# 拾影 · Haskell 全栈抖音下载

Haskell / Warp / WAI 后端，Lucid 类型化 HTML 前端。页面、表单、校验、解析、令牌和下载均在 Haskell 中实现，没有 React、Node.js 或 Python 运行时。浏览器原生播放器和下载器处理媒体；少量渐进增强 JavaScript 只负责剪贴板、加载提示和 Service Worker。关闭 JavaScript 仍可解析、预览、下载。

真实样本：`https://v.douyin.com/1znUsjZNolc/`。Haskell 版本已经下载 12,650,373 字节、720×1280 H.264 + AAC 视频并通过 FFmpeg 完整解码；SHA256 与迁移前相同。验收见 [docs/verification.md](docs/verification.md)。

## 本地构建

Ubuntu 24.04 / GHC 9.4.7 已验证（使用系统包，避免依赖 Hackage 在线索引）：

```sh
sudo apt-get update
sudo apt-get install ghc libghc-warp-dev libghc-wai-dev \
  libghc-http-client-tls-dev libghc-aeson-dev libghc-lucid-dev \
  libghc-network-uri-dev libghc-cryptonite-dev ca-certificates
./scripts/build-haskell.sh
./build/douyin-download
# http://127.0.0.1:8187
```

Cabal 项目定义位于 `haskell/douyin-download.cabal`，可在能正常访问 Hackage 的环境运行 `cabal build all`；本次环境的 Hackage 安全索引签名验证失败，实际构建和测试采用上述 GHC + 系统依赖方式。

环境变量：`BIND_ADDRESS`（默认 127.0.0.1）、`PORT`（默认 8187）、`BASE_PATH`（默认空）、`STATIC_DIR`（默认 static）。反向代理挂 `/douyin/` 时设置 `BASE_PATH=/douyin`，代理转发应剥离该前缀。默认限制固定在源码中：512 MiB/视频、8 MiB/封面、4 并发解析、4 并发媒体流、500 个结果、令牌 30 分钟、解析 60 秒、媒体总时限 300 秒、上游单次响应空闲超时 30 秒。

## Docker Compose

```sh
cp .env.example .env
docker compose up --build -d
# http://localhost:8187
```

多阶段镜像在构建阶段运行 Haskell 测试，运行镜像仅含二进制、系统动态库、CA 证书和静态资源。服务器部署使用原生 systemd 服务，不需要 Docker，也不会修改服务器容器环境。Docker Compose 配置验证通过；本环境 Docker Hub 网络限制仍影响镜像拉取，镜像构建未作为本次生产部署路径。

## HTTPS、PWA 和部署

当前发布目标为 `https://typed.cn/douyin/`。部署细节与回滚见 [deploy/README.md](deploy/README.md)。Android Chrome 菜单可添加到主屏幕。PWA、剪贴板和 Service Worker 需要 HTTPS（localhost 除外）；离线仅能打开首页，解析与下载必须联网。下载进度交给浏览器管理。

`deploy/douyin-haskell.service` 使用动态低权限用户、256 MiB 内存限制、50% CPU 配额、只读系统和独立私有临时目录。监听 127.0.0.1:8187，不暴露后台端口；`deploy/nginx-location.conf` 仅增加 `/douyin/` 的反向代理，不替换已有首页或 API。

## 解析和安全

- `Parser.hs`：从文案提取允许的抖音链接，处理短链和标准视频链接，解析 `_ROUTER_DATA`，核对作品 ID；缺失作者/封面/时长正常降级。首次框架响应只允许一次同会话补请求，保留平台匿名 Cookie，不绕过验证码。
- `Network.hs`：每一跳验证协议、端口、凭据、域名边界。DNS 只解析 IPv4，拒绝内网、回环、链路本地、保留地址，随后将解析结果固定到实际 TCP/TLS 连接，防止二次 DNS 解析带来的重绑定。IPv6 上游目前不支持。忽略环境代理，不接收用户指定代理或任意下载 URL。
- `App.hs`：媒体接口只接受 256 位随机令牌。限制并发、缓存容量、读取体积和时限；流式读取，不整段缓存视频。支持单段 Range、Content-Type 和中文 Content-Disposition。媒体过期重新解析，超过 4 分钟主动刷新；失败返回中文错误码。
- `View.hs`：Lucid 自动转义用户输入和上游文本。PWA 只缓存自身静态首页和资源，既不缓存结果/媒体，也不删除其他应用的缓存。

视频保持平台原样，可能含水印和片尾。当前样本页面时长 48.734 秒，文件时长 51.733 秒。上游仍可能限流、要求验证或中断传输；流开始后发生错误只能中止下载，浏览器提示失败后可重新解析。结果在进程内存中，重启需要重新解析，多实例部署需要另行增加共享令牌存储与全局限额。

## 验收

```sh
./scripts/build-haskell.sh
# 已启动服务，且安装 ffmpeg 后：
python3 scripts/verify_live.py --base http://127.0.0.1:8187
# 可选浏览器测试工具（非生产依赖）：
python3 -m venv .venv
.venv/bin/pip install playwright
.venv/bin/python -m playwright install --with-deps chromium
.venv/bin/python scripts/browser_check.py --base http://127.0.0.1:8187
```

实测会下载、计算 SHA256 并完整解码；没有用测试素材替代真实视频。测试脚本使用 Python 仅作开发验收工具。历史 React/FastAPI 实现在 Git 历史中，旧验收记录保留于 `docs/verification-v1.md`。
