{-# LANGUAGE OverloadedStrings #-}
module Parser where
import Types
import Network
import Control.Exception
import Control.Monad
import Data.Aeson
import qualified Data.Aeson.KeyMap as K
import Data.Aeson.Key (fromText)
import Data.Aeson.Parser (json')
import qualified Data.Attoparsec.ByteString as A
import qualified Data.ByteString as B
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as E
import Data.Text.Encoding.Error (lenientDecode)
import Data.Char
import Data.Maybe
import Data.IORef
import Network.URI
import Network.HTTP.Client (Manager, createCookieJar)
import Network.HTTP.Types.URI (parseQueryText)

get :: Text -> Value -> Value
get k (Object o) = fromMaybe Null (K.lookup (fromText k) o)
get _ _ = Null
str :: Value -> Maybe Text
str (String s) = Just s
str _ = Nothing
arr :: Value -> [Value]
arr v = fromMaybe [] (decode $ encode v)
urls :: Value -> [Text]
urls = mapMaybe str . arr . get "url_list"
extractURL :: Text -> Either AppError String
extractURL t = maybe (Left $ AppError 400 "invalid_input" "请粘贴抖音分享文案或视频链接。") Right $ listToMaybe
 [u | word <- T.words t, (_,suffix) <- [T.breakOn "http" word], not (T.null suffix), let u=T.unpack $ T.dropWhileEnd (`elem` (".,!;:，。！；：、）)]}】"::String)) suffix, validURL False u]
videoID :: String -> Maybe Text
videoID url = do
 u <- parseURI url
 let pieces=T.splitOn "/" $ T.pack $ uriPath u
     ids=[b | (a,b) <- zip pieces (drop 1 pieces), a=="video", valid b]
     query=mapMaybe snd [p | p@(k,_) <- parseQueryText $ E.encodeUtf8 $ T.pack $ uriQuery u,k=="modal_id"]
 listToMaybe (ids ++ filter valid query)
 where valid x=T.length x >=10 && T.length x<=25 && T.all isDigit x
parsePage :: Text -> B.ByteString -> Either AppError Video
parsePage ident bytes = do
 let text=E.decodeUtf8With lenientDecode bytes
     (_,tail0)=T.breakOn "_ROUTER_DATA" text
 when (T.null tail0) $ Left $ if any (`T.isInfixOf` T.toLower text) ["captcha","argus","verifycenter","验证"] then AppError 502 "verification_required" "分享页要求验证，请在抖音打开原链接后重试。" else AppError 502 "parser_changed" "分享页格式已变化，请更新解析模块。"
 let payload=T.drop 1 $ snd $ T.breakOn "=" tail0
 value <- either (const $ Left $ AppError 502 "parser_changed" "分享页数据格式已变化。") Right $ A.parseOnly json' $ E.encodeUtf8 $ T.stripStart payload
 let nodes=case get "loaderData" value of Object o -> K.elems o; _ -> []
 info <- maybe (Left $ AppError 502 "data_missing" "抖音仅返回页面框架，未提供视频数据。请确认作品公开并稍后重试。") Right $ listToMaybe [v | node<-nodes,let v=get "videoInfoRes" node,v/=Null]
 let items=arr $ get "item_list" info
 when (null items) $ Left $ AppError 404 "unavailable" "作品不可用，可能已删除或私密。"
 item <- maybe (Left $ AppError 502 "parser_changed" "上游作品 ID 不一致，已停止下载。") Right $ listToMaybe [v | v<-items,str (get "aweme_id" v)==Just ident || str (get "item_id" v)==Just ident]
 let vid=get "video" item; links=urls $ get "play_addr" vid
 when (null links) $ Left $ AppError 404 "unavailable" "此作品未提供视频资源，可能是图文作品。"
 unless (all (validURL True . T.unpack) links) $ Left $ AppError 400 "unsafe_url" "媒体地址不在允许范围内。"
 let dur=case get "duration" vid of Number n -> Just (realToFrac n / 1000); _ -> Nothing
 pure $ Video ident (fromMaybe ("抖音视频 "<>ident) $ str $ get "desc" item) (str $ get "nickname" $ get "author" item) dur (listToMaybe $ urls (get "cover" vid) ++ urls (get "origin_cover" vid)) links
resolve :: Manager -> Text -> IO Video
resolve mgr input = do
 url <- either throwIO pure (extractURL input)
 jar <- newIORef (createCookieJar [])
 ident <- case videoID url of
  Just i -> do
   -- Standard URLs need the same anonymous-cookie bootstrap as short links.
   _ <- page mgr jar url
   pure i
  Nothing -> do
   (final,_) <- page mgr jar url
   maybe (err 400 "invalid_input" "分享链接未指向视频作品。") pure (videoID final)
 let targets=["https://"++h++"/share/video/"++T.unpack ident++"/" | h<-["www.iesdouyin.com","www.douyin.com"]]
     fetch [] lastError = throwIO lastError
     fetch (u:us) _ = do
      (_,b) <- page mgr jar u
      case parsePage ident b of
       Right v -> pure v
       Left e@(AppError _ code _) -> if code=="data_missing" then do
        (_,b2)<-page mgr jar u
        either (fetch us) pure (parsePage ident b2)
        else fetch us e
 fetch targets (AppError 502 "data_missing" "未获取到视频数据。")
