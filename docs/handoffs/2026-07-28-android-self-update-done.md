# 2026-07-28 Android 应用内更新 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-28-claude-client-self-update.md`。

基线：`origin/feat/client-self-update @ 6a5d887`。
分支：`feat/android-self-update`，独立工作树 `finwealth-android-update`。
边界核对：对 `server-rs`、`docs/contracts`、Caddy/部署/发布脚本的改动为空；
只改 Flutter `lib/**`、`test/**`、`android/**`、`pubspec.yaml`。
`git diff --check` 零输出。Windows 更新 helper 本批未做，也没有在 Flutter 里
伪造任何 Windows 自动替换。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `fefe328` | 版本提升、更新服务、设置页更新行、Android 通道与 Manifest |
| `0d4b5a2` | 23 条专项测试（含一条既有失败的顺带修复） |
| `2d1e4c0` | 更新行 golden（明暗各两态） |
| （最后一笔） | 本回执 |

## 2. 依赖与 Android 侧改动（重点审计项）

**新增依赖只有一个**：`crypto ^3.0.6`（Dart 官方包，用于流式 SHA-256）。
没有引入任何第三方"应用内更新"或"打开安装器"的 package——安装能力是自己写的
窄 MethodChannel，便于逐条审计。缓存目录也由通道返回，因此不需要
`path_provider`。

`android/app/src/main/AndroidManifest.xml`：
- 新增 `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>`
  （仅此一条新权限）。
- 新增 `androidx.core.content.FileProvider`，`android:exported="false"`，
  authority 为 `${applicationId}.updates`。

`android/app/src/main/res/xml/update_file_paths.xml`（新文件）只有一条映射：
`<cache-path name="updates" path="updates/"/>`——**只暴露 App 私有 cache 下的
`updates` 子目录**，没有 `external-path`、`root-path` 或任何更宽的映射。

`MainActivity.kt` 新增 `finwealth.client_update` 通道，五个方法：
`installedVersion`、`updateCacheDir`、`canInstallPackages`、
`openInstallPermissionSettings`、`openInstaller`。
`openInstaller` 在分享前做 `canonicalFile` 比对，
**要求文件的父目录正好是 cache/updates**，否则直接抛错——
即使 Dart 侧被传入任意路径也无法把别的文件交出去。

## 3. 逐条落实

1. 版本从 `1.0.0+1` 提升到 **`1.1.0+2`**。
2. 设置页新增紧凑「应用更新」行：当前版本、检查更新；有新版本时显示
   `发现 1.1.0`、第一条更新项、包大小与「下载更新」。无常驻风险解释文案。
3. 打开设置即静默检查一次，之后 24 小时内不再重复（`silentInterval`）；
   静默失败不弹框、不影响账本；手动检查失败才显示错误 + 重试。
4. 升级判定**只比较整数 `versionCode`**；有一条专门的测试用
   `versionName=9.9.9` 但 `versionCode` 更低来证明不按字符串比较。
5. 下载走 `StreamedResponse` 分块写盘，边写边喂 SHA-256，
   **APK 不会整包进内存**；有进度回调与取消。
6. `resolveUpdateAssetUrl` 只接受以 `/` 开头的同源相对路径，
   绝对 URL、协议相对 `//`、`..`/`.` 穿越、无前导斜杠一律拒绝；
   manifest 的 platform/channel 与客户端不一致同样拒绝。
7. 下载完成后**同时**核对 `sizeBytes` 与重算的 SHA-256，
   任一不符即删除文件并报失败，不会进入可安装状态。
8. 安装走 FileProvider content URI + 系统 Package Installer；
   没有"安装未知应用"权限时先跳系统授权页，返回后用户再点一次安装。
   界面从不宣称静默安装或安装完成。
9. 安装结果只由重启后的真实 `versionCode` 体现；
   下载、授权、取消都不触碰 token 与服务器地址——更新请求根本不经
   `DevApiClient`，不带 bearer、不参与 401 刷新。
10. 可「删除下载」清掉未安装的包；确认已是最新版本时自动清理低版本缓存。

## 4. 测试（23 条）

`test/client_update_test.dart`（16 条）：公开检查不带 `Authorization`、
未登录 token store 不被触碰、404 视作无更新、平台/channel 不符拒绝、
`versionCode` 三态、同源 URL 门禁六种坏输入、流式进度、
大小不符与 SHA 不符各自删除文件、取消删除临时文件、缓存清理保留指定文件、
各状态文案不含 SHA/路径/下划线英文标识、包大小格式化。

`test/app_update_row_test.dart`（7 条）：非 Android 整行不显示、无更新态、
发现新版本 → 下载 → 安装（断言真的调用了安装器且路径是校验过的包）、
未授权先跳授权页且不调安装器、授权后可再次安装、校验失败显示可重试错误
且不产出可安装包、长更新说明进可滚动 sheet、360×640 与 720×1280 无 overflow。

真实流式下载与文件校验放在纯 `test()` 里跑；更新行的 widget 测试用服务替身，
因为 widget 测试的假异步驱动不了真实文件 I/O。

### 顺带修了一条与本任务无关的既有失败

`test/subscription_next_charge_test.dart` 里硬编码选「28 日」，
在当月 28 日之后会选到过去日期而失败（我在基线上复现确认过）。
改成按当天推导目标日。这不是本任务引入的问题，但它挡着"全量 flutter test"门禁。

## 5. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**335 passed / 73 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_remote_android.ps1 -CheckReadinessOnly`：
  `Android server client readiness passed (endpoint mode: runtime)`。
- `git diff --check`：零输出。

## 6. 视觉证据

`app_update_up_to_date_{dark,light}`：当前版本 + 「已是最新版本」+ 检查更新。
`app_update_available_{dark,light}`：`发现 1.1.0` + 「加入应用内更新 · 160.0 MB」
+ 更新内容 / 下载更新。两组都没有 SHA、路径、endpoint 或实现细节。

## 7. 未完成项

**必测第 10 条（AVD 真实覆盖升级）我没能执行**：本机
`flutter emulators` 报 `Unable to find any emulator sources`，没有可用 AVD 镜像；
我也不会在你使用桌面时自行拉起模拟器抢占前台。

因此这条链路里**尚未由我验证**的是：
`+2` 装机 → 服务端发布 `+3` → App 内下载 → 拉起系统安装器 → 覆盖安装后
数据/服务器地址/登录态保留。前面所有环节（检查、比较、下载、校验、
授权分支、安装器调用）都有测试覆盖，最后一步需要真机。

按你给的流程，这一步本来就在你手上（你构建并发布 `+3` 再验收）。
如果希望我来跑，请先告诉我可以拉起模拟器。

另外：Windows 更新 helper 按任务单不在本批范围，Flutter 侧没有任何
Windows 自动替换的伪实现。

本回执不含 token、密码、认证文件内容或真实账本数据。
