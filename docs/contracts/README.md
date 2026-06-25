# Contracts

本目录是 finwealth 的工程契约入口。当前用途是支持前端与数据/后端并行开发，避免 Flutter UI、debug fixture、本地账本、AI proposal、行情/汇率、同步 API 各自发明字段。

## 当前读取顺序

1. `DATA_SCHEMA_V1.md`  
   领域模型基线：Account、Holding、Movement、DCA、Quote、Snapshot 等。

2. `AI_PROPOSAL_SCHEMA_V1.md`  
   AI 候选、old → new diff、atomic group、审批流。

3. `LOCAL_LEDGER_FORMAT_V1.md`  
   本地账本边界、空账本、debug fixture 隔离、迁移与备份原则。

4. `QUOTE_RATE_CONTRACT_V1.md`  
   行情/汇率刷新、过期、估值质量、历史价格口径。

5. `SYNC_API_DRAFT.md`  
   未来 VPS 同步、登录、设备、冲突处理草案。

6. `APPLICATION_INTERFACES_V1.md`  
   应用层服务接口：账户、组合、流水、定投、AI、行情、快照、同步。

7. `HTTP_API_V1.md`  
   未来 VPS HTTP API 草案；当前前端第一阶段不发真实请求。

8. `openapi_v1.yaml`  
   `HTTP_API_V1.md` 的机器可读 OpenAPI 3.1 草案，用于后续生成 client/server stub。

9. `BACKEND_INTERFACE_IMPLEMENTATION_PLAN_V1.md`  
   接口线下一步执行计划：契约一致性、core ports、后端 stub 边界。

10. `CORE_PORTS_V1.md`  
    本地账本 core 的端口边界：store ports、provider ports、atomic group use case 不变量。

11. `examples/`  
    接口载荷示例：空账本、首页空态/降级态、AI diff、DCA proposal、报价 stale。它们不是 debug fixture 种子，不得写入正式账本。

12. `API_MOCK_STUB_PLAN_V1.md`  
    本地 mock/stub 计划：只读、只返回 examples、不写账、不接真实行情/AI/同步。

## 对 Claude 前端的约束

- 当前 Flutter 前端以 `DATA_SCHEMA_V1.md` 和 `AI_PROPOSAL_SCHEMA_V1.md` 的命名为准。
- 如项目中存在旧 `API_CONTRACT_V1.md`，只作为 legacy reference，不驱动 UI / Repository 命名。
- 第一阶段前端只做 Repository interface、`real_local` 空实现、`debug_fixture` 隔离实现、空数据 UI、DEMO 标记。
- 不实现 SQLite / 加密 / Rust core / 同步 / 真实行情 / 真实 AI。

## 契约检查

运行：

```bash
python tools/contract_check.py
```

当前检查项：

- `openapi_v1.yaml` 可解析。
- README 引用的当前契约文件都存在。
- OpenAPI 不包含禁止端点。
- `HTTP_API_V1.md` 中允许的 endpoint 都存在于 OpenAPI。
- AI/DCA 的关键不变量存在：atomic group approval、old → new diff、DCA 只生成 proposal。
- `examples/*.json` 可解析，并满足关键示例不变量：空账本不含账户、AI 修改有 diff、DCA 示例明确不下单/不转账且只生成 pending review、报价示例包含 stale/offline cached。

## 本地只读 mock API

运行：

```bash
python tools/mock_api_server.py
```

默认地址：

```text
http://127.0.0.1:8787
```

约束：

- 仅用于本地接口形状验证。
- 只读 `docs/contracts/examples/*.json`。
- 不写文件。
- 不持久化 POST 副作用。
- 不接真实 AI / 行情 / 同步。
- 拒绝绑定非 localhost 地址。
- 明确拦截交易、转账、AI 自动写账、优惠券规划等禁止端点。
