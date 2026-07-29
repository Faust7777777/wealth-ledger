# 多资产持仓快照集成发布回执

## 集成与生产

- `feat/holding-snapshot-ui @ 0df4fc3` 已快进合入集成线。
- 集成审阅修复 `skippedPositions` 刷新后丢失，提交 `662acba` 已部署生产。
- 部署前账本备份：`/var/backups/finwealth/20260729-122918Z`。
- 代码回滚副本：`/opt/finwealth/rollback-20260729-122918Z`。
- Rust、Agent systemd unit 与公网 health 正常；未修改 Caddy、Cloudflare、sub2api 或生产账本内容。

## 客户端

- 客户端版本：`1.3.2+8`，源码提交 `c63eec0`。
- Android stable 已发布，公网 manifest、HEAD 与本地文件大小一致。
- Windows stable 已发布，公网 manifest、HEAD 与本地文件大小一致。
- Android：`167972872` bytes；桌面 `Finwealth-1.3.2+8.apk`。
- Windows：`19878430` bytes；桌面 `Finwealth-1.3.2+8-Windows.zip`。
- 旧 stable 资产保留；最新 manifest 只指向 `+8`。VPS 临时上传目录已删除，剩余空间约 40 GB。

## 门禁

- Flutter 418 passed / 92 skipped / 0 failed。
- Rust 150 passed。
- holding snapshot 专项 18 passed。
- frontend local-server smoke、analyze、OpenAPI/contract check 通过。
