# Client Update V1

状态：后端已实现，Flutter 客户端待接入。

## 目标

Finwealth 自用客户端从 `wuwaidut.com` 检查、下载并校验更新。Android 使用同签名 APK 覆盖升级；Windows 使用独立更新 helper 原子替换。更新服务不读取或修改账本。

首次安装带更新器的 Android 包仍需手动完成。之后 App 可以自动下载，但 Android 非 root 设备最终安装确认仍由系统界面完成，客户端不得伪造静默安装成功。

## 端点

```http
GET /v1/client-updates/{platform}/{channel}/latest
GET /v1/client-updates/{platform}/{channel}/assets/{fileName}
```

- `platform`：`android` 或 `windows`。
- `channel`：默认 `stable`；只允许小写字母、数字和连字符。
- 两个端点均无需 bearer token，使过期会话和首次设置页也能更新。
- manifest 使用 `Cache-Control: no-store`；版本化资源使用一年 immutable cache。
- manifest 与资源均支持 `If-None-Match` / `304`。

## Manifest

```json
{
  "schemaVersion": 1,
  "platform": "android",
  "channel": "stable",
  "versionName": "1.1.0",
  "versionCode": 2,
  "releasedAt": "2026-07-28T12:00:00Z",
  "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
  "mandatory": false,
  "minimumVersionCode": 1,
  "notes": ["加入应用内更新"],
  "asset": {
    "url": "/v1/client-updates/android/stable/assets/finwealth-1.1.0-android.apk",
    "fileName": "finwealth-1.1.0-android.apk",
    "sizeBytes": 123456,
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "contentType": "application/vnd.android.package-archive"
  }
}
```

`versionCode` 是升级顺序的唯一依据，必须严格大于现网同平台、同 channel 的值。`versionName` 只用于显示。`minimumVersionCode` 高于当前客户端时可要求升级，但 App 仍不得绕过 Android 系统安装确认。

## 客户端不变量

1. 只接受与当前 API origin 同源的相对 `asset.url`；不得跟随 manifest 指向其他 origin。
2. 下载到 App 私有 cache，完成后重新计算 SHA-256；不匹配时删除并报更新失败。
3. Android 交给 Package Installer 后，只把“已发起安装”当作中间态；重启后比较实际 `versionCode` 才能显示完成。
4. 下载失败不影响账本使用；不清 token、不改服务器地址。
5. `mandatory=false` 时允许稍后；`mandatory=true` 也保留退出 App 的能力，不制造不可退出的假死界面。
6. 不把 APK、下载 URL、文件路径或安装状态写入 Agent 记忆。

## 发布不变量

- 只发布干净 Git commit 构建的产物。
- publisher 必须验证 provenance manifest、文件大小和 SHA-256。
- 同平台/channel 的 `versionCode` 必须单调递增；默认拒绝覆盖或降级。
- 先写版本化资源与 sidecar，最后原子替换 `latest.json`；失败时旧版本继续可用。
- 更新目录由 root 写、`finwealth-server` 只读。
