# LOCAL_LEDGER_FORMAT_V1

状态：草案。  
用途：定义真实本地账本、debug fixture、迁移、备份、校验的边界。  
非用途：不要求前端第一阶段实现 SQLite / 加密 / Rust core。

## 0. 第一阶段分工

Claude 前端第一阶段只实现：

- Repository interface。
- `real_local` 空账本实现。
- `debug_fixture` 隔离实现。
- 空数据 UI。
- DEMO 标记。

不实现：

- 正式 SQLite 表结构。
- 加密账本。
- Rust core。
- 同步协议。
- 真实行情。
- 真实 AI。

## 1. 数据源模式

```ts
DataSourceMode =
  | "real_local"
  | "debug_fixture"
  | "api_remote";
```

规则：

- 默认必须是 `real_local`。
- `debug_fixture` 只能在 debug/demo 模式启用。
- `api_remote` 预留给未来 VPS 同步。

## 2. 本地账本逻辑结构

未来正式本地账本至少包含：

```text
ledger/
  metadata
  accounts
  instruments
  holdings
  movements
  movement_entries
  dca_plans
  dca_reminders
  categories
  counterparties
  quotes
  fx_rates
  snapshots
  ai_proposals
  evidence_refs
  anomalies
  sync_state
  migrations
```

实现可选择 Rust + SQLite + 加密；Flutter 不直接依赖物理表结构。

## 3. 空账本初始化

`real_local` 第一次启动应有：

- 空 accounts。
- 空 holdings。
- 空 movements。
- 空 dca plans。
- 空 proposals。
- base currency 默认 `CNY`，但允许后续设置。
- 首页显示空状态 CTA：建账户 / 记录基线。

禁止：

- 禁止自动注入示例资产。
- 禁止默认加载 fixture。

## 4. debug fixture 隔离

fixture 规则：

1. fixture 使用独立内存 store 或独立数据库文件。
2. fixture 不写入正式账本。
3. fixture 不参与同步。
4. fixture UI 必须常驻 `DEMO` 标记。
5. fixture 只允许在 `kDebugMode` 或显式 `DEMO=true` 时启用。
6. 离开 fixture 模式后，真实账本仍保持原样。

推荐命名：

```text
ledger.db          // 真实本地账本，未来正式
ledger.fixture.db  // debug/demo only
```

## 5. 写入原则

正式账本写入必须满足：

- 单次写入以 atomic group 为事务边界。
- 写入前完成 schema validation。
- 写入后刷新快照或标记快照过期。
- 已确认记录优先通过 correction 修正，不静默覆盖。
- 每次 AI 写入必须保留 proposal id / evidence refs。

## 6. 迁移原则

```ts
Migration {
  id: string;
  fromVersion: number;
  toVersion: number;
  appliedAt: ISODateTime;
  checksum?: string;
}
```

规则：

- 迁移必须可重复检测。
- 迁移失败不得破坏原账本。
- 迁移前应创建本地备份。

## 7. 备份与导出

MVP 备份需求：

- CSV 导入导出后续做。
- 本地账本应支持手动备份。
- debug fixture 不应被正式备份包含。

未来导出格式：

```text
accounts.csv
holdings.csv
movements.csv
movement_entries.csv
dca_plans.csv
quotes.csv
fx_rates.csv
snapshots.csv
```

## 8. 安全边界

未来正式本地账本应考虑：

- 本地加密。
- 系统安全存储保存登录 token。
- 不在日志中输出完整账户余额、密钥、token、原始图片内容。
- 不把 AI 输入原文无差别写入长期日志。

第一阶段前端不得添加真实密钥、真实 API key、真实账号密码。

## 9. 校验入口

本地账本至少需要这些校验：

- decimal string 格式。
- currency code 非空。
- movement entries 账户存在。
- holding 指向 account / instrument 存在。
- transfer 双边账户存在。
- AI proposal 通过 validation 后才可 approve。
- debug fixture 与 real ledger 路径互斥。

