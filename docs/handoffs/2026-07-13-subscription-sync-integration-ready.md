# 2026-07-13 订阅前端与认证同步后端集成回执

## 1. 集成结果

- 集成分支：`feat/subscription-sync-integration`
- 独立工作树：`C:\Users\15892\projects\finwealth-subscription-sync-integration`
- 共同基线：`9b3e0f7f5d99b9ecf349e83af4afb5ffdcfbe35a`
- 后端输入：`feat/sync-account-create-inbound@3268f4e1cce469325a163afb9893de6ebd705be0`
- 前端输入：`feat/subscription-due-scan-ui@e666aa3fb418e0570639080fd7269a6b17e9fc71`
- 无冲突合并提交：`655170a`（`merge: integrate subscription UI with authenticated sync backend`）

两个输入分支均已在合并前通过 GitHub 远端 SHA 核对。本次未改写 `main`，未创建 Release，
也未修改两个来源工作树。

## 2. 已集成能力

### Flutter 订阅管理

- 有待确认扣费时禁用取消订阅，不弹确认框且不发送请求。
- 用户显式触发到期订阅扫描，不使用后台 timer。
- 展示新建候选、已存在 pending、受阻原因和剩余可扫描数量。
- 支持前往 AI 审核与 `hasMore` 再次扫描。
- 扫描后刷新 subscriptions、upcoming、AI pending 和 overview。
- 扫描只生成待确认候选，不自动确认、扣款或调用服务商支付/退订接口。

### Rust 认证设备入站同步

- Bearer token 解析真实 auth device ID，拒绝请求体冒充其他设备。
- 仅接受 `entityType=account`、`operation=create`、`baseVersion=0`。
- 要求完整 Account payload 且 `payload.id == entityId`。
- 账户实体和远端 sync log 在同一次原子 ledger write 中提交。
- 相同 `(sourceDeviceId, sourceChangeId)` 重试只 skip。
- 已存在 account ID 返回结构化 manual conflict，不覆盖且不落远端日志。
- 远端 change 不进入本地 outbox；响应包含 `appliedChangeIds`。

## 3. 集成门禁

以下命令均在集成工作树实际运行并通过：

- `dart format --output=none --set-exit-if-changed lib test`：63 files，0 changed。
- `flutter analyze`：No issues found。
- `flutter test`：93 passed，16 个按环境条件跳过的 golden/真实服务测试。
- `cargo test`：108 passed。
- `cargo clippy --all-targets -- -D warnings`：通过。
- `cargo fmt -- --check`：通过。
- `python tools/contract_check.py`：通过。
- `python tools/server_smoke.py`：mock、dev、Rust server 全通过。
- `python tools/local_ledger_smoke.py`：real-local ledger smoke 通过。
- `pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1`：2 条 Flutter↔Rust 真实联调通过。
- `pwsh -NoProfile -File tools/local_backup_restore_smoke.ps1`：Windows 备份、恢复、无 auth 恢复和失败回滚通过。

## 4. 当前边界

- 尚未实现 account update、movement merge 或通用多实体入站同步。
- 尚未实现逐设备 delivery receipt、自动冲突解决、设备密钥或 E2EE。
- quote/FX、snapshot/holding、AI proposal/evidence 不在本轮同步范围。
- 订阅管理不连接 OpenAI、Anthropic 等服务商的真实支付、续费或退订 API。
- feature 分支推送不会触发当前仅针对 `main` 的 GitHub CI，因此本回执记录本地完整门禁证据。

## 5. 后续建议

1. 将本集成分支作为下一轮开发和自用打包基线，不再从旧 `frontend-skeleton` 派生。
2. 若要进入 Windows 自用发布，运行 package workflow 等价的完整门禁和 package integrity smoke。
3. 下一条同步线路先设计持久化 conflict/device delivery 模型，再决定是否实现 account update。

