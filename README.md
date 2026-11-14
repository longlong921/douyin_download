# 拾影 · 抖音视频解析下载

React + TypeScript + Vite 手机 Web/PWA，FastAPI 后端。支持分享文案、短链接和标准视频地址。后端独立解析分享页 `_ROUTER_DATA`，只使用平台返回的媒体地址，浏览器通过同源流式接口预览、下载。

**真实下载已通过：给定短链接对应视频已下载 12,650,373 字节，720×1280 H.264 + AAC，并通过 FFmpeg 完整解码。** 详细证据及复现见 [docs/verification.md](docs/verification.md)。

## 启动

需要 Docker Engine 和 Docker Compose v2：

```sh
cp .env.example .env
docker compose up --build -d
# 打开 http://localhost:8000
docker compose logs -f app
```

开发（Python 3.12、Node.js 22）：

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
cd frontend
npm ci
npm run build
cd ..
.venv/bin/uvicorn backend.app.main:app --host 0.0.0.0 --port 8000
```

前端热更新：另开终端 `cd frontend && npm run dev`，访问 5173 端口，Vite 将 `/api` 代理到后端。构建后后端直接提供前端静态文件。

## 手机与 HTTPS 部署

局域网临时测试可设 `BIND_ADDRESS=0.0.0.0`，手机连接同一 Wi-Fi，访问电脑局域网 IP 的 8000 端口。HTTP 局域网地址可进行解析/下载，但剪贴板 API、Service Worker 和 PWA 安装需要 **HTTPS**（localhost 开发例外）。剪贴板不可用时长按输入框粘贴。

生产用 Caddy/Nginx 提供证书并同源代理到 `127.0.0.1:8000`，例如 Caddyfile：

```caddyfile
video.example.com {
    reverse_proxy 127.0.0.1:8000 {
        flush_interval -1
    }
}
```

域名解析到服务器，开放 80/443，Caddy 自动申请证书。Nginx 应关闭 `proxy_buffering`，将 `proxy_read_timeout` 设置为 310 秒。不要缓存 `/api/*`。安卓 Chrome 菜单选择“安装应用”或“添加到主屏幕”。PWA 只缓存应用外壳，解析与下载必须联网；不缓存媒体或 API 数据。已验证 Chromium 中离线打开应用外壳；真机安装需在自己的 HTTPS 部署中确认。

下载由浏览器管理，可在下载列表查看；应用不虚构进度。浏览器直接导航下载接口时若失败，会显示含错误码和中文说明的 JSON；返回应用点击重新解析可恢复。流已经开始后若网络中断，HTTP 状态不能再修改，浏览器会报告失败，应重新解析并下载。

## 配置与限制

见 `.env.example`：默认 512 MiB/视频、4 个并发媒体流、4 个并发解析、令牌 30 分钟、最多 500 个结果。封面上限 8 MiB。连接超时 10 秒，空闲读取 30 秒，单次媒体请求总时限 300 秒，解析总时限 60 秒。支持单段 Range 请求。

`DOUYIN_COOKIE` 可由部署者填写自己合法取得的有效 Cookie；它不是保证成功的开关，不会自动绕过验证码。不要把 Cookie 放进前端或提交仓库。后端直连网络，刻意不读取 HTTP_PROXY/HTTPS_PROXY，确保公网 DNS 检查控制实际连接。

资源令牌存在单进程内存中，重启后需要重新解析。**保持一个 uvicorn worker**；多副本需增加共享存储和分布式限额。生产如对公网开放，建议在反向代理加身份验证及每 IP 请求速率限制；当前并发限制是每实例全局限制。

下载接口只接受不可猜测令牌，不接受 URL。媒体来自已解析且 ID 匹配的作品。所有请求及重定向都校验协议、端口、凭据、域名边界；连接时校验全部 DNS 结果，只允许公网地址，防止 DNS 重绑定。流以 64 KiB 分块传输，检查 Content-Length/Content-Range，未知长度也累计限额；媒体地址过期后重新解析一次，4 分钟以上的地址主动刷新。

正常字段缺失显示降级文案。错误码包括 `invalid_input`、`unavailable`、`verification_required`、`timeout`、`rate_limited`、`parser_changed`、`data_missing`、`upstream_error`、`expired`、`unsafe_url`、`too_large`。`data_missing` 表示上游没有数据，不能据此断言作品已删除或确定需要登录。

## 验证与维护

```sh
.venv/bin/pip install pytest httpx
.venv/bin/python -m pytest backend/tests -q
cd frontend && npm ci && npm run build
# 另装 ffmpeg（含 ffprobe），启动应用后运行真实验收
python3 scripts/verify_live.py
```

真实验收脚本保存文件、计算 SHA256、用 ffprobe 检查轨道，再由 ffmpeg 完整解码；无法解析时返回非零退出码，不使用模拟视频替代。平台变化优先修改 `backend/app/parser.py`，网络和下载安全逻辑位于 `network.py` / `main.py`。

本项目独立实现，调研参考 [aiaoxd/douyinDownloader](https://github.com/aiaoxd/douyinDownloader) 的分享页思路及 [yt-dlp 抖音问题 #17464](https://github.com/yt-dlp/yt-dlp/issues/17464)。未引入第三方解析服务，实际文件可能带平台水印和片尾，不承诺特定画质或所有作品均可用。
