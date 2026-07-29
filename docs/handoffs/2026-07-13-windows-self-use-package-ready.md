# 2026-07-13 Windows 自用包交付回执

## 1. 产物

- 源分支：`feat/subscription-sync-integration`
- 源提交：`7a99c9aa875901a372e77b36f4f9178c23bfb5cc`
- 客户端版本：`1.0.0+1`
- 服务端版本：`0.1.0`
- 数据源：`local_server`
- API：`http://127.0.0.1:8791`
- Windows zip：`C:\tmp\finwealth-package-20260713\finwealth-1.0.0+1-20260713-221608-windows-self-use-x64.zip`
- SHA-256 sidecar：同路径追加 `.sha256`
- zip 大小：21,714,054 bytes
- zip SHA-256：`9607925dd0f309d018b61482649fbfba632fc51a1adfe6b5813cd9d17890abc5`

该 zip 未提交 Git、未上传 GitHub Release，也未合并 `main`。

## 2. 构建与完整性结果

- 源工作树在构建前干净。
- package readiness 的 auth/idempotency 行为测试：10 passed。
- launcher package integrity smoke：通过，且篡改后的 dummy client 被拒绝。
- Rust release server 构建：通过。
- Flutter Windows release 构建：通过。
- staged package launcher 完整性检查：通过。
- zip 解压后的 launcher 完整性检查：通过。
- `.zip.sha256` 与独立计算的 zip SHA-256 一致。
- zip 共 27 个条目；未发现 `ledger.json`、`ledger.auth.json`、
  `launcher.config.json` 或 server 用户日志。
- `package-manifest.json` 与 `finwealth.build-config.json` 均记录
  `sourceCommit=7a99c9a...`、`sourceDirty=false`、bundled server 和 loopback API。

## 3. 本次构建前已通过的集成门禁

- Flutter format、analyze、93 个全量测试。
- Rust 108 个测试、rustfmt、Clippy `-D warnings`。
- OpenAPI/Markdown contract check。
- mock/dev/Rust server smoke。
- real-local ledger smoke。
- Flutter↔Rust 订阅真实联调 2 条。
- Windows 本地账本/auth 备份、恢复和失败回滚 smoke。

## 4. 使用方式

1. 将 zip 复制到需要长期保存的位置，并同时保留 `.sha256` 文件。
2. 完整解压到普通用户可写目录。
3. 不要直接运行 `finwealth.exe`；双击 `Start-Finwealth.cmd`。
4. 首次启动设置本地用户名和密码，然后在客户端登录。
5. 用户数据保存在 `%LOCALAPPDATA%\Finwealth`，不在解压目录内。
6. 备份或恢复前先关闭 launcher。

## 5. 边界

- 本产物是未签名的自用 zip，SHA-256/manifest 能检测损坏或混包，不能替代发行者代码签名。
- 未构建 Android 可写版本；Android 仍仅允许明确标记的只读预览。
- 订阅功能不会调用 OpenAI、Anthropic 等服务商的真实支付、续费或退订 API。
- 尚未完成 account update、通用多实体入站同步、逐设备 delivery receipt 或 E2EE。

