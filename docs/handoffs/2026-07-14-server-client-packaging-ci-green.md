# 2026-07-14 服务器客户端打包 CI 全绿回执

## 1. 源码与远端门禁

- 分支：`feat/subscription-sync-integration`
- 源码提交：`8f47ea3d80966ce6425c8dfeaa4076cb3a846a7e`
- GitHub Actions run：`29275890356`
- 地址：<https://github.com/Faust7777777/wealth-ledger/actions/runs/29275890356>
- 结论：成功。

成功 job：

- `Verify source before packaging`
- `Verify Linux VPS topology`
- `Package Windows`
- `Package Windows server client`
- `Package Android server client`

Android 只读 preview 按 workflow 输入跳过，不是失败。

## 2. 本轮修复

- `8fa4a18`：Android PowerShell 打包脚本改用跨平台测试与 APK 路径。
- `8f47ea3`：显式注入 endpoint 文件时，在所有非 Android 平台复用文件 JSON
  序列化路径，修复 Linux CI 把 JSON 原文当作 API origin 返回的问题。

Android job 已实际穿过 18 条 runtime endpoint/auth/data-source 专项测试并完成 APK
构建，证明两处 Linux 兼容问题均已关闭。

## 3. 已下载并核验的 artifacts

本机下载目录：`C:\tmp\finwealth-actions-29275890356`

### Windows 本地成对自用包

- 文件：`finwealth-1.0.0+1-20260713-185534-windows-self-use-x64.zip`
- SHA-256：`2b8ba7eddd9678c74c74df7f9766b4e2ccf321c610527e0b50bb3ac72224173e`
- 包内包含 Flutter 客户端、`server/finwealth-server.exe`、启动器和 manifest。
- 此包不依赖 VPS；首次运行由启动器设置本地用户名和密码。

### Windows 通用服务器客户端

- 文件：`finwealth-1.0.0+1-20260713-185502-windows-server-client-x64.zip`
- SHA-256：`826b08105023d059ea8408624e3918f21a1ecd1ac57a02f5a2fe21367ec9eca5`
- 包内不含 Rust server；首次启动填写真实 HTTPS API origin。

### Android 通用服务器客户端

- 文件：`finwealth-1.0.0+1-20260713-185619-android-server-client-debug.apk`
- SHA-256：`a36ea1ec4305bdcbc951afa1a90ef9caccf143fa22cfed5dbe6fd9311c4d3cfc`
- manifest：`sourceCommit=8f47ea3d80966ce6425c8dfeaa4076cb3a846a7e`、
  `sourceDirty=false`、`dataSource=api_remote`、`endpointMode=runtime`、
  `networkPolicyVerified=true`。
- 仍为 debug self-use 签名；升级必须复用同一签名密钥。

三个文件的 `.sha256` sidecar 均已与本机实际 SHA-256 比对一致。

## 4. 当前可用边界

- 无 VPS 资料时，可先使用 Windows 本地成对自用包，后端为真实 Rust/Axum JSON
  持久化服务，不是 mock。
- Windows/Android 跨设备通用客户端仍需真实 VPS、API 域名和 HTTPS 反代。
- VPS 上线尚需用户提供 SSH 目标、本机私钥路径和 API 域名；不得提供私钥内容或
  密码。拿到这些信息后才能完成公网登录、订阅扫描、确认扣款、重启持久化和备份恢复
  的最终验收。
