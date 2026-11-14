{-# LANGUAGE OverloadedStrings #-}
module View where
import Types
import Lucid
import Lucid.Base (makeAttribute)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Maybe
import Text.Printf

home :: Text -> Text -> Maybe AppError -> Maybe (Text,Video) -> Html ()
home base input failure result = doctypehtml_ $ do
 head_ $ do
  meta_ [charset_ "utf-8"]
  meta_ [name_ "viewport",content_ "width=device-width, initial-scale=1, viewport-fit=cover"]
  meta_ [name_ "theme-color",content_ "#101618"]
  title_ "拾影 · Haskell 视频下载"
  link_ [rel_ "stylesheet",href_ (base<>"/style.css")]
  link_ [rel_ "manifest",href_ (base<>"/manifest.webmanifest")]
  link_ [rel_ "icon",href_ (base<>"/icon.svg")]
  script_ [src_ (base<>"/enhance.js"),defer_ ""] (""::Text)
 body_ $ main_ $ do
  header_ $ do
   a_ [class_ "brand",href_ (base<>"/")] $ do
    span_ [class_ "logo"] "↓"; toHtml ("拾影"::Text); span_ [class_ "brand-small"] "视频下载"
   span_ [class_ "badge"] "Haskell 全栈"
  section_ [class_ "intro"] $ do
   p_ [class_ "eyebrow"] "KEEP THE MOMENT"
   h1_ $ do "喜欢的视频，"; br_ []; span_ "留在手机里。"
   p_ $ do "复制抖音分享内容，粘贴到这里。";br_ [];"预览确认后，一键保存。"
  div_ [class_ "workspace"] $ do
   section_ [class_ "input-card"] $ form_ [method_ "post",action_ (base<>"/parse"),id_ "parse-form"] $ do
    div_ [class_ "card-top"] $ do
     h2_ $ do span_ [class_ "step"] "01";"粘贴分享内容"
     a_ [class_ "text-button",href_ (base<>"/")] "清空"
    label_ [for_ "share",class_ "sr-only"] "抖音分享链接或文案"
    textarea_ [id_ "share",name_ "text",maxlength_ "8192",required_ "",placeholder_ "在这里粘贴分享链接或整段文案\nhttps://v.douyin.com/…"] (toHtml input)
    div_ [class_ "input-meta"] $ do
     span_ "支持短链接 · 视频链接 · 分享文案"
     button_ [type_ "button",id_ "paste",class_ "text-button"] "粘贴"
    button_ [type_ "submit",class_ "primary",id_ "parse-button"] $ do "解析视频";span_ "→"
    case failure of
     Just (AppError _ _ msg) -> div_ [class_ "error",role_ "alert"] $ do
      strong_ "暂时无法解析";p_ (toHtml msg);button_ [type_ "submit",class_ "retry"] "重新尝试 ↻"
     Nothing -> pure ()
    p_ [class_ "notice",id_ "notice",role_ "status"] "视频由平台提供，部分作品可能需要登录或验证。"
   section_ [class_ "result-card",id_ "result"] $ do
    h2_ $ do span_ [class_ "step"] "02"; toHtml (if isJust result then "预览并保存" else "等待你的下一段精彩" :: Text)
    case result of
     Nothing -> div_ [class_ "empty"] $ do div_ [class_ "film"] (span_ "▷");p_ "解析后，视频会出现在这里";small_ "先预览，再决定保存"
     Just (token,v) -> do
      let u=base<>"/api/media/"<>token
      video_ ([controls_ "",makeAttribute "playsinline" "",preload_ "metadata",src_ u] ++ [poster_ (u<>"?kind=cover") | isJust (cover v)]) (pure () :: Html ())
      h3_ (toHtml $ title v)
      p_ [class_ "video-meta"] $ toHtml $ fromMaybe "作者信息未提供" (author v) <> " · " <> maybe "时长未提供" (T.pack . printf "%.1f 秒") (duration v)
      a_ [class_ "primary download",href_ (u<>"?download=1"),download_ ""] "↓ 下载到本地"
      a_ [class_ "source",href_ ("https://www.douyin.com/video/"<>videoId v),target_ "_blank",rel_ "noreferrer"] "在抖音查看原作品 ↗"
  section_ [class_ "guide"] $ mapM_ (\(n,t,d)->div_ $ do b_ (toHtml (n::Text));p_ $ do toHtml (t::Text);small_ (toHtml (d::Text))) [("1","复制分享链接","抖音 → 分享 → 复制链接"),("2","粘贴并解析","整段分享文案也可以"),("3","下载到手机","在浏览器下载列表中查看")]
  footer_ $ do p_ "只保存你拥有或获准下载的作品，尊重创作者。";p_ "添加到主屏幕，即可像 App 一样使用 · 在线解析需要网络"
