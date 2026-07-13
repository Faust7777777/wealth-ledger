# 2026-07-14 通用服务器客户端交付回执

## 1. 源码

- 分支：`feat/subscription-sync-integration`
- 客户端实现提交：`cb70486742c0e87b686818dd125ce070bff4b82d`
- 打包门禁提交：`2008da0aca53571d9a1591a9f406bb822d62d2a9`
- 两个平台产物均由干净的 `2008da0` 构建，`sourceDirty=false`。

## 2. Windows 通用服务器客户端

- 路径：`C:\tmp\finwealth-server-clients-20260714-final\finwealth-1.0.0+1-20260714-014204-windows-server-client-x64.zip`
- 大小：18,542,081 bytes
- SHA-256：`a7cadfb0a1d7c19b0b90bd4c266bb54a34aa08ae7ffb516c8fba01c7952f10e5`
- sidecar：同路径追加 `.sha256`

核验：

- staged 与解压后的 launcher integrity 均通过。
- manifest/build config：`endpointMode=runtime`、空编译期 API origin、上述 source
  commit、`sourceDirty=false`。
- 包内无 Rust server、ledger、auth、server endpoint 用户配置或 launcher 用户配置。
- 解压后运行 `Start-Finwealth.cmd`，首次启动在应用内填写 HTTPS origin。

## 3. Android 通用服务器客户端

- 路径：`C:\tmp\finwealth-server-clients-20260714-final\finwealth-1.0.0+1-20260714-014253-android-server-client-debug.apk`
- 大小：159,555,743 bytes
- SHA-256：`ad52bcbddf8e98830410230e87c9adc5b582b3e640f45feb18c5acd111598d64`
- sidecar：同路径追加 `.sha256`
- provenance：同路径追加 `.manifest.json`

核验：

- manifest sidecar 的 APK hash、source commit、clean 标记和 runtime endpoint 模式匹配。
- 使用 `apkanalyzer` 独立确认编译后 APK 包含 INTERNET 权限、
  `usesCleartextTraffic=false`、`allowBackup=false`。
- 服务器地址存入 app-private preferences；token 使用 Android Keystore AES-GCM。
- 当前 APK 使用 debug self-use 签名。后续更新必须使用同一 debug keystore；正式分发前
  应改为用户持有并备份的 release signing key。

## 4. 运行时服务器切换规则

- 只接受无 credentials/path/query/fragment 的 HTTPS origin。
- 保存前必须通过公开 `/v1/health`。
- 健康检查失败不保存地址、不清除现有 token。
- 切换到不同 origin 时，先清除旧 token，再激活新地址，避免跨主机发送凭证。
- Windows 保存于 `%APPDATA%\Finwealth\server.json`；Android 保存于 app-private
  SharedPreferences。地址配置不包含密码或 token。

## 5. 门禁

- Flutter format/analyze：通过。
- Flutter：105 passed / 16 skipped。
- runtime endpoint/auth 专项：18 passed。
- Android `api_remote` debug build：通过。
- Windows universal remote build：通过。
- Windows fixed endpoint、Android fixed endpoint readiness：均通过。
- OpenAPI/Markdown/deploy/package contract check：通过，116 schemas。
- PowerShell parser、workflow YAML parser、`git diff --check`：通过。

## 6. 使用边界

- 这两个客户端不包含服务器或账本；必须先部署 VPS Rust 服务与 HTTPS 反代。
- 初次连接后在设置中使用 VPS 配置的用户名和密码登录。
- 当前 Android APK 适合个人测试安装，不是商店签名版本。
- 此前 `api.example.com` 占位构建与 dirty-source smoke 产物均不是交付物。
