# 真实验收记录

测试日期：2026-11-14（Asia/Shanghai）。环境：Ubuntu 24.04 / Python 3.12 / Node 22.16 / Chromium 159 / FFmpeg 6.1.1。

## 核心结果：真实下载成功

输入：`复制打开抖音，看看这个视频 https://v.douyin.com/1znUsjZNolc/`

- 作品 ID：`7707698168485708904`
- 标题：太强了：一面镜子搞定一部音乐剧 话说这是ai嗓音吧？ 大家觉得呢？
- 作者：大脑壳儿留学@英国🇬🇧
- 页面时长：48.734 秒；下载文件时长：51.733333 秒。直接保存平台提供的含水印视频，文件含平台片尾，未裁剪、未修改或猜测媒体地址。
- 下载：12,650,373 字节，`video/mp4`，720×1280，H.264 + AAC。
- SHA256：`86606f5dde1e43873e5c01d288866bfa5390316a251daaeb1408b5ab94833b73`
- `ffprobe` 正常读取音视频轨道；`ffmpeg -v error -xerror -i <文件> -f null -` 完整解码退出码 0。
- 抽帧核对：镜前表演，画面文字“一面镜子搞定一部音乐剧”，与分享页作品标题对应；作品 ID 从短链接跳转到页面 JSON 全程一致。
- 浏览器真实验收：填写分享文案 → 点击解析 → video 元数据就绪 → 实际播放时间前进 → 点击下载 → 保存 12,650,373 字节文件 → 完整解码通过。没有对真实链路注入模拟响应。
- Range：`bytes=0-1023` 返回 HTTP 206，`Content-Range: bytes 0-1023/12650373`，实际 1024 字节。
- 封面：同源代理返回 HTTP 200、`image/webp`、29,094 字节。

视频文件仅保留在验收机器 `/tmp/douyin-confirmed.mp4` 和 `/tmp/douyin-ui-check/live-download.mp4`，不提交到源码仓库。临时文件可能随环境回收消失，可运行验收脚本重新下载。

## 方案调研与实测

1. [yt-dlp](https://github.com/yt-dlp/yt-dlp/issues/17464)：安装并实测版本 `2026.10.26`，命令如下，返回 `Fresh cookies (not necessarily logged in) are needed`，未取得媒体。

   ```sh
   yt-dlp --skip-download --no-warnings --socket-timeout 15 'https://www.douyin.com/video/7707698168485708904'
   ```

2. [分享页解析思路](https://github.com/aiaoxd/douyinDownloader)：移动 UA 读取 `_ROUTER_DATA.loaderData` 下 `videoInfoRes.item_list`。独立实现解析，无第三方解析服务，生产不依赖 yt-dlp 或浏览器。

3. 初次 curl 探测两个分享域名（含完整分享参数）只返回约 32–35 KiB 框架；公开详情接口返回访问校验错误。后续使用保持 Cookie 的 aiohttp 会话，真实短链连续三个新会话均成功。标准链接新会话首次可能只收到匿名 Cookie 和框架，第二次请求成功。因此最终实现对 `data_missing` 的页面做一次同会话补请求，仍失败则切换分享域名。最终全新会话直接标准链接也解析成功。未设置用户登录 Cookie，没有模拟媒体数据。

4. 初始一次下载遇上游中途断流，服务按设计中止传输；后续独立下载及浏览器下载均成功并完整解码。不能承诺上游永不失败，流开始后的错误交给浏览器报告，用户可重新解析下载。

## 其他验收

- 后端测试：18 passed。覆盖文案提取、标准/分享/modal_id 链接、元数据缺失、ID 不匹配、Cookie 框架补请求、无效输入、模拟超时/登录验证、任意 URL 下载拒绝、私网 DNS、IPv4-mapped IPv6、重定向 SSRF、下载头、大小限制、并发限制、媒体过期刷新、无效 Range。
- 前端：`npm ci && npm run build` 通过，TypeScript 检查通过。
- 浏览器：360、390、430、1280 宽度均无横向溢出；390×844 触控模拟完成真实流程。无效文字输入显示明确错误；通过 Playwright 仅在错误场景注入 HTTP 502 `verification_required`，确认中文错误与重试按钮。上游失败测试是受控注入，不冒充抖音实时返回错误。
- 手机画面人工查看：[首页截图](mobile.png)。真实安卓设备安装 PWA 未测试，HTTPS 生产域名未部署；浏览器设备模拟不能代替真机验收。

## 复现

```sh
# 按 README 启动后
python3 scripts/verify_live.py --output /tmp/douyin-live.mp4
# 浏览器验收（额外的开发依赖，不是生产依赖）
.venv/bin/pip install playwright
.venv/bin/python -m playwright install --with-deps chromium
.venv/bin/python scripts/browser_check.py
```

浏览器脚本当前对真实样本要求成功，若平台限制、作品失效或媒体下载失败会退出非零，不跳过为“成功”。服务端仅连接公网；环境需要直接访问抖音和 CDN，不能依赖被忽略的环境代理变量。

## Docker 检查边界

已安装 Docker 29.1.3，`docker compose config -q` 通过。实际执行 `docker compose build` 在拉取 `node:22-alpine` 基础镜像的 manifest 时失败：`registry-1.docker.io ... dial tcp ...:443: i/o timeout`，尚未执行到项目构建步骤。此为当前环境访问 Docker Hub 的网络限制，不能宣称容器启动已验证。相同源码的原生依赖安装、前端构建、后端启动和真实端到端验收均通过。部署机可访问 Docker Hub 后运行 `docker compose up --build -d` 复现容器验收。

PWA 补充：Chromium 中等待 Service Worker 激活，重新加载缓存静态资源后切换离线，首页仍正常加载；离线解析不支持。
