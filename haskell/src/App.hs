{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module App where
import Types
import qualified Network as N
import Parser (resolve)
import View
import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (convertToBase, Base(Base16))
import Data.Aeson
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Builder (byteString)
import qualified Data.Map.Strict as M
import Data.IORef
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock.POSIX
import Network.Wai
import qualified Network.HTTP.Client as H
import Network.HTTP.Types
import Network.HTTP.Types.Header (hContentRange, hContentDisposition, hAcceptRanges)
import Lucid (renderBS)
import System.Timeout
import Text.Read

-- Tokens are opaque capabilities; upstream URLs never come from media requests.
data Entry = Entry Video POSIXTime POSIXTime (MVar ())
data Env = Env {manager::H.Manager, cache::TVar (M.Map Text Entry), parsers::TVar Int, streams::TVar Int, basePath::Text, staticDir::FilePath}
newEnv :: Text -> FilePath -> IO Env
newEnv base dir = Env <$> N.newClient <*> newTVarIO M.empty <*> newTVarIO 0 <*> newTVarIO 0 <*> pure base <*> pure dir
limited :: TVar Int -> IO a -> IO a
limited counter action = bracket_ acquire release action where
 acquire = do ok<-atomically $ do n<-readTVar counter;if n>=4 then pure False else writeTVar counter (n+1)>>pure True
              unless ok $ err 429 "rate_limited" "任务较多，请稍后重试。"
 release = atomically $ modifyTVar' counter (subtract 1)
boundedTime :: Int -> IO a -> IO a
boundedTime seconds action = timeout (seconds*1000000) action >>= maybe (err 504 "timeout" "上游请求超时，请稍后重试。") pure
normalizeError :: SomeException -> IO AppError
normalizeError e = case fromException e of
 Just a -> pure a
 Nothing -> case fromException e :: Maybe AsyncException of
  Just async -> throwIO async
  Nothing -> pure (AppError 502 "upstream_error" "无法连接上游服务，请稍后重试。")
jsonResponse :: Status -> Value -> Response
jsonResponse s = responseLBS s [(hContentType,"application/json; charset=utf-8"),(hCacheControl,"no-store")] . encode
htmlResponse :: Status -> Env -> Text -> Maybe AppError -> Maybe (Text,Video) -> Response
htmlResponse s env input failure result = responseLBS s [(hContentType,"text/html; charset=utf-8"),(hCacheControl,"no-store")] $ renderBS $ home (basePath env) input failure result
readInput :: Request -> IO Text
readInput req = do
 body <- N.readBounded 16384 (getRequestBodyChunk req)
 let jsonInput=case decodeStrict' body :: Maybe (M.Map Text Text) of
      Just obj -> M.findWithDefault "" "text" obj
      Nothing -> ""
     formInput=fromMaybe "" $ lookup "text" (parseQueryText body) >>= id
     input=if "application/json" `B.isPrefixOf` fromMaybe "" (lookup hContentType $ requestHeaders req) then jsonInput else formInput
 when (T.null input || T.length input>8192) $ err 400 "invalid_input" "请粘贴有效分享内容（最多 8192 字）。"
 pure input
parseVideo :: Env -> Text -> IO (Text,Video)
parseVideo env text = limited (parsers env) $ boundedTime 60 $ do
 v <- resolve (manager env) text
 token <- E.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 32 :: IO B.ByteString)
 now<-getPOSIXTime; lock<-newMVar ()
 atomically $ modifyTVar' (cache env) $ \m -> let fresh=M.filter (\(Entry _ born _ _)->now-born<1800) m; bounded=if M.size fresh>=500 then M.deleteMin fresh else fresh in M.insert token (Entry v now now lock) bounded
 pure (token,v)
videoJSON :: Env -> (Text,Video) -> Value
videoJSON env (token,v) = let u=basePath env<>"/api/media/"<>token in object ["id" .= videoId v,"title" .= title v,"author" .= author v,"duration" .= duration v,"cover" .= fmap (const $ u<>"?kind=cover") (cover v),"preview_url" .= u,"download_url" .= (u<>"?download=1"),"expires_in" .= (1800::Int)]
application :: Env -> Application
application env req respond = do
 started <- newIORef False
 let send response=writeIORef started True >> respond response
     handle (e::SomeException) = do
      begun<-readIORef started
      if begun then throwIO e else do a@(AppError code _ _)<-normalizeError e; respond (jsonResponse (mkStatus code "Error") $ errorJSON a)
 route env req send `catch` handle
route :: Env -> Application
route env req send = case (requestMethod req,pathInfo req) of
 ("GET",[]) -> send $ htmlResponse status200 env "" Nothing Nothing
 ("GET",["api","health"]) -> send $ jsonResponse status200 $ object ["status" .= ("ok"::Text),"stack" .= ("Haskell / Warp / Lucid"::Text)]
 ("POST",["api","parse"]) -> readInput req >>= parseVideo env >>= send . jsonResponse status200 . videoJSON env
 ("POST",["parse"]) -> do
  input<-readInput req
  result<-try (parseVideo env input)
  case result of
   Right v -> send $ htmlResponse status200 env input Nothing (Just v)
   Left e -> do a@(AppError code _ _)<-normalizeError e;send $ htmlResponse (mkStatus code "Error") env input (Just a) Nothing
 ("GET",["api","media",token]) -> limited (streams env) $ boundedTime 300 $ streamMedia env req token send
 ("GET",["manifest.webmanifest"]) -> send $ responseLBS status200 [(hContentType,"application/manifest+json")] $ encode $ object ["id" .= (basePath env<>"/"),"name" .= appTitle,"short_name" .= ("拾影"::Text),"start_url" .= (basePath env<>"/"),"scope" .= (basePath env<>"/"),"display" .= ("standalone"::Text),"theme_color" .= ("#101618"::Text),"background_color" .= ("#101618"::Text),"icons" .= [object ["src" .= (basePath env<>"/icon-"<>T.pack(show n)<>".png"),"sizes" .= (T.pack(show n)<>"x"<>T.pack(show n)),"type" .= ("image/png"::Text),"purpose" .= ("any maskable"::Text)] | n<-[192,512::Int]]]
 ("GET",[file]) | Just mime<-lookup file [("style.css","text/css"),("enhance.js","text/javascript"),("sw.js","text/javascript"),("icon.svg","image/svg+xml"),("icon-192.png","image/png"),("icon-512.png","image/png")] -> send $ responseFile status200 [(hContentType,mime),(hCacheControl,"no-cache")] (staticDir env<>"/"<>T.unpack file) Nothing
 _ -> send $ jsonResponse status404 $ errorJSON $ AppError 404 "not_found" "页面不存在。"

validRange :: B.ByteString -> Bool
validRange value = case B.stripPrefix "bytes=" value of
 Nothing -> False
 Just s -> case C.split '-' s of [a,b] -> (not (B.null a) || not (B.null b)) && C.all (`elem` ['0'..'9']) a && C.all (`elem` ['0'..'9']) b;_ -> False
streamMedia :: Env -> Request -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
streamMedia env req token send = do
 now<-getPOSIXTime
 entry<-M.lookup token <$> readTVarIO (cache env)
 (v,born,updated,lock)<-case entry of Just (Entry v b u l) | now-b<1800 -> pure (v,b,u,l);_ -> err 410 "expired" "解析结果已过期，请重新解析。"
 let coverRequest=lookup "kind" (queryString req)==Just (Just "cover")
     download=lookup "download" (queryString req)==Just (Just "1")
     range=lookup hRange (requestHeaders req)
 when (maybe False (not . validRange) range) $ err 416 "invalid_range" "仅支持单段视频范围请求。"
 let refresh = withMVar lock $ \_ -> do
      new<-resolve (manager env) ("https://www.douyin.com/video/"<>videoId v)
      stamp<-getPOSIXTime
      atomically $ modifyTVar' (cache env) (M.adjust (const $ Entry new born stamp lock) token)
      pure new
 current<-if now-updated>240 then boundedTime 60 refresh else pure v
 jar<-newIORef (H.createCookieJar [])
 let open video = do
      let candidates=if coverRequest then maybe [] (:[]) (cover video) else media video
      let choose [] = err 404 "unavailable" "资源不可用。"
          choose (u:us) = do
           (_,r)<-N.openSafe (manager env) jar True (maybe [] (\x->[(hRange,x)]) range) (T.unpack u)
           if statusCode(H.responseStatus r)>=400 && not(null us) then H.responseClose r>>choose us else pure r
      choose candidates
 r0<-open current
 (actual,r)<-if statusCode(H.responseStatus r0) `elem` [401,403,404,410] then do H.responseClose r0;new<-boundedTime 60 refresh;r1<-open new;pure(new,r1) else pure(current,r0)
 flip finally (H.responseClose r) $ do
  upstream (statusCode $ H.responseStatus r)
  let hs=H.responseHeaders r
      mime=C.takeWhile (/=';') $ fromMaybe "" (lookup hContentType hs)
      ext=lookup mime [("video/mp4","mp4"),("video/webm","webm"),("video/quicktime","mov")]
      limit=if coverRequest then 8*1024*1024 else 512*1024*1024 :: Int
      number x=readMaybe (C.unpack x)::Maybe Int
      len=lookup hContentLength hs >>= number
      total=lookup hContentRange hs >>= number . last . C.split '/'
  unless (if coverRequest then mime `elem` ["image/jpeg","image/png","image/webp"] else isJust ext) $ err 502 "parser_changed" "上游未提供支持的媒体文件。"
  when (any (>limit) $ catMaybes [len,total]) $ err 413 "too_large" "文件超过服务器大小限制。"
  let suffix=fromMaybe "mp4" ext
      clean=T.take 80 $ T.map (\c->if c<' ' || c `elem` ("/\\:*?\"<>|"::String) then '_' else c) (title actual)
      filename=E.encodeUtf8 $ clean<>"_"<>videoId actual<>"."<>E.decodeUtf8 suffix
      disposition=(if download then "attachment" else "inline")<>"; filename=\"douyin_"<>E.encodeUtf8(videoId actual)<>"."<>suffix<>"\"; filename*=UTF-8''"<>urlEncode True filename
      headers=[(hContentType,mime),(hCacheControl,"no-store"),("X-Content-Type-Options","nosniff")]++[(hContentDisposition,disposition)|not coverRequest]++filter (\(k,_)->k `elem` [hContentLength,hContentRange,hAcceptRanges]) hs
      loop n write flush = do
       b<-H.brRead (H.responseBody r)
       unless (B.null b) $ do
        when (n+B.length b>limit) $ err 413 "too_large" "流超出大小限制。"
        write (byteString b);flush;loop (n+B.length b) write flush
  send $ responseStream (H.responseStatus r) headers (loop 0)
