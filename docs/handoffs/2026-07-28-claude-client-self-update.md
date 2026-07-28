# Claude 任务单：Android 应用内更新

日期：2026-07-28

## 基线与边界

- 等 Codex 推送后，从 `origin/feat/client-self-update` 新建独立工作树与前端分支。
- 允许改 `lib/**`、`test/**`、`integration_test/**`、`android/**`、`pubspec.yaml`/lock、前端 smoke/golden 和回执。
- 不改 `server-rs/**`、`docs/contracts/**`、Caddy、VPS 部署、发布脚本或生产更新目录。
- 本批只做 Android P0；Windows 更新 helper 另开任务，不要在 Flutter 中伪造 Windows 自动替换。

## 后端契约

读取 `docs/contracts/CLIENT_UPDATE_V1.md` 与 OpenAPI：

```http
GET /v1/client-updates/android/stable/latest
GET /v1/client-updates/android/stable/assets/{fileName}
```

两者公开可读，不需要 token。manifest 的 `asset.url` 必须是当前 API origin 下的相对 URL。

## 必须实现

1. 把 `pubspec.yaml` 版本提升到至少 `1.1.0+2`；当前已安装包是 `+1`，不提升 `versionCode` 就不是升级。
2. 设置页增加紧凑“应用更新”行：当前版本、检查更新；有新版本时显示版本号、简短更新项、包大小和“下载更新”。不要放常驻风险解释文案。
3. App 启动后静默检查一次，之后最多每 24 小时一次；失败不弹阻断框、不影响账本。手动检查失败才显示可重试错误。
4. 比较只使用整数 `versionCode`。服务端相同或更低版本视为无更新；不要按字符串比较 `versionName`。
5. 下载必须流式写入 App 私有 cache，不得把约 160 MiB APK 全部读入内存。显示进度并允许取消。
6. 下载只接受同源相对 URL；拒绝绝对 URL、`..`、非 HTTPS origin 或 manifest 平台/channel 不一致。
7. 完成后重新计算文件 SHA-256，并同时核对 `sizeBytes`；任一不符即删除临时文件，不能打开安装器。
8. Android 用 `FileProvider`/content URI 调系统 Package Installer。需要“安装未知应用”权限时跳系统授权页；返回后用户再次点安装。不得宣称静默安装或安装完成。
9. 安装完成只通过 App 重启后的真实 `versionCode` 判断。下载、授权、安装取消均保留账本登录态和服务器地址。
10. 更新页可删除已下载但未安装的旧 APK；成功升级后清掉低版本缓存。

可使用小而成熟的 package 获取版本和打开安装器，也可写窄 MethodChannel。无论选择哪种，都必须审计 Android Manifest 权限、FileProvider 路径只能指向 App cache，不能暴露任意文件。

## 状态与文案

- 无更新：`已是最新版本`
- 有更新：`发现 1.1.0`
- 下载中：百分比与取消
- 校验中：`正在校验`
- 可安装：`安装更新`
- 失败：一句具体错误 + `重试`

不要显示 SHA、内部路径、source commit、endpoint、manifest schema、安装器实现细节或“为了安全我们不会……”类解释文案。

## 测试

至少覆盖：

1. 未登录仍可检查更新，且请求不带/不要求 bearer。
2. `versionCode` 高/等于/低于当前版本三态。
3. 同源相对 URL 接受；跨源、绝对 URL、路径穿越拒绝。
4. 流式下载进度与取消；取消删除临时文件。
5. 大小不符、SHA 不符均删除且不调用安装器。
6. 401 refresh/token 逻辑不参与公开更新请求，也不清登录态。
7. 未授权安装来源 → 打开授权页 → 返回后可再次安装。
8. FileProvider 只能分享已校验的 cache APK。
9. Android 360×640 和 720×1280 无 overflow；长更新说明放可滚动 sheet，不挤主页面。
10. 从 `+2` 安装到测试发布的 `+3` 的 AVD 真实覆盖升级：App 数据、服务器地址与登录状态保留。

## 门禁与回执

- format、analyze、全量 Flutter test。
- 更新专项 widget/integration test。
- `frontend_local_server_smoke.ps1`、`frontend_agent_smoke.ps1`、Android server-client readiness。
- 生成必要的明暗 golden 并肉眼核验。
- 回执列出依赖、Manifest/FileProvider 变化、真实升级结果与未完成项。
