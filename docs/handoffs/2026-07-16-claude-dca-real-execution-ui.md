# 2026-07-16 Claude 前端任务：DCA 真实成交记录表单

执行对象：Claude（Flutter 前端线）。

基线：`origin/feat/subscription-sync-integration @ 44d2d3a`。请从该远端提交新建独立
工作树与分支，不要在 Codex 的集成工作树内修改。

## 1. 背景与必须修复的问题

旧前端调用：

```dart
markExecutedAsProposal(reminderId)
```

不提交成交数据。旧后端因此错误地把 `plannedAmount.amount` 同时当成现金总成本和持仓
数量，例如计划投入 200 元会生成 200 份持仓。

后端 `44d2d3a` 已改为必须提交真实成交输入，并已通过 Rust 全量、契约、dev/mock/Rust
smoke 与真实 JSON 账本 smoke。前端必须适配后才能重新打包与部署。

## 2. 新请求契约

```http
POST /v1/dca/reminders/{reminderId}/mark-executed-as-proposal
Idempotency-Key: ...
Content-Type: application/json
```

```json
{
  "holdingAccountId": "acct_brokerage",
  "quantity": "10",
  "totalCost": {
    "amount": "200.00",
    "currency": "CNY"
  },
  "quoteCurrency": "CNY",
  "executedAt": "2026-07-16T10:30:00+08:00"
}
```

权威定义：`docs/contracts/openapi_v1.yaml` 的 `DcaExecutionInput`。

语义：

- `quantity` 是实际买到的数量，必须是大于 0、最多 8 位小数的十进制字符串。
- `totalCost` 是实际总成本，金额必须大于 0；不得用浮点数转换。
- `holdingAccountId` 必须选择 `balanceMode=holdings|mixed` 的未归档账户。
- `quoteCurrency` 默认使用所选持仓账户的 `defaultCurrency`，允许用户修改。
- `executedAt` 可省略；前端若提供，必须发送带时区的 ISO 时间。
- DCA plan 的资金账户仍由后端读取，前端不得在本请求中另传或覆盖。
- `plannedAmount` 只作为总成本默认值，不得自动填入数量。
- 同一 reminder 已有 pending 时后端返回 409；不要伪造成功。

## 3. 数据层改动

新增不可变 VM：

```dart
class DcaExecutionInput {
  final Id holdingAccountId;
  final DecimalString quantity;
  final Money totalCost;
  final CurrencyCode quoteCurrency;
  final IsoDateTime? executedAt;
}
```

修改接口：

```dart
Future<void> markExecutedAsProposal(
  Id reminderId,
  DcaExecutionInput input,
);
```

更新 `LocalServerDcaRepository` 的 POST body。继续使用 `DevApiClient.postData()` 现有幂等键
与 401 重放机制；认证重放必须复用同一个 key。`real_local` 和 fixture 不得伪造真实成功。

## 4. 最小 UI

点击投资页提醒卡片的“记录已执行”后，先打开一个尺寸受限、可滚动的表单/对话框，用户
确认后才发请求。不要增加常驻解释性段落。

字段：

1. 持仓账户：只列 `holdings` / `mixed` 且未归档账户，显示账户名称。
2. 实际数量：空值，不得用计划金额预填。
3. 实际总成本：默认 `reminder.plannedAmount.amount`，用户可修改。
4. 成本币种：默认 `reminder.plannedAmount.currency`。
5. 报价币种：默认所选持仓账户 `defaultCurrency`，用户可修改。
6. 成交时间：可不展示，省略即由服务端取当前时间；若展示则默认当前本地时间并带时区。

如果没有可用持仓账户，表单应明确引导“先创建证券账户或其他投资账户”，不要发送请求。
提交期间禁用按钮。成功后刷新 due reminders、DCA plans、overview 与 AI pending；409 显示
“本期已有待确认记录”一类简短错误，不得当作成功。

## 5. 必须补的测试

至少覆盖：

1. repository 映射的五个字段完全正确，数量与总成本不同。
2. `quantity=10`、`totalCost=200.00` 时 HTTP body 不会把 200 写到 quantity。
3. 401 刷新重放复用同一 Idempotency-Key。
4. 点击“记录已执行”只打开表单，确认前不发 POST。
5. 持仓账户选择器只显示 `holdings` / `mixed`，排除 cash/liability/archived。
6. 数量空、0、负数、超过 8 位小数时不可提交。
7. 总成本空、0、负数、超过 8 位小数时不可提交。
8. 没有持仓账户时不发请求。
9. busy 时不能重复提交。
10. 成功后刷新四类 provider；409 不伪造成功。
11. 1200×800 与 1440×900 下不溢出、不出现巨型弹层。
12. 真实 local-server 联调：投入 200、数量 10，确认候选后持仓 quantity=10、
    costBasisTotal=200，确认前余额和持仓不变。

## 6. 门禁

```text
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1
pwsh -NoProfile -File tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly
```

## 7. 边界

- 不修改 `server-rs/**`、`docs/contracts/**`、部署配置或生产数据。
- 不恢复旧的无 body 调用，也不由前端猜测成交数量。
- 不实现券商下单、自动确认、自动转账或后台 timer。
- 完成后推送独立分支，回报提交列表、实际测试结果与视觉核验结论。
- 合并、重新打包和生产部署仍由 Codex 负责。
