# 客户端在线更新后端生产部署回执

日期：2026-07-28

## 已部署

- 分支：`feat/client-self-update`
- 提交：`7c14dbe`
- VPS 源码：`deploy/client-self-update`
- Rust 服务已安装并重启，生产配置校验通过。
- `/var/lib/finwealth-updates` 已按 `root:finwealth 0755` 创建；服务只读访问。
- 共享 Caddyfile 已精确加入 `/v1/client-updates/*`，未修改 `sub2api.wuwaidut.com` 或 `/v1/models` 路由。
- VPS readiness 通过。

## 公网验收

- `GET https://wuwaidut.com/v1/health`：200。
- 匿名 `GET /v1/accounts`：401，账本鉴权未放宽。
- `GET /v1/client-updates/android/stable/latest`：404；当前尚未发布 stable manifest，符合预期。
- 根域与 `sub2api.wuwaidut.com` 的 `/v1/models` 均保持原有 401 行为。

## 部署中修复

Caddy 临时候选配置没有 `Caddyfile` 文件名，Caddy 曾将其误判为 JSON。补丁脚本现显式传入 `--adapter caddyfile`，并在契约检查中锁定；首次失败已自动恢复原配置，修复后重新应用成功。

## 剩余工作

1. Claude 按 `2026-07-28-claude-client-self-update.md` 完成 Android 前端，首个版本至少为 `1.1.0+2`。
2. 集成后手动安装一次带更新器的 `+2`。
3. 再构建 `+3`，使用 `/opt/finwealth/tools/publish_client_update.py` 发布 stable。
4. 在 AVD 或真机完成 `+2 -> +3` 下载、SHA-256/大小校验、系统覆盖安装，以及登录态、服务器地址和账本数据保留验收。

在前端交付前不要发布空 manifest，也不要用旧 APK 冒充新版本。
