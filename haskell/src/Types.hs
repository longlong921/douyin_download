{-# LANGUAGE OverloadedStrings, DeriveDataTypeable #-}
module Types where
import Control.Exception
import Data.Typeable
import Data.Text (Text)
import Data.Aeson

data AppError = AppError Int Text Text deriving (Show, Eq, Typeable)
instance Exception AppError
err :: Int -> Text -> Text -> IO a
err s c m = throwIO (AppError s c m)
errorJSON :: AppError -> Value
errorJSON (AppError _ c m) = object ["error" .= object ["code" .= c, "message" .= m]]
data Video = Video { videoId :: Text, title :: Text, author :: Maybe Text, duration :: Maybe Double, cover :: Maybe Text, media :: [Text] } deriving (Show)
upstream :: Int -> IO ()
upstream n
 | n == 429 = err 429 "rate_limited" "抖音请求过于频繁，请稍后重试。"
 | n `elem` [401,403] = err 502 "verification_required" "上游要求登录或验证，请在抖音确认作品可访问后重试。"
 | n `elem` [404,410] = err 404 "unavailable" "视频已不可用，请在抖音确认作品是否公开。"
 | n == 416 = err 416 "invalid_range" "视频范围无效，请重新解析。"
 | n >= 400 = err 502 "upstream_error" "上游服务异常，请稍后重试。"
 | otherwise = pure ()
