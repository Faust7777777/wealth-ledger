# 2026-07-14 预编译 VPS Server Bundle 交付回执

## 1. 源码与 CI

- 分支：`feat/subscription-sync-integration`
- 源码提交：`55028e21b0cde4f820321dfb22b7c0bfd7213960`
- GitHub Actions run：`29278779742`
- 地址：<https://github.com/Faust7777777/wealth-ledger/actions/runs/29278779742>
- 结论：成功。

本轮成功门禁包括源码总门禁、Linux VPS topology、Windows 本地成对包、Windows
通用服务器客户端和新的 `Package Linux VPS server`。Android jobs 按本轮 workflow
输入跳过，不是失败。

## 2. 最终 Linux VPS Bundle

- 本机路径：
  `C:\tmp\finwealth-vps-static-29278779742\finwealth-server-0.1.0-20260713-193728-linux-x86_64-vps.tar.gz`
- 大小：3,483,474 bytes
- SHA-256：`37ee43d99c771caced6b739f08c7adc5271613e6f6872546e6dd7b37c274ade7`
- artifact：`finwealth-linux-x86_64-vps-server`

manifest：

- `sourceCommit=55028e21b0cde4f820321dfb22b7c0bfd7213960`
- `sourceDirty=false`
- `target=x86_64-unknown-linux-musl`
- `libc=musl`
- `linkage=static`

## 3. 独立核验

- 外层 `.tar.gz.sha256` 与实际文件一致。
- 解包后内部 `SHA256SUMS` 全部通过。
- `install_vps_bundle.sh --check-bundle-only` 通过。
- ELF 为 `static-pie linked`，没有动态 program interpreter。
- 独立执行 `--hash-password-stdin` 成功。
- bundle 篡改测试会被内部 SHA-256 校验拒绝。

此前 run `29278091306` 生成的动态 glibc bundle 已被本包取代，不应部署。

## 4. Bundle 内容与安装边界

bundle 包含：

- 预编译 `finwealth-server`；
- systemd unit 和生产环境示例；
- 无 Rust/Cargo 安装依赖的 bundle installer；
- readiness、备份和恢复脚本；
- 部署文档、来源 manifest 和内部 SHA-256 清单。

安装器会拒绝错误 CPU 架构或损坏文件，保留现有 `/etc/finwealth/server.env` 与账本；
配置仍含 `change-me` 时只安装不启动。生产配置完成后，启动前仍通过 systemd 执行
`--check-production-config`。

## 5. 真实上线剩余阻塞

- 已定位 VPS：`47.254.66.246`。
- 已定位 HTTPS 域名：`zhixuanyun.cc`，DNS 指向该 VPS。
- 现有 Nginx 提供 HTTPS，`/v1/health` 当前为空闲 404，可挂载 Finwealth `/v1/*`。
- 本机现有 SSH 别名与密钥均被服务器拒绝；必须先通过阿里云控制台恢复公钥登录。

恢复登录后可直接上传本 bundle，无需在 VPS 安装 Rust，然后完成 systemd、Nginx、认证、
真实订阅扣费、重启持久化和备份恢复验收。
