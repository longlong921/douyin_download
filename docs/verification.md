# Haskell v2 验收与部署记录

时间：2026-11-14，Asia/Shanghai。线上地址：**https://typed.cn/douyin/**。

## 技术迁移

生产进程是本地 GHC 9.4.7 编译的 Haskell 原生二进制。Warp/WAI 处理 HTTP，Lucid 渲染前端和表单，http-client-tls 请求平台，独立 `Parser` 模块解析作品；随机令牌、并发和缓存由 Haskell 实现。React、Vite 和 FastAPI 运行代码已移除，旧实现可由 Git 历史恢复。

浏览器只用原生 HTML 表单/video/download，并有少量渐进增强 JS（剪贴板、加载文字、PWA）。禁用 JavaScript 后的表单错误提示已验证正常。Python 仅用于离线验收脚本，不是部署依赖。

## 真实解析和下载

测试分享内容：`复制打开抖音 https://v.douyin.com/1znUsjZNolc/`。

- 作品 ID：`7707698168485708904`
- 标题：太强了：一面镜子搞定一部音乐剧 话说这是ai嗓音吧？ 大家觉得呢？
- 作者：大脑壳儿留学@英国🇬🇧
- 平台元数据时长：48.734 秒。原样媒体含平台片尾，实际时长 51.733333 秒。
- 12,650,373 字节，MP4，720×1280，H.264 视频 + AAC 音频。
- SHA256：`86606f5dde1e43873e5c01d288866bfa5390316a251daaeb1408b5ab94833b73`
- Haskell 本地 API 和线上 HTTPS API 均实际下载并通过 `ffmpeg -v error -xerror ... -f null -` 完整解码，哈希与迁移前版本一致。
- 本地及线上浏览器真实完成分享文案提交、预览实际播放、下载、完整解码；没有模拟媒体替代。线上浏览器保存文件的大小、SHA256 和解码结果均一致。
- 平台本次媒体跳转至 `v3-dy-o.zjcdn.com`，已加入媒体 CDN 域名列表；所有重定向仍校验域名和实际连接 IP。

命令行验收：

```sh
python3 scripts/verify_live.py --base https://typed.cn/douyin --output /tmp/douyin-haskell-production.mp4
```

## 安全和界面

36 项 Haskell 检查通过：分享内容/视频 ID 提取、字段缺失、作品 ID 不匹配、缺少数据、内网/回环/保留 IP、伪造域名/凭据/端口/协议、连接前实际 IP 拒绝、单段 Range、并发限制和异常释放、响应体限额、上游 403/429/404/503 分类、表单文本 HTML 转义。

手机模拟 360、390、430 和桌面 1280 宽度无横向溢出。截图见 [mobile.png](mobile.png)。生产 PWA scope 为 `https://typed.cn/douyin/`；实际验证静态首页离线可打开，激活 Service Worker 不删除其他站点缓存。尚未做真实安卓设备安装测试。

当前测试环境 Chromium 直接解析 typed.cn 时超时；在测试浏览器里通过 `--host-resolver-rules` 将该域名固定到用户指定的 `1.15.171.142` 后，页面、TLS 和静态资源加载正常。未更改服务器或系统 DNS，也未关闭 HTTPS 证书校验。复现命令：

```sh
.venv/bin/python scripts/browser_check.py --base https://typed.cn/douyin --resolve-ip 1.15.171.142
```

## 既有服务保护

服务器 Ubuntu 24.04 x86_64；原有 Nginx、婚礼后端和 MongoDB。新增内容：

- `/opt/douyin-haskell/releases/20261114-haskell-v2.2/` 以及 `current` 链接。
- 独立 `douyin-haskell.service`，动态非 root 用户，回环 `127.0.0.1:8187`。
- CPU 配额 50%，内存硬上限 256 MiB，Haskell heap 上限 192 MiB。实测常驻约 13–35 MiB，验收期间自动重启次数 0。
- `/etc/nginx/snippets/douyin-haskell.conf`；原 HTTPS server 仅新增该文件的 include。`nginx -t` 成功后 reload，未 restart 原有服务。
- 原 Nginx 配置备份：`/opt/douyin-haskell/backups/wedding.before-20261114-haskell-v2.conf`。

部署前后原服务进程一致：Nginx 主进程 `1309328`，婚礼后端 `1563789`，MongoDB `3357008`；均 active。原 `/api/health` 仍返回 `{"message":"ok"}`。原站首页 SHA256 前后一致：

```text
905012ae1c28f624650f95b2e3ed3d42feaf60e8a60eb4a83af6ab5488b89c2b
```

未修改原 API 路由、数据库、证书、防火墙、现有服务 unit 或代理配置。没有在服务器安装编译器、npm、Docker，也没有重启服务器。密码未写入仓库和部署文件。

## 构建边界

`./scripts/build-haskell.sh` 使用 Ubuntu 系统 GHC 依赖编译和测试成功。Cabal 项目文件已提供；本环境 Hackage 安全索引报签名校验错误，未将 Cabal 在线构建计为通过。Docker Compose 配置检查通过；实际生产使用已验证的原生二进制 + systemd，不依赖 Docker Hub 构建。

安全复核：检查 http-client-tls 源码发现其默认 TLS 连接器忽略 hostAddress，因此最终实现同时替换 HTTP/TLS 连接器：显式创建 socket 连接经验证的公网 IPv4，再通过 connectFromSocket 按原域名做 TLS/SNI 和证书验证。加入连接器直接拒绝私网目标测试；最终部署为 v2.2，只重启了本项目服务。

版本说明：v2.1 已完成线上安全连接器的真实浏览器端到端验收；v2.2 仅增加标准链接原始页面的匿名 Cookie 初始化，短链接和媒体流路径未变。标准链接与短链接都使用独立会话，Cookie 不跨用户共享。

最终 v2.2 线上补测：直接标准 URL `https://www.douyin.com/video/7707698168485708904` 返回匹配作品 ID；`Range: bytes=0-1023` 返回 206、`Content-Range: bytes 0-1023/12650373`、1024 字节；封面 200、image/webp、29,094 字节。最终 Nginx/婚礼后端/MongoDB PID 与部署前一致，首页哈希和原 API 健康检查再次通过。

线上 stripped 二进制 SHA256：`daf8328964d08cdad53a8c3260d96942e2028092c0757473b0ac84e4139a2dd9`。发布配置和回滚说明见 `deploy/README.md`。
