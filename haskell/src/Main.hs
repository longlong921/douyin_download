{-# LANGUAGE OverloadedStrings #-}
module Main where
import App
import Network.Wai.Handler.Warp
import System.Environment
import Data.Maybe
import qualified Data.Text as T
import Data.String (fromString)
import Text.Read
main :: IO ()
main = do
 port<-fromMaybe 8187 . (>>=readMaybe) <$> lookupEnv "PORT"
 host<-fromMaybe "127.0.0.1" <$> lookupEnv "BIND_ADDRESS"
 base<-T.pack . fromMaybe "" <$> lookupEnv "BASE_PATH"
 dir<-fromMaybe "static" <$> lookupEnv "STATIC_DIR"
 env<-newEnv base dir
 putStrLn $ "Haskell downloader listening on "<>host<>":"<>show port
 runSettings (setPort port $ setHost (fromString host) $ setTimeout 310 $ setGracefulShutdownTimeout (Just 10) defaultSettings) (application env)
