# 2026-07-06 wealth-ledger 代码审阅报告

状态：已沉淀。  
范围：Flutter 前端、Repository 抽象、HTTP 契约、Rust/Axum 本地 JSON ledger、Python mock/dev/check 工具、部署脚本。  
结论：整体质量中上，方向正确，适合继续迭代；当前仍是 pre-release 自用阶段。

## 1. 总体结论

仓库分层清晰：

- Flutter Repository 抽象；
- HTTP/OpenAPI 契约；
- Rust/Axum 本地 JSON ledger；
- Python mock/dev/check 工具；
- PowerShell 本地运行/备份/恢复脚本。

产品边界总体守住：转账、券商下单、AI 自动确认/直接写账、优惠券规划等端点被硬拒。AI 内容只进入 `aiProposals`，需要用户确认后才影响 confirmed/effective ledger。金额核心使用定点整数 `DecimalAmount(i128)`，没有用浮点处理资产金额。

本次审阅时关键验证命令均通过：

```powershell
flutter analyze
flutter test
cargo test --manifest-path server-rs\Cargo.toml
python tools\contract_check.py
python tools\server_smoke.py
python tools\local_ledger_smoke.py
```

## 2. 已被后续提交修复的问题

以下是旧审阅里出现过、但当前代码已修复或明显改善的项，避免重复修：

- `contract_check.py` 已通过，不再卡旧固定 dev token。
- `--ledger-path` 真实账本模式已默认拒绝 `scenario` demo 混用。
- JSON ledger 写路径已有 per-path mutex + tmp/rename 原子替换。
- auth fail-closed 配置校验已存在：`FINWEALTH_REQUIRE_AUTH=true` 但缺 username/password hash 会拒启动。
- `/v1/accounts/anomalies` 已走真实 ledger。
- logout bearer 分支已正确撤销 access token。

## 3. P1 风险

### 3.1 账户余额小数位校验前后不一致

问题：写入侧 `is_decimal_string()` 允许超过 8 位小数；读取/汇总侧 `DecimalAmount::parse()` 拒绝超过 8 位小数。结果是一个 9 位小数 opening balance 可被写入，但之后 `/v1/portfolio/overview` 或 allocation 会因为解析失败返回 500。

影响：单条脏数据可永久打坏首页净值，需要手工改 ledger JSON 才能恢复。

建议：

- 统一 decimal 校验，所有金额输入最多 8 位小数；
- 增加 opening balance 与 movement entry 的边界测试；
- 目标行为：9 位小数写入请求应被 400 拒绝。

### 3.2 默认 auth fail-open + 无 Host 头校验

问题：`FINWEALTH_REQUIRE_AUTH` 缺省为 false，`tools/run_local_server.ps1` 又不会主动开启 auth；同时 Rust server 没有 Host 头白名单。真实账本 server 虽然只监听 loopback，但浏览器恶意页面可通过 DNS rebinding 对本机服务发起盲写。

影响：本机浏览器场景存在真实账本被盲写风险。读响应受 CORS 限制较难直接读取，但写副作用可发生。

建议：

- 真实 ledger 模式下增加 Host 白名单，默认只允许 `127.0.0.1`、`localhost`、`[::1]`，VPS/反代域名通过显式环境变量加入；
- `run_local_server.ps1` 默认要求 auth，只有显式 `-NoAuth` 才允许无鉴权开发运行；
- 增加非法 Host 测试。

### 3.3 AI “已入账” UI 语义失真

问题：前端 AI review 的 approve 成功后硬编码显示“已入账”，没有消费服务端返回的 `ledgerWrite` / `confirmedMovementIds`。dev/scenario 或二次确认场景下服务端可能返回 `ledgerWrite:false`，前端仍显示已入账。

影响：资产类产品里“已入账”是强会计语义，不能由前端猜测。

建议交给前端线：

- `approveAtomicGroup()` 返回确认结果 VM；
- UI 只在 `ledgerWrite == true` 时显示“已入账”；
- `confirmedMovementIds` 为空时显示“已确认/无新增入账”之类文案；
- DCA confirm、movement confirm 建议同口径。

## 4. P2 风险

### 4.1 契约/路由漂移

现象：

- `/v1/holdings`、`/v1/movements/recent` 是 Rust/Flutter 私有别名，但不在 OpenAPI/HTTP_API 中；
- Python mock/dev server 覆盖面落后，部分 Flutter 调用在 Python server 下会 404；
- 部分 POST create 端点在 OpenAPI 中复用了实体响应 schema，导致请求体字段与服务端真实输入不一致；
- `contract_check.py` 当前主要检查文档引用、禁用端点、少量 invariant，抓不到 method/status/request/response schema 漂移。

建议：

- 要么把别名补进 OpenAPI/HTTP_API，要么让 Flutter 改用已文档化端点；
- 为 create/update 请求体定义独立 schema；
- 升级 `contract_check.py`，枚举 Rust 路由并做 OpenAPI schema 级检查。

### 4.2 LOCAL_LEDGER_FORMAT_V1.md 与真实磁盘格式不符

现象：文档描述偏“目录 + 多表/CSV”，真实实现是单个 `ledger.json`。

影响：照文档写备份/迁移工具会失败。

建议：重写该文档，明确当前 v1 是单 JSON 文档；SQLite/加密是未来实现。

### 4.3 refresh token 无服务端过期

现象：refresh token 可一直轮换，除非 logout/revoke。

建议：给设备记录增加 `refresh_expires_at`，refresh 时校验。自用阶段可放 P2。

### 4.4 sync 细节欠账

现象：

- `nextChangeSequence` 信任 ledger 字段，人工回退可能导致重复 change id；
- `/sync/changes?since=<未知>` 返回全部，而 `/sync/ack` 对未知 cursor 报错，语义不对称。

建议：扫描现有最大 change id 作为保底；统一 unknown cursor 语义。

## 5. P3 风险

- token hash 比对不是常量时间；token 是高熵随机值，自用/本机风险低。
- 法币现金余额最终落盘会按 2 位小数显示/更新，与 movement entry 可接受 8 位小数的策略需文档化。

## 6. 建议修复路线

P1 当前执行：

1. 统一 decimal 校验；
2. Host 头白名单；
3. 本地真实账本脚本默认 auth；
4. 前端 AI ledgerWrite 语义修复交给 Claude。

P2 后续：

1. 契约/路由/状态码/schema 对齐；
2. 重写 `LOCAL_LEDGER_FORMAT_V1.md`；
3. 升级 contract check；
4. refresh token 过期；
5. sync cursor/sequence 语义硬化。

## 7. 前端需交给 Claude 的事项

详见 `docs/handoffs/2026-07-06-frontend-fixes-for-claude.md`。
