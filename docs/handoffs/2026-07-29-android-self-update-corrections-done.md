# 2026-07-29 Android 应用内更新 · 发布阻塞项修正回执

执行对象：Claude（前端线）。对应修正单
`docs/handoffs/2026-07-29-claude-android-self-update-corrections.md`。

审阅基线：`feat/android-self-update @ e51f345`。
分支：`fix/android-self-update-corrections`（从该分支新建）。
边界核对：对 `server-rs`、`docs/contracts`、部署与发布脚本的改动为空。
`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `de01fe1` | P0.1 / P0.2 / P0.3 / P1 与窄校验 |
| `3edc8d8` | 17 条新测试 + 既有行测试适配 + golden 重生成 |
| （最后一笔） | 本回执 |

## 2. P0.1 启动触发静默检查

**代码位置**

- `lib/app/app.dart`：`_WealthLedgerAppState` 新增一次性闩锁
  `_startupUpdateCheckScheduled`。在 `build` 里、远端已配置的分支中，
  当 `clientUpdateServiceProvider != null` 时用 `addPostFrameCallback`
  触发一次 `checkSilently()`，`unawaited` 调用因此不阻塞首屏。
  未配置远端时该分支上方已 `return` 到 `RemoteServerSetupPage`，
  所以"未配置不请求、配置完成后第一次命中"是同一段逻辑的自然结果。
- `lib/features/app_update_row.dart`：**删除**了 `initState` 里的
  `checkSilently()`。设置行现在只调 `loadInstalledVersion()`——
  纯本地平台调用，不产生任何网络请求。
- 闩锁在 `State` 上，rebuild、切主题、切路由都不会重新初始化。

**测试**（`test/client_update_corrections_test.dart` → `group('P0.1 启动静默检查')`）

1. `Android 启动后不进设置页也恰好检查一次`
2. `rebuild 与切主题不产生第二次请求`（切两次主题后仍为 1）
3. `非 Android：零次请求`
4. `未配置远端零次；配置完成后一次`（用 `container.updateOverrides` 把环境
   从未配置切到已配置的 HTTPS 远端）

## 3. P0.2 拒绝非 HTTPS API origin

**代码位置**

- `lib/data/client_update.dart` 新增 `requireHttpsOrigin(String)`：
  `scheme == 'https'`、host 非空、无 `userInfo`、无 query/fragment、
  且路径为空或仅 `/`；否则抛 `ClientUpdateRejected('服务器地址不可用于更新')`。
  `resolveUpdateAssetUrl` 第一步就调用它，asset 侧的相对路径校验保持不变。
- `lib/features/app_update_controller.dart` 的 `clientUpdateServiceProvider`
  现在要求 **Android + `DataSourceMode.apiRemote` + 已配置 + 合法 HTTPS**，
  否则返回 `null`。local_server / DEMO 因此不会向 loopback HTTP 检查更新，
  也不存在"调试模式绕过生产门禁"的路径。设置行的显示门控同步改为看服务是否存在。

**测试**（`group('P0.2 HTTPS origin 门禁')`）

- `非 HTTPS origin 一律拒绝`：`http://wuwaidut.com`、`http://127.0.0.1:8791`、
  `ftp://`、无 scheme、空串。
- `带 userInfo / query / fragment / 业务路径的 base 被拒绝`。
- `干净 HTTPS origin + 合法相对资源保持同源`。
- `更新服务只在 Android + apiRemote + HTTPS 下存在`（四种组合逐一断言）。

## 4. P0.3 失败与极早取消不遗留半包

**代码位置**：`lib/data/client_update.dart` 的 `download()` 重写。

- 整个下载包在 `try/catch` 中；**任何**失败路径（非 200、流错误、sink 错误、
  取消、大小/SHA 不符）都走同一段收尾：先 `await sub?.cancel()`，
  再 `await sink.close()`，最后 `file.deleteSync()`。
- 取消信号先 `await sub.cancel()` 再让主流程收尾，**不会在订阅仍写入时删文件**；
  chunk 回调也会在 `cancelled` 后直接返回，不再写入已关闭的 sink。
- 请求发出前与订阅建立前各有一次极早取消检查：后者 `drain` 掉响应体后退出，
  不打开 sink、不落任何文件。
- 非 `ClientUpdateRejected` 的异常统一归一成"下载失败，请重试"，不外泄内部错误。
- 成功路径仍是逐块写盘 + 逐块 SHA-256，APK 不整包进内存。

**测试**（`group('P0.3 失败与取消不得遗留半包')`）

1. `收到首块后 stream 抛错：目录为空`
2. `极早取消（订阅建立前）：不下载、不遗留文件`
3. `下载中取消：等订阅终止后删除半包`
4. `非 200 响应：不落文件`
5. `成功路径仍是逐块写盘`（断言进度仍是 `[2, 4]`）

原有的正常取消、大小不符、SHA 不符三条测试（`client_update_test.dart`）继续通过。

## 5. P1 授权返回后的动作

`AppUpdateController.refreshInstallPermission()`：仅在 `needsPermission`
阶段生效，重新查询 `canInstallPackages()`，已授权则切回 `readyToInstall`。
`AppUpdateRow` 注册 `WidgetsBindingObserver`，在 `resumed` 时调用它。
按钮文案由「去授权」改为「继续安装」。
测试：`group('P1 授权返回') → resume 后权限已开：直接进入可安装态`
（先断言未授权时保持原状，再断言授权后进入可安装态）。

## 6. 窄校验

`parseClientUpdateManifest` 现在拒绝：`versionCode <= 0`、`sizeBytes <= 0`、
非 64 位十六进制的 SHA-256、Android 平台下不安全的资源文件名
（要求 `^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$`，因此 `../evil.apk`、`evil.exe`、
`.hidden.apk`、含空格的名字都被拒）。失败统一抛
`ClientUpdateRejected('更新信息不完整')`，UI 只停在更新行错误态。
大写十六进制摘要视为合法并归一成小写（有断言）。

## 7. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- 更新专项测试：`client_update_test` 16 条、`client_update_corrections_test`
  17 条、`app_update_row_test` 7 条，全绿。
- `flutter test`：**352 passed / 73 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_remote_android.ps1 -CheckReadinessOnly`：
  `Android server client readiness passed (endpoint mode: runtime)`。
- `git diff --check`：零输出。

## 8. 视觉证据

`app_update_up_to_date_{dark,light}`、`app_update_available_{dark,light}` 重新生成
并肉眼核验：仍是当前版本 + 状态 + 摘要 · 包大小 + 动作，没有 SHA、路径或 endpoint。

## 9. 说明与未完成项

- 设置行现在**只在有更新能力时出现**（Android + 远端 HTTPS）。
  本地服务模式下这一行不再显示——这是 P0.2 要求的副产品，
  也避免了"点检查更新但永远失败"的死路。
- 按修正单，本批仍未启动 AVD；`+2 → +3` 真实覆盖升级由 Codex 合入后执行。

本回执不含 token、密码、认证文件内容或真实账本数据。
