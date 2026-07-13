# 2026-07-14 服务器模式可部署回执

## 1. 基线

- 分支：`feat/subscription-sync-integration`
- 服务器模式实现提交：`bede585276826758a4f266737738c412e0681648`
- 目标架构：Windows/Android 在线客户端通过 HTTPS 访问同一台 VPS 上的 Rust
  `ledger.json` 事实源。
- 在线共享账本不依赖尚未完成的离线多账本 merge。

## 2. 本轮解除的不可用阻断

- `DATA_SOURCE=api_remote` 现在真实选择 HTTP auth 与全部账本 repository，不再回落到
  `real_local` 空实现。
- 远端模式显示服务登录、使用 DPAPI token store、启用定时行情刷新，且不显示 DEV 横幅。
- 新增 HTTPS-only Windows server-client 打包器、完整性 launcher、manifest、source
  provenance 和 zip SHA-256。
- GitHub Package workflow 支持可选 `remote_api_base` 输入；本地也可直接运行打包脚本。
- Rust 新增 `--check-production-config`，强制 auth、Argon2、loopback bind、公共 Host
  allow-list、关闭 scenario，并拒绝未知 quote provider。
- 认证 token 签发、旋转、logout、设备撤销必须先成功持久化；写入使用同步临时文件与
  原子 rename。损坏 auth 状态拒绝启动，不再静默清空。
- VPS installer 在启动服务前运行生产配置校验；新增一键 readiness，验证权限、账本、
  auth、systemd、loopback 监听和公网 HTTPS health。
- 新增服务器模式算法文档，明确金额符号、atomic group、多腿更正、订阅日历、净值、
  幂等、认证和恢复口径。

## 3. 已运行门禁

- Rust：112 passed；rustfmt、Clippy `-D warnings` 通过。
- Flutter：101 passed / 16 skipped；format、analyze 通过。
- `api_remote`/auth 专项：12 passed。
- OpenAPI/Markdown/packaging contract check：通过，116 schemas。
- mock/dev/Rust API smoke、real-local ledger smoke：通过。
- Flutter↔Rust 订阅真实联调：2 passed。
- Windows 本地 backup/restore rollback smoke：通过。
- paired package integrity smoke：通过。
- production config CLI 使用有效临时 Argon2 配置实跑通过，未输出哈希。
- remote Windows 包完整构建两次；staged 和解压后 launcher integrity 均通过。

占位域名构建产物仅用于打包烟测，不是用户交付包。实际交付必须使用用户最终 HTTPS
API origin 重新构建。

## 4. 部署入口

VPS：

```bash
git clone --branch feat/subscription-sync-integration --single-branch \
  https://github.com/Faust7777777/wealth-ledger.git
cd wealth-ledger
sudo bash tools/install_vps_systemd.sh
```

配置 `/etc/finwealth/server.env` 与 Caddy 后：

```bash
sudo bash tools/check_vps_readiness.sh \
  --public-base-url https://api.example.com
```

Windows server client：

```powershell
pwsh -NoProfile -File tools\package_remote_windows.ps1 `
  -ApiBase https://api.example.com `
  -OutputDir C:\tmp\finwealth-server-client
```

解压后运行 `Start-Finwealth.cmd`。

## 5. 仍需外部部署信息

要完成真实上线和最终客户端包，需要用户提供或在服务器上执行：

- VPS SSH 入口（或由用户执行命令并回传脱敏结果）。
- 最终 HTTPS API 域名。
- DNS 已指向 VPS，80/443 可用。
- 由用户在 VPS 交互式输入的登录密码；密码和生成的 Argon2 hash 不回传、不写仓库。

不需要提供账本内容、token、密码、私钥或 API key。
