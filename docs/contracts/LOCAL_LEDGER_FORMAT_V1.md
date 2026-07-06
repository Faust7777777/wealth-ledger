# LOCAL_LEDGER_FORMAT_V1

状态：当前实现契约。
用途：定义 `--ledger-path` 真实本地账本的磁盘格式、备份边界、fixture 隔离和校验入口。
非用途：不承诺 SQLite/多文件目录结构；不定义远端同步数据库格式。

## 0. 当前物理格式

当前真实本地账本是一个 UTF-8 JSON 文件，由 Rust local ledger 读写：

```text
ledger.json
ledger.json.tmp   // 写入中临时文件；成功 rename 后可被清理
```

规则：

- `ledger.json` 是唯一真实账本文件。
- 不存在 `accounts.csv`、`movements.csv`、`ledger.db` 等正式磁盘文件。
- 写入流程必须是：读取现有 JSON → 内存中修改 → schema/invariant 校验 → 写入同目录 `.tmp` → 原子 rename 覆盖 `ledger.json`。
- 已存在但损坏/截断的 `ledger.json` 不得被静默重建；必须返回错误，让用户先备份或人工恢复。
- 新建账本只允许发生在目标 `ledger.json` 不存在时。

## 1. 数据源模式

```ts
DataSourceMode =
  | "real_local"      // Flutter 默认空实现，不直接读写 JSON
  | "debug_fixture"   // DEMO/fixture，必须隔离
  | "local_server";   // Flutter 通过 Rust localhost server 访问 --ledger-path
```

规则：

- Flutter 不直接读写 `ledger.json`。
- `local_server` 才能通过 HTTP 调 Rust local ledger。
- `debug_fixture` 只能在 debug/demo 模式启用，必须有可见 `DEMO` 标记。
- fixture 数据不得同步、不得备份进真实账本、不得和 `ledger.json` 共用文件。

## 2. 顶层 JSON 结构

`ledger.json` 顶层对象至少包含这些字段，字段名以实际 JSON/camelCase 为准：

```json
{
  "metadata": {},
  "accounts": [],
  "instruments": [],
  "holdings": [],
  "movements": [],
  "movementEntries": [],
  "dcaPlans": [],
  "dcaReminders": [],
  "categories": [],
  "counterparties": [],
  "quotes": [],
  "fxRates": [],
  "snapshots": [],
  "aiProposals": [],
  "evidenceRefs": [],
  "anomalies": [],
  "syncState": {},
  "syncChanges": [],
  "migrations": []
}
```

说明：

- API 响应可以是投影/聚合结果；磁盘格式不是 HTTP 响应格式。
- `movements` 是业务事件；`movementEntries` 是分录明细。
- `aiProposals` 只保存候选与复核状态；确认前不得影响正式余额、净值、持仓。
- `syncChanges` 是本地/远端同步变更日志，不等于业务流水。

## 3. 空账本初始化

第一次创建 `ledger.json` 时：

- `accounts`、`holdings`、`movements`、`movementEntries`、`dcaPlans`、`aiProposals` 必须为空。
- base currency 默认 `CNY`。
- 不得自动注入示例资产。
- 不得默认加载 fixture。
- 首页应显示空状态 CTA：建账户 / 记录基线。

## 4. 写入原则

正式账本写入必须满足：

- 写操作以 atomic group 或单个明确命令为事务边界。
- 写入前完成金额、币种、账户引用、分录方向、AI validation 等校验。
- decimal string 必须使用统一校验口径；当前最多允许 8 位小数。
- 已确认记录更正必须生成 correction movement，不静默覆盖原记录。
- AI approve 必须消费服务端 `ledgerWrite` / `confirmedMovementIds`，前端不得自行猜测“已入账”。
- 写入后如影响净值/持仓/快照，必须返回或标记 `snapshotInvalidated`。

## 5. 迁移原则

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

- 迁移器必须先备份整个 `ledger.json`。
- 迁移失败不得覆盖原账本。
- 迁移必须可重复检测，不能重复应用同一 migration。
- 迁移完成后必须执行完整账本校验。

## 6. 备份与导出

MVP 备份口径：

- 手动备份 = 复制整个 `ledger.json`。
- 备份不包含 fixture。
- 备份不包含运行时 token、设备密钥、服务端 env。
- CSV 导入导出是应用层能力，不是当前本地账本的物理格式。

未来如提供 CSV 导出，应明确标注为“导出视图”，不是可直接替代 `ledger.json` 的完整备份。

## 7. 安全边界

- `ledger.json` 可能包含完整资产、账户名称、AI evidence 摘要，默认应按敏感文件处理。
- 不在日志中输出完整余额、token、密钥、原始图片内容。
- localhost server 必须保持 loopback bind，并通过 Host allow-list 防 DNS rebinding。
- 真实账本模式建议开启 auth；开发脚本不得无提示地以无 auth 方式打开真实账本。

## 8. 校验入口

本地账本至少需要这些校验：

- decimal string 格式与小数位数。
- currency code 非空。
- movement entries 引用的账户存在。
- holding 指向 account / instrument 存在。
- transfer 双边账户存在且不直接执行外部转账。
- AI proposal 通过 validation 后才可 approve。
- debug fixture 与 real ledger 路径互斥。
