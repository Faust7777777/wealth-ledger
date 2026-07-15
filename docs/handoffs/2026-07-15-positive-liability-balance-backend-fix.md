# 2026-07-15 信用卡正余额净值算法修复回执

## 1. 问题

生产可用性审计发现，旧版净值汇总只要账户被识别为信用卡、贷款或
`balanceMode=liability`，就无条件对账户合计余额取绝对值计入负债。

这会把信用卡溢缴款等正余额算错。例如信用卡余额为 `+5.00 CNY` 时，旧算法得到：

```text
grossAssets=0.00
totalLiabilities=5.00
netWorth=-5.00
```

正确结果应为：

```text
grossAssets=5.00
totalLiabilities=0.00
netWorth=5.00
```

## 2. 修复后的算法

纳入净值且可估值的账户统一按合计余额符号汇总：

- 合计余额 `< 0`：绝对值计入 `totalLiabilities`；
- 合计余额 `> 0`：计入 `grossAssets` 和资产配置；
- 合计余额 `= 0`：不增加资产或负债；
- 账户类型只决定负余额是否是正常负债：信用卡/贷款负余额不触发异常，普通资产账户
  负余额继续产生 `negative_balance`/质量异常。

因此信用卡溢缴款、贷款退款等正余额不会再被误算成欠款，同时既有负债符号和还款
流水算法保持不变。

## 3. 回归证据

新增公共 HTTP API 级测试：

```text
local_ledger_positive_credit_card_balance_is_an_asset_not_debt
```

测试通过真实 `POST /v1/accounts` 创建 `+5.00 CNY` 信用卡账户，再读取 overview 与
allocation，断言：

- `grossAssets=5.00`；
- `totalLiabilities=0.00`；
- `netWorth=5.00`；
- `accountAnomalyCount=0`；
- allocation 为“其他”且占比 `100.0`。

旧算法下该测试稳定失败，修复后通过。

## 4. 门禁

- `cargo fmt --check`：通过；
- `cargo test`：113 passed / 0 failed；
- `python tools/contract_check.py`：通过；
- OpenAPI：64 paths / 116 schemas；
- 订阅、同步、认证、备份恢复、生产拓扑等既有 contract checks 全部通过。

## 5. 前端配合

Claude 前端任务单位于：

```text
C:\tmp\2026-07-15-claude-account-liability-ux-handoff.md
```

前端仍需把负债原始负数展示为正的“当前欠款”，并将正余额显示为“余额/溢缴款”；
不得在 mapping 层抹掉原始符号。
