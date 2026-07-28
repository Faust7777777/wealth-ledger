# Android 应用内更新发布回执

日期：2026-07-29

## 集成

- 更新主线：`feat/client-self-update @ 724a806`
- `+3` 发布分支：`release/android-1.1.0-3 @ ddaa033`
- Android 更新器及 P0/P1 修正均已合入。
- 门禁：format、analyze、Flutter 全量 `352 passed / 73 skipped / 0 failed`、契约检查、账本真实 smoke、Agent 真实 smoke 全部通过。

## 构建产物

### 1.1.0+2（最后一次手动安装）

- 文件：`finwealth-1.1.0+2-20260729-021401-android-server-client-debug.apk`
- 大小：`161234460` bytes
- SHA-256：`6a147d34b880b205c38471eedc6eb5462d0fce73155b4afa3fc7b522247ae8f0`
- GitHub Release：`android-v1.1.0+2`（prerelease）

### 1.1.0+3（首次在线更新）

- 文件：`finwealth-1.1.0+3-20260729-021642-android-server-client-debug.apk`
- 大小：`161234612` bytes
- SHA-256：`3420807aea91b365a065c567ecbcee4b2ecd40e9c85ca919a38c82e2046db8a1`
- GitHub Release：`android-v1.1.0+3`（latest）

两个 Release 均包含 APK、`.sha256` 和 provenance `.manifest.json`。

## VPS stable

- stable manifest 已原子发布为 `1.1.0+3`。
- `minimumVersionCode=2`，从 `+2` 开始允许在线升级。
- 公网完整下载后，文件大小与 SHA-256 均和本机构建及 GitHub Release digest 一致。
- VPS readiness 通过。
- 正式更新目录占用约 `154M`，临时上传目录已删除；根分区仍约有 `41G` 可用。

## 尚需设备验收

1. 手动覆盖安装一次 `1.1.0+2`。
2. 启动 App，确认自动或手动发现 `1.1.0+3`。
3. App 内下载并拉起系统安装器，完成覆盖安装。
4. 重启后确认版本为 `+3`，登录态、服务器地址和账本数据保留。

Android 非 root 环境仍会显示系统安装确认，这是平台限制。除这次安装 `+2` 外，后续版本不再需要手动下载 APK。
