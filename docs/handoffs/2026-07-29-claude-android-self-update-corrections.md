# Claude 修正单：Android 应用内更新发布阻塞项

日期：2026-07-29
审阅基线：`feat/android-self-update @ e51f345`
修正分支：从 `origin/feat/android-self-update` 新建，不要改后端、契约、部署和发布脚本。

## 审阅结论

Android 原生边界合格：`REQUEST_INSTALL_PACKAGES` 是唯一新增权限；FileProvider 为 `exported=false`；只映射 `cache/updates/`；`openInstaller` 使用 canonical path 且要求直接父目录等于受控目录；更新请求与 bearer/refresh 链隔离。当前没有原生侧 Critical/High 安全问题。

以下三项属于发布 P0。全部修好前 Codex 不合入、不发布 `+3`。

## P0.1 真正从 App 启动触发静默检查

当前唯一的 `checkSilently()` 调用位于 `AppUpdateRow.initState()`。用户不进入设置页就永远不会检查更新，不符合“App 启动后静默检查一次”。

要求：

- 在已配置远端 API 后，由 `WealthLedgerApp` 的启动生命周期触发一次；不要依赖设置页被构建。
- 删除设置行里的重复启动触发，或证明全局门控不会产生第二个请求。
- 不阻塞首屏；失败不弹窗、不改登录态。
- 同一进程的 rebuild、主题切换和路由切换不得重复请求。
- 非 Android 不发请求；远端地址尚未配置时不发请求，配置成功后应触发一次。

必测：

1. Android 启动后不打开设置页，也恰好请求一次 latest。
2. 根组件 rebuild/切主题后仍只有一次。
3. 非 Android为零次。
4. 未配置远端为零次，配置完成后一次。

## P0.2 在客户端门禁中拒绝非 HTTPS API origin

`resolveUpdateAssetUrl()` 目前只校验 asset 是相对路径，随后直接 `Uri.parse(apiBaseUrl).replace(...)`；传入 `http://wuwaidut.com` 仍会被接受。任务单明确要求拒绝非 HTTPS origin。

要求：

- base 必须是合法 HTTPS origin：`scheme == https`、host 非空、无 userInfo、无 query/fragment，且不能携带业务路径。
- asset 继续只接受单斜杠开头的同源相对路径，拒绝绝对 URL、`//`、`.`、`..`。
- local-server/debug 模式不要绕过生产门禁；可让更新 provider 仅在 Android `apiRemote` 模式存在，避免向 loopback HTTP 检查更新。

必测：

- `resolveUpdateAssetUrl('http://wuwaidut.com', '/v1/...apk')` 必须拒绝。
- HTTPS origin + 合法相对资源仍保持同源。
- 带 userInfo、query、fragment 或路径的 base 被拒绝。

## P0.3 流失败与极早取消必须删除半包

当前 `await done.future` 抛出 stream error 时只关闭 sink，后续删除与摘要校验不会执行，私有 cache 会遗留半包。取消 future 如果在 `sub = response.stream.listen(...)` 前完成，回调看到 `sub == null`，随后订阅仍可能继续向已关闭 sink 写入。

要求：

- 网络错误、stream error、sink error、取消、大小/SHA 不符：全部关闭响应订阅和 sink，并删除临时文件。
- 取消应等待订阅终止；不得在订阅仍写入时删除文件。
- 极早取消（含订阅建立前）不得继续下载或遗留文件。
- 成功路径仍是逐块写盘和逐块 SHA-256，不得改成整包进内存。

必测：

1. 收到首块后 stream 抛错，最终目录为空。
2. 调用 download 后立即 cancel，最终目录为空且底层订阅停止。
3. 正常取消、大小不符、SHA 不符既有测试继续通过。

## P1：授权返回后的动作文案

当前进入 `needsPermission` 后按钮始终显示“去授权”。用户从系统授权页返回，即使权限已打开，仍看到“去授权”，再次点击才实际打开安装器。

在 App resume 时重新检查权限，或将返回后的动作明确呈现为“继续安装”。不要增加解释性常驻文案。

## 建议追加的窄校验

- manifest 的 `versionCode > 0`、`sizeBytes > 0`。
- SHA-256 必须为 64 位十六进制。
- Android asset 文件名应是安全的版本化 `.apk` 文件名。

这些校验失败统一停留在更新行错误态，不展示内部字段。

## 回交门禁

- `dart format --output=none --set-exit-if-changed lib test integration_test`
- `flutter analyze`
- 更新专项测试。
- `flutter test` 全量。
- 两个既有 smoke。
- `tools/package_remote_android.ps1 -CheckReadinessOnly`。
- `git diff --check`。

回执需逐项说明 P0.1–P0.3 的代码位置与测试名。仍不要求本批启动 AVD；真实 `+2 -> +3` 覆盖升级由 Codex 在合入后执行。
