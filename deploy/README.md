# 独立部署和回滚

目标：Ubuntu 24.04 x86_64，已有 `typed.cn` Nginx HTTPS 站点、婚礼后端 127.0.0.1:8080、MongoDB 127.0.0.1:27017。

新应用布局：

- `/opt/douyin-haskell/releases/<release>/douyin-download` 及 `static/`
- `/opt/douyin-haskell/current` 指向当前发布目录
- `/etc/systemd/system/douyin-haskell.service`
- `/etc/nginx/snippets/douyin-haskell.conf`
- 在已有 typed.cn HTTPS server 中增加一行 `include /etc/nginx/snippets/douyin-haskell.conf;`

发布前记录旧首页 SHA256、`/api/health`、Nginx 主进程、婚礼后端和 MongoDB PID。只上传本地编译包，不在服务器安装 GHC、Docker 或 npm。先启动独立 systemd 服务并从回环验收，再备份原 Nginx 文件、增加 include、执行 `nginx -t` 并 **reload**，不 restart 现有 Nginx。已有 API、首页、证书、防火墙、数据库和其他服务不作配置变更。

之后的应用更新：本地运行 `scripts/build-haskell.sh`，将二进制和 static 上传到新 release；确认动态库可用，再切换 `current` 并重启 **douyin-haskell.service**。失败时将 `current` 指回上个版本并只重启此服务。

首次部署撤销：停止并禁用 `douyin-haskell.service`，从 typed.cn HTTPS server 删除本项目专属 include，`nginx -t` 通过后 reload。可保留发布包和备份以便排查；不要删除或重启婚礼后端、MongoDB 或代理服务。

```sh
systemctl status douyin-haskell
journalctl -u douyin-haskell -n 50 --no-pager
curl http://127.0.0.1:8187/api/health
curl https://typed.cn/douyin/api/health
```

服务器 SSH 密码不写入源码、部署文件或文档。现有 Nginx 配置备份保存在服务器 `/opt/douyin-haskell/backups/`；最终检查结果见 `docs/verification.md`。

当前发布：`20261114-haskell-v2.2`（显式 HTTP/TLS 固定公网 IP 连接器）。初始 v2 发布包保留在 releases 中供审计；不要回退到缺少该 TLS 修复的版本。
