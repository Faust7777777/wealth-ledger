# 2026-07-06 前端修复清单给 Claude

范围：只改 Flutter 前端；不要改 Rust server、Python tools、部署脚本。后端 P1 由 Codex 处理。

## 目标

修复资产产品里“确认/入账”语义由前端猜测的问题，并补 capability/auth/契约漂移相关前端侧防线。

## 1. P1：AI approve 不得硬编码“已入账”

当前问题：

- `LocalServerAiProposalRepository.approveAtomicGroup()` 返回 `Future<void>`，丢弃服务端响应。
- `ai_review_page.dart` approve 成功后硬编码 `writesLedger: true`，恒定显示“已入账”。
- 服务端真实响应可能是：
  - `ledgerWrite: true`，有 `confirmedMovementIds`；
  - `ledgerWrite: false`，如 dev/scenario、二次确认、已 approved 组。

要求：

- 新增前端 VM，例如 `ConfirmAtomicGroupResultVm`：
  - `atomicGroupId`
  - `ledgerWrite`
  - `confirmedMovementIds`
  - `snapshotInvalidated`
- Repository 接口返回该 VM，不再返回 `void`。
- UI 文案规则：
  - `ledgerWrite == true`：显示“已入账”，并刷新账户/流水/概览/快照相关 provider；
  - `ledgerWrite == false`：显示“已确认，无新增入账”或“已处理”，不得写“已入账”。
- DCA “记录已执行”后的确认、普通 movement confirm 如有同类硬编码，也按同一 VM/文案口径处理。

建议测试：

- mock 一个 approve response `ledgerWrite:false`，断言不出现“已入账”。
- mock `ledgerWrite:true + confirmedMovementIds`，断言出现“已入账”并触发刷新。

## 2. P1：capability gating 再核查

当前 review 指出默认 `realLocal` 可能暴露写入口但最终 repository 抛 `UnsupportedError`。请确认当前前端是否已修。

要求：

- 写入口不要只按 `DataSourceMode` 猜能力；
- 优先读取 `/v1/ledger/bootstrap.data.capabilities`：
  - `canWriteConfirmedLedger`
  - `canCreateAccount`
  - `canRecordMovement`
  - `canConfirmProposal`
  - `canPersistPendingProposal`
- 不具备能力时：
  - 隐藏或 disable 写入口；
  - 给出明确原因，例如“请启动 local_server 可写模式”。

## 3. P2：路由/契约漂移前端侧处理

当前 review 指出：

- `/v1/holdings`、`/v1/movements/recent` 是 Rust/Flutter 私有别名，未写入 OpenAPI/HTTP_API；
- Python mock/dev server 未必支持这些别名。

前端处理建议：

- 如果继续使用这些端点，先和后端确认是否要补进契约；
- 如果不补契约，则改用已文档化端点；
- 不要继续扩大“前端私有端点”。

## 4. P2：auth/Host hardening 后的前端影响

Codex 会让真实 ledger server 对 Host 更严格，并让 `run_local_server.ps1` 默认要求 auth。

请前端确认：

- `DevApiClient` 对 401/403 的错误文案明确；
- 登录/refresh/token store 的 UI 路径不被破坏；
- 用户未登录时，不要把 401 泛化成“网络错误”。

## 5. 验证建议

```powershell
flutter analyze
flutter test
flutter run -d windows --dart-define=DATA_SOURCE=local_server --dart-define=API_BASE=http://127.0.0.1:8791
```

重点手测：

- AI proposal approve：`ledgerWrite:true` 和 `ledgerWrite:false` 两种响应；
- 默认 `realLocal` 下写入口是否被隐藏/禁用；
- local_server 未登录/登录过期时的错误提示。
