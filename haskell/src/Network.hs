{-# LANGUAGE OverloadedStrings #-}
module Network where
import Types
import Control.Exception
import Control.Monad
import Data.IORef
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Text as T
import Network.URI
import qualified Network.Socket as S
import Network.HTTP.Client
import Network.HTTP.Client.Internal (Request(hostAddress), makeConnection)
import qualified Network.Connection as NC
import qualified Network.Socket.ByteString as SB
import System.Timeout (timeout)
import Network.HTTP.Client.TLS
import Network.HTTP.Types

pageHosts :: [String]
pageHosts = ["v.douyin.com","www.douyin.com","douyin.com","www.iesdouyin.com","m.douyin.com"]
mediaDomains :: [String]
mediaDomains = ["douyin.com","iesdouyin.com","douyinvod.com","douyincdn.com","douyinpic.com","zjcdn.com","bytecdn.cn","bytecdn.com","snssdk.com","amemv.com","pstatp.com","byteimg.com","ibytedtos.com","bytedance.com","bytedance.net"]
validURL :: Bool -> String -> Bool
validURL isMedia url = case parseURI url of
 Just u | Just a <- uriAuthority u -> uriScheme u `elem` ["http:","https:"] && null (uriUserInfo a) && uriPort a `elem` ["",":80",":443"] && allowed (uriRegName a)
 _ -> False
 where allowed h = if isMedia then any (\d -> h == d || T.pack ('.':d) `T.isSuffixOf` T.pack h) mediaDomains else h `elem` pageHosts
publicIPv4 :: S.HostAddress -> Bool
publicIPv4 ip = let (a,b,c,_) = S.hostAddressToTuple ip in not $
 a `elem` [0,10,127] || a >= 224 || (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) || (a == 192 && (b == 168 || (b == 0 && c `elem` [0,2]) || (b == 88 && c == 99))) || (a == 198 && (b `elem` [18,19] || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113)
-- Resolve once, reject non-public answers, and pin the actual connection address.
-- IPv4 only deliberately avoids a second resolver or unchecked IPv6 fallback.
pinRequest :: Request -> IO Request
pinRequest req = do
 xs <- S.getAddrInfo (Just S.defaultHints {S.addrFamily=S.AF_INET,S.addrSocketType=S.Stream}) (Just $ C.unpack $ host req) (Just $ show $ port req)
 let ips = [ip | x <- xs, S.SockAddrInet _ ip <- [S.addrAddress x]]
 when (null ips || not (all publicIPv4 ips)) $ err 400 "unsafe_url" "已阻止访问非公网地址。"
 pure req { hostAddress=Just (head ips), proxy=Nothing, redirectCount=0, checkResponse = \_ _ -> pure (), responseTimeout=responseTimeoutMicro 30000000 }
newClient :: IO Manager
newClient = do
 context <- NC.initConnectionContext
 let raw address _ portNumber = do
      sock <- connectPinned address portNumber
      makeConnection (SB.recv sock 32768) (SB.sendAll sock) (S.close sock)
     tls address hostname portNumber = do
      sock <- connectPinned address portNumber
      let params = NC.ConnectionParams hostname (fromIntegral portNumber)
                     (Just $ NC.TLSSettingsSimple False False True) Nothing
      conn <- NC.connectFromSocket context sock params `onException` S.close sock
      makeConnection (NC.connectionGetChunk conn) (NC.connectionPut conn) (NC.connectionClose conn)
 -- http-client-tls's default connector ignores Request.hostAddress. Supply both
 -- connectors explicitly so TLS keeps the original SNI/certificate hostname
 -- while the TCP socket connects ONLY to the checked address, without DNS again.
 newManager tlsManagerSettings {managerConnCount=8, managerResponseTimeout=responseTimeoutMicro 30000000,
                               managerRawConnection=pure raw, managerTlsConnection=pure tls}
connectPinned :: Maybe S.HostAddress -> Int -> IO S.Socket
connectPinned address portNumber = do
 ip <- case address of
  Just checked | publicIPv4 checked -> pure checked
  _ -> err 400 "unsafe_url" "实际连接目标必须是已验证的公网地址。"
 bracketOnError (S.socket S.AF_INET S.Stream S.defaultProtocol) S.close $ \sock -> do
  result <- timeout 10000000 $ S.connect sock (S.SockAddrInet (fromIntegral portNumber) ip)
  case result of
   Nothing -> err 504 "timeout" "连接上游超时，请稍后重试。"
   Just () -> pure sock
ua :: B.ByteString
ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
openSafe :: Manager -> IORef CookieJar -> Bool -> RequestHeaders -> String -> IO (String, Response BodyReader)
openSafe mgr jar isMedia extra = go (0::Int)
 where
 go n url = do
  when (n > 5 || not (validURL isMedia url)) $ err 400 "unsafe_url" "链接或重定向地址不在允许范围内。"
  req0 <- parseRequest url
  req <- pinRequest req0
  cookies <- readIORef jar
  r <- responseOpen req {cookieJar=Just cookies,requestHeaders=[("User-Agent",ua),("Referer","https://www.douyin.com/"),("Accept-Encoding","identity")] ++ extra} mgr
  writeIORef jar (responseCookieJar r)
  if statusCode (responseStatus r) `elem` [301,302,303,307,308]
   then do
    responseClose r
    case (lookup hLocation (responseHeaders r) >>= parseURIReference . C.unpack,parseURI url) of
     (Just loc, Just base) -> go (n+1) (show $ loc `relativeTo` base)
     _ -> err 502 "upstream_error" "上游跳转异常。"
   else pure (url,r)
readBounded :: Int -> BodyReader -> IO B.ByteString
readBounded limit reader = go 0 []
 where go n xs = do
        b <- brRead reader
        let total=n+B.length b
        when (total>limit) $ err 413 "too_large" "上游响应超过大小限制。"
        if B.null b then pure (B.concat $ reverse xs) else go total (b:xs)
page :: Manager -> IORef CookieJar -> String -> IO (String,B.ByteString)
page mgr jar url = bracket (openSafe mgr jar False [] url) (responseClose . snd) $ \(final,r) -> do
 upstream (statusCode $ responseStatus r)
 b <- readBounded (4*1024*1024) (responseBody r)
 pure (final,b)
