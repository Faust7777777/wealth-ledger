# 2026-07-05 ChatGPT 架构与安全审查沉淀

## 审查范围

本文沉淀一次 ChatGPT Web 独立审查与 Codex 本地核验后的结论。

- 仓库：`C:\Users\15892\projects\finwealth`
- 审查时分支：`feat/frontend-skeleton`
- ChatGPT 输入：由 `git archive HEAD` 生成的源码 zip
- zip 不包含：`.git`、`build`、`dist`、`tmp` 等工作目录
- 本地桥接根目录：`C:\Users\15892\projects\finwealth`
- 桥接意图：只读审查
- Secrets：未请求、未读取、未上传

## 本地验证快照

Codex 已执行过以下验证：

```powershell
flutter analyze
flutter test
cargo test --manifest-path server-rs\Cargo.toml
python tools\server_smoke.py --target rust
python tools\local_ledger_smoke.py
python tools\contract_check.py
```

结果：

- `flutter analyze`：通过
- `flutter test`：通过，22 个测试
- `cargo test --manifest-path server-rs\Cargo.toml`：通过，51 个测试
- `python tools\server_smoke.py --target rust`：通过
- `python tools\local_ledger_smoke.py`：通过
- `python tools\contract_check.py`：失败

当前已知失败：

```text
FAIL: Rust server missing required safety snippets: dev_access_token_not_for_production
```

## 总体结论

仓库整体方向是正确的。Flutter Repository 抽象、Rust/Axum 本地 JSON ledger、Python mock/dev/check 工具、契约文档和产品边界测试基本处在同一条线上。

没有发现直接绕过产品边界的硬问题：外部转账执行、券商下单、AI 直接写正式账本、DCA 自动下单等能力目前都被明确限制或拒绝。

主要风险集中在模式边界与数据完整性：

- `?scenario=degraded` demo 读路径可能与 `--ledger-path` 真实账本写路径混用。
- 默认 Flutter `realLocal` 会展示写入口，但写入实际抛 `UnsupportedError`。
- AI approve UI 会基于本地布尔值显示“已入账”，没有消费服务端真实 `ledgerWrite`。
- JSON ledger 的读改写流程缺少明显的并发串行化或冲突检测。
- VPS/auth 的 fail-closed 主要依赖脚本和文档，服务运行时还可以更硬。

## 优先级行动表

| 优先级 | 问题 | 建议行动 |
| --- | --- | --- |
| P0 | `contract_check.py` 仍检查 Rust 旧固定 dev token | 改成检查随机 token 与 hash-only 存储语义。 |
| P0 | `--ledger-path` 真实账本可混用 `scenario` demo 读路径 | 真实账本模式默认拒绝 `scenario`，写接口尤其必须拒绝。 |
| P1 | 默认 `realLocal` 暴露会失败的写入口 | 增加 capability gating，或重塑默认可写模式。 |
| P1 | AI approve UI 硬编码“已入账” | Repository 返回并由 UI 消费 `ledgerWrite` / `confirmedMovementIds`。 |
| P1 | JSON ledger 写入缺少明显串行化 | 增加 per-ledger mutex / file lock / revision check，并补并发测试。 |
| P1 | VPS/auth fail-closed 不够硬 | `REQUIRE_AUTH=true` 但缺凭据时拒绝启动；部署模式默认显式要求 auth。 |
| P2 | logout bearer-only 分支撤销错 token 类型 | 明确 logout contract，或正确撤销 access/refresh token。 |
| P2 | `/v1/accounts/anomalies` 未走真实 ledger | 实现真实 ledger anomaly read model，或显式返回 unsupported。 |

## P0/P1 详细发现

### 1. `contract_check.py` 的 Rust dev token 检查已经漂移

证据：

- `tools/contract_check.py` 仍要求 Rust server 源码包含固定字符串 `dev_access_token_not_for_production`。
- `server-rs/src/main.rs` 当前生成随机 `dev_access_...` / `dev_refresh_...` token。
- Rust auth state 持久化的是 token hash，不是明文 token。
- `tools/server_smoke.py` 对 Rust 只检查 token 前缀 `dev_`，已经与新行为一致。
- `server/dev_server.py` 保留固定 dev token 是 Python dev skeleton 的行为，不应强加给 Rust local ledger server。

风险：

- 契约检查作为质量门禁会持续失败。
- 如果为了过检查把 Rust 改回固定 token，会造成真实安全倒退。

建议：

- 修改 `tools/contract_check.py` 的 Rust 检查逻辑，从“固定字符串存在”改成“安全语义存在”。
- 建议检查项：
  - Rust 不包含旧固定 access token。
  - Rust dev login 生成随机 opaque token。
  - Rust auth state 只保存 hash。
  - Rust smoke 仍允许 `dev_` 前缀用于开发识别。

验证：

```powershell
python tools\contract_check.py
python tools\server_smoke.py --target rust
cargo test --manifest-path server-rs\Cargo.toml
```

### 2. `--ledger-path` 真实账本模式与 `scenario` demo 读路径可混用

证据：

- `server-rs/src/main.rs` 中 `AppState::should_use_local_ledger()` 只有在存在 ledger path 且 query 不包含 `scenario` 时才返回 true。
- 多个读接口在带 `scenario` 时回退到 dev scenario 数据。
- 多个写接口直接检查 `state.local_ledger_path`，不统一受 `should_use_local_ledger()` 控制。
- `lib/data/api_mock_repositories.dart` 的 `DevApiClient` 会在 `apiScenario` 非空时自动追加 `scenario=...`。

风险：

- 请求可能读到 demo/degraded 数据，但写入真实 JSON ledger。
- 测试或人工联调可能误以为只在 demo 场景操作，实际已经改了真实账本。
- 资产账本领域里，模式混淆属于数据完整性风险。

建议：

- Rust 在 `--ledger-path` 启用时默认拒绝非空 `scenario`。
- 所有写接口遇到 `scenario` 都应拒绝。
- 如果确实需要在真实 ledger server 上看 degraded 场景，必须显式开启 dev-only 环境开关。
- Flutter 在可写真实账本连接上不应自动追加 `apiScenario`。

验证：

```powershell
# 启动 Rust server，并带 --ledger-path
curl -i "http://127.0.0.1:8790/v1/accounts?scenario=degraded"
curl -i -X POST "http://127.0.0.1:8790/v1/accounts?scenario=degraded"
python tools\local_ledger_smoke.py
```

建议新增 Rust 测试：

- `--ledger-path + scenario` 被拒绝。
- 写接口带 `scenario` 被拒绝。
- 不带 `--ledger-path` 时 dev scenario 仍可用于 mock/dev 联调。

### 3. 默认 Flutter `realLocal` 暴露了实际不可写的入口

证据：

- `lib/core/env.dart` 默认模式是 `DataSourceMode.realLocal`。
- `lib/data/real_local_repositories.dart` 中大量写方法抛 `UnsupportedError`。
- `lib/features/overview_page.dart` 在空态直接展示“添加账户”。
- 用户可进入账户/流水等表单，最后才在 Repository 层失败。

风险：

- 默认体验是“看起来能写，填完表才失败”。
- 用户无法清楚区分只读空账本、DEMO fixture、可写本地 Rust ledger。

建议：

- 增加统一 capability model，例如：
  - `canWriteLedger`
  - `canCreateAccount`
  - `canRecordMovement`
  - `canConfirmProposal`
  - `requiresLocalServer`
- 默认 `realLocal` 下隐藏或禁用写入口，并给出明确引导。
- 或者调整自用产品的默认启动路径，让可写模式明确走 Rust local server。

验证：

```powershell
flutter analyze
flutter test
```

建议新增 widget tests：

- 默认模式不展示可点击写入口，或展示 disabled + 原因。
- `localServer` 模式正常展示写入口。
- 表单页不会允许提交到已知 unsupported repository。

### 4. AI approve UI 没有消费服务端 `ledgerWrite`

证据：

- `lib/data/api_mock_repositories.dart` 的 `LocalServerAiProposalRepository.approveAtomicGroup()` 返回 `Future<void>`，丢弃服务端 response。
- `lib/features/ai_review_page.dart` 对 approve 硬编码 `writesLedger: true`。
- Rust dev/scenario 路径可以返回 `ledgerWrite: false` 与空 `confirmedMovementIds`。

风险：

- UI 可能显示“已入账”，但服务端实际没有写正式账本。
- 对资产类产品，“已入账”是强会计语义，不能由前端猜测。

建议：

- 增加前端 `ConfirmResultVm` 或类似结构。
- `approveAtomicGroup()` 返回 `ledgerWrite`、`confirmedMovementIds`、`snapshotInvalidated` 等字段。
- UI 文案和 provider invalidation 基于服务端真实 response。
- DCA proposal、movement confirm 等类似路径也应统一处理。

验证：

- 无 `--ledger-path` 的 dev server：approve 后不显示“已入账”。
- 带 `--ledger-path` 的 real local server：只有 `ledgerWrite == true` 才显示“已入账”。
- 增加 response parsing 和 UI message 测试。

### 5. JSON ledger 写入缺少并发串行化

证据：

- `server-rs/src/local_ledger.rs` 采用 `read_document()`、内存修改、`write_document()` 的 read-modify-write 模式。
- `write_document()` 使用临时文件和 rename，可保证单次替换，但没有看到 per-ledger mutex、file lock 或 revision 检测。
- Axum 可并发处理请求。

风险：

- 两个并发写请求可能基于同一旧版本 ledger 修改，后写覆盖先写。
- 账户、流水、DCA、AI proposal 状态都可能 lost update。

建议：

- 在 `AppState` 或 ledger service 层增加单进程 per-ledger 写串行化。
- 若未来可能多进程访问同一 ledger 文件，再补 file lock。
- 后续可引入 `revision` / optimistic conflict check。

验证：

- 新增 Rust 并发测试：并发创建 N 个账户或 movement，最终数量必须等于 N。
- 保持 `python tools\local_ledger_smoke.py` 通过。

### 6. VPS/auth fail-closed 应由服务运行时兜底

证据：

- 文档和脚本都推荐正确部署姿态：loopback bind、反代、`FINWEALTH_REQUIRE_AUTH=true`、用户名、Argon2 hash。
- `tools/run_self_use_windows.ps1` 默认会提示本地 auth，并设置 `FINWEALTH_REQUIRE_AUTH=true`。
- 但服务运行时在缺少 auth env 时仍保留 dev-compatible login fallback。

风险：

- 手动部署、env 文件缺失或 systemd 配置错误时，服务可能以 dev/open 行为跑在反代后面。
- 对个人资产面板，这是部署安全硬风险。

建议：

- 当 `FINWEALTH_REQUIRE_AUTH=true` 时，缺少 username 或 Argon2 hash 应拒绝启动。
- 部署/systemd 模式应默认要求 auth，除非显式 unsafe override。
- 明文 `FINWEALTH_AUTH_PASSWORD` 仅允许本地开发，并打印强警告。

验证：

```powershell
$env:FINWEALTH_REQUIRE_AUTH="true"
Remove-Item Env:\FINWEALTH_AUTH_USERNAME -ErrorAction SilentlyContinue
Remove-Item Env:\FINWEALTH_AUTH_PASSWORD_HASH -ErrorAction SilentlyContinue
cargo run --manifest-path server-rs\Cargo.toml -- --ledger-path tmp\ledger.json
```

期望：拒绝启动或明确失败，而不是进入 dev fallback。

## P2 发现

### logout bearer-only 分支撤销错 token 类型

证据：

- `auth_logout()` 在 body 包含 `refreshToken` 时撤销 refresh token。
- body 不含 refresh token 但有 bearer token 时，会把 bearer access token 传给 `revoke_refresh_token()`。

建议：

- 明确 logout contract：要么要求 refresh token，要么同时支持 access token 与 refresh token revoke。
- 保持 Flutter 主路径传 refresh token。

### `/v1/accounts/anomalies` 未走真实 ledger

证据：

- 该接口直接返回 dev scenario anomalies。
- `empty_document()` 中存在 `anomalies` 字段，但 route 未使用真实 ledger read model。

建议：

- 实现真实 ledger anomaly read model。
- 或在真实 ledger 模式下显式返回 unsupported，避免静默给 dev scenario 结果。

### DCA proposal 文案需要更精确

证据：

- DCA “record executed” 不下单、不转账，符合产品边界。
- 但它可能把 pending proposal / pending movement 持久化到 JSON ledger 文件。

建议：

- 文档区分三件事：
  - 不执行外部订单/转账。
  - 用户确认前不写 confirmed/effective ledger。
  - 可以持久化 pending proposal/draft。

### Quote provider 隐私默认值

证据：

- `deploy/finwealth-server.env.example` 当前设置 `FINWEALTH_QUOTE_PROVIDER=yahoo`。

建议：

- VPS 示例可考虑默认 `none`，由用户显式 opt-in Yahoo。
- 文档提示 symbol 查询可能暴露投资偏好。

### systemd hardening 可继续加强

证据：

- `deploy/systemd/finwealth-server.service` 已有 `NoNewPrivileges=true`、`PrivateTmp=true`、`ProtectHome=true`、`ProtectSystem=strict`、`ReadWritePaths=/var/lib/finwealth` 等配置。

建议：

- 评估增加 `UMask=0077`、`PrivateDevices=true`、更严格 capability 限制、`StateDirectory=finwealth`。

## 建议验证命令

```powershell
python tools\contract_check.py
python tools\server_smoke.py --target rust
python tools\local_ledger_smoke.py

cargo fmt --manifest-path server-rs\Cargo.toml --check
cargo clippy --manifest-path server-rs\Cargo.toml -- -D warnings
cargo test --manifest-path server-rs\Cargo.toml

flutter analyze
flutter test
```

建议补充为自动化边界测试：

```powershell
# 非 loopback bind 应被拒绝
$env:FINWEALTH_RS_ADDR="0.0.0.0:8791"
cargo run --manifest-path server-rs\Cargo.toml

# 真实 ledger 模式不应静默接受 scenario
cargo run --manifest-path server-rs\Cargo.toml -- --ledger-path tmp\ledger.json
curl -i "http://127.0.0.1:8790/v1/accounts?scenario=degraded"

# 产品边界 endpoint 应保持 forbidden
curl -i -X POST http://127.0.0.1:8790/v1/transfers/execute
curl -i -X POST http://127.0.0.1:8790/v1/broker/orders
curl -i -X POST http://127.0.0.1:8790/v1/ai/write-ledger-directly
```

## 备注

- ChatGPT 审查结果只作为建议；本文只沉淀已由 Codex 对照源码核验过的高信号问题。
- 审查阶段未修改源码。
- 审查结束后，本地 bridge/tunnel 已停止，无残留进程。
