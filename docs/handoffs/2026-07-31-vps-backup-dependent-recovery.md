# VPS 备份依赖服务恢复修复

## 问题

`finwealth-agent.service` 使用 `Requires=finwealth-server.service`。账本备份停止 Rust 服务时，systemd 会同时停止 Agent；旧脚本只记录并恢复 Rust，随后单独执行 Agent 状态备份时已经无法得知 Agent 原本在线，因此可能在备份完成后留下 inactive Agent。

## 修复

- `backup_vps_ledger.sh` 在停止 Rust 前记录仍在线的依赖服务，默认包含 `finwealth-agent.service`。
- 清理路径按 Rust、依赖服务、Docker bridge proxy socket 的顺序恢复。
- 备份本身失败时也执行完整恢复，不再把 proxy socket 留在停止状态。
- 可用 `FINWEALTH_BACKUP_DEPENDENT_SERVICES` 覆盖依赖服务列表；服务名经过 systemd unit 名窄校验。
- manifest 新增 `dependentServicesStopped`，便于审计该次备份实际暂停了哪些依赖。

## 验证

`vps_backup_restore_smoke.sh` 的 fake systemd 现在模拟 `Requires` 传播停止，并覆盖：

- 正常备份后 Rust、Agent 与 proxy socket 全部恢复；
- 无效账本导致备份失败后，三者仍全部恢复；
- 原有校验、校验和、防篡改、恢复回滚和无 auth 状态用例继续通过。
