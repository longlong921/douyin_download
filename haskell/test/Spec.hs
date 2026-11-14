{-# LANGUAGE OverloadedStrings #-}
module Main where
import Types
import Network
import Parser
import App (validRange,limited,boundedTime)
import qualified Network.Socket as S
import Control.Exception
import Control.Concurrent.STM hiding (check)
import Control.Monad
import Data.Aeson
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import System.Exit
import Data.IORef
import qualified Network.HTTP.Client as H
import View
import Lucid (renderBS)
check :: String -> Bool -> IO ()
check label ok = if ok then putStrLn ("PASS "<>label) else die ("FAIL "<>label)
main :: IO ()
main = do
 forM_ ["http://127.0.0.1/","http://[::1]/","http://169.254.169.254/","https://www.douyin.com.evil.com/","https://evil@www.douyin.com/","https://www.douyin.com:8080/","file:///etc/passwd"] $ \u->check ("reject "<>u) (not $ validURL True u)
 forM_ [(127,0,0,1),(10,1,2,3),(172,16,0,1),(192,168,1,1),(169,254,169,254),(100,64,0,1),(198,18,0,1),(224,0,0,1),(0,0,0,0)] $ \ip->check ("private IP "<>show ip) (not $ publicIPv4 $ S.tupleToHostAddress ip)
 check "public IP" (publicIPv4 $ S.tupleToHostAddress (8,8,8,8))
 check "domain boundary" (validURL True "https://v3.douyinvod.com/video.mp4")
 check "share text" (extractURL "复制打开抖音 https://v.douyin.com/abc/， 作品"==Right "https://v.douyin.com/abc/")
 let ident="7707698168485708904"
 check "standard ID" (videoID ("https://www.douyin.com/video/"<>T.unpack ident)==Just ident)
 check "query ID" (videoID ("https://www.douyin.com/?modal_id="<>T.unpack ident)==Just ident)
 let payload=object ["loaderData" .= object ["video_(id)/page" .= object ["videoInfoRes" .= object ["item_list" .= [object ["aweme_id" .= ident,"video" .= object ["play_addr" .= object ["url_list" .= ["https://v3.douyinvod.com/a"::T.Text]]]]]]]]]
 let pageBody="window._ROUTER_DATA = "<>L.toStrict(encode payload)<>";</script>"
 case parsePage ident pageBody of Right v->check "metadata degradation" (author v==Nothing && duration v==Nothing); Left e->die(show e)
 case parsePage "1234567890123" pageBody of Left (AppError _ c _)->check "identity mismatch" (c=="parser_changed");_ ->die "mismatched ID allowed"
 case parsePage ident "window._ROUTER_DATA={\"loaderData\":{}}" of Left(AppError _ c _)->check "missing data" (c=="data_missing");_->die "missing data allowed"
 check "range supported" (all validRange ["bytes=0-1023","bytes=1024-","bytes=-256"])
 check "multirange rejected" (not $ validRange "bytes=0-1,3-4")
 ref<-newTVarIO 4
 outcome<-try (limited ref $ pure ()) :: IO(Either AppError ())
 case outcome of Left(AppError code _ _)->check "concurrency" (code==429);_->die "concurrency limit failed"
 ref2<-newTVarIO 0
 _<-try (limited ref2 $ err 502 "upstream_error" "test") :: IO(Either AppError ())
 count<-readTVarIO ref2
 check "slot released after failure" (count==0)
 forM_ [(403,"verification_required"),(429,"rate_limited"),(404,"unavailable"),(503,"upstream_error")] $ \(status,code)->do
  failure<-try (upstream status) :: IO (Either AppError ())
  check ("upstream status "<>show status) (case failure of Left(AppError _ c _)->c==code;_->False)
 req<-H.parseRequest "http://127.0.0.1/"
 denied<-try(pinRequest req) :: IO(Either AppError H.Request)
 check "connection-time IP denial" (case denied of Left(AppError _ c _)->c=="unsafe_url";_->False)
 chunks<-newIORef ["1234","5678",""]
 let reader=atomicModifyIORef' chunks (\xs->case xs of []->([],"");(x:rest)->(rest,x))
 oversized<-try(readBounded 6 reader) :: IO(Either AppError B.ByteString)
 check "stream size bounded" (case oversized of Left(AppError code _ _)->code==413;_->False)
 let rendered=L.toStrict $ renderBS $ home "" "<script>alert(1)</script>" Nothing Nothing
 check "form input HTML escaped" (not $ "<script>alert(1)</script>" `B.isInfixOf` rendered)
 deniedSocket<-try (connectPinned (Just $ S.tupleToHostAddress (127,0,0,1)) 443) :: IO(Either AppError S.Socket)
 check "TLS/raw socket rejects private pin" (case deniedSocket of Left(AppError _ c _)->c=="unsafe_url";_->False)
 putStrLn "All Haskell security/parser tests passed"
