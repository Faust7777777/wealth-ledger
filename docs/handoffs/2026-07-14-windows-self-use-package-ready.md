# 2026-07-14 Windows 自用包交付回执

## 1. 产物

- 源分支：`feat/subscription-sync-integration`
- 源提交：`9d2d611f159903f9cb031f81b580ff07c7c691a9`
- 客户端版本：`1.0.0+1`
- 服务端版本：`0.1.0`
- 数据源：`local_server`
- API：`http://127.0.0.1:8791`
- Windows zip：`C:\tmp\finwealth-package-20260714\finwealth-1.0.0+1-20260714-003325-windows-self-use-x64.zip`
- SHA-256 sidecar：同路径追加 `.sha256`
- zip 大小：21,718,459 bytes
- zip SHA-256：`f25cc222ffca9392a2a990f3415c2a48afed2a0b4148a6b889f626cfe577a61e`

此前 `20260713-221608` Windows 包已作废，不应继续分发或使用。本次新 zip
未提交 Git、未上传 GitHub Release，也未合并 `main`。

## 2. 本次集成内容

- 合入桌面可用性修复：压缩桌面记录操作入口，删除常驻解释性文案。
- 合入原子多腿交易更正后端：保留原 movement，不改写已确认历史；更正确认时
  原子追加全部反向腿与 replacement 腿，并写入 sync outbox。
- 保留订阅到期扫描、取消门控、认证设备 `account/create` 入站同步和 Windows
  本地服务启动链路。

## 3. 门禁与独立核验

- Flutter format、analyze：通过。
- Flutter 全量测试：99 passed / 16 skipped。
- Rust 全量测试：109 passed；rustfmt、Clippy `-D warnings` 通过。
- OpenAPI/Markdown contract check：通过，共 116 schemas。
- mock/dev/Rust server smoke、real-local ledger smoke：通过。
- Flutter↔Rust 订阅真实联调：2 passed。
- package integrity smoke、Windows package readiness：通过。
- Rust release server、Flutter Windows release 构建：通过。
- staged package 与 zip 解压后的 launcher 完整性检查：通过。
- `.zip.sha256` 与独立计算结果一致。
- manifest 与 build config 均记录上述 source commit，且 `sourceDirty=false`。
- 包内未发现 `ledger.json`、`ledger.auth.json`、`launcher.config.json` 或 server
  用户日志。

## 4. 使用方式

1. 同时保存 zip 和 `.sha256` 文件。
2. 完整解压到普通用户可写目录。
3. 不要直接运行 `finwealth.exe`；双击 `Start-Finwealth.cmd`。
4. 首次启动设置本地用户名和密码，然后在客户端登录。
5. 用户数据保存在 `%LOCALAPPDATA%\Finwealth`，不在解压目录内。
6. 备份或恢复前先关闭 launcher。

## 5. 边界

- 这是未签名的自用 zip；SHA-256 与 manifest 可检测损坏或混包，但不能替代
  发行者代码签名。
- 未构建 Android 可写版本；Android 仍仅允许明确标记的只读预览。
- 订阅功能不会调用 OpenAI、Anthropic 等服务商的真实支付、续费或退订 API。
- account update、通用多实体入站同步、逐设备 delivery receipt 与 E2EE 尚未完成。
