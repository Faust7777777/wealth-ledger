# 2026-07-15 转账守恒与信用卡还款后端修复回执

## 1. 问题

旧版 Rust 服务只校验 movement entry 的字段形状，没有校验 `type=transfer` 的账务
守恒。客户端或直接 API 调用可以提交同币种“转出 60、转入 50”，草稿仍返回 201，
确认后会凭空减少 10 的净资产。

## 2. 当前服务器模式的转账边界

服务器现在只接受当前产品已实现的简单转账：

- 恰好两个分录；
- 一个 `source/out`，一个 `destination/in`；
- 来源和目标账户不同；
- 币种相同；
- 十进制定点金额数值相等，`60.0` 与 `60.00` 视为相等；
- 若提供 `transferMeta`，账户和金额必须与分录一致；
- 当前不支持手续费、汇损或跨币种 transfer，相关 shape 明确返回 400。

历史 movement 可以没有 `transferMeta`；这是 schema 兼容边界。新客户端仍应发送完整
`fromAmount/toAmount`。

## 3. 回归链路

新增两个 HTTP API 级测试：

1. `local_ledger_rejects_unbalanced_same_currency_transfer`
   - 两个真实账户；
   - 转出 `60.00`、转入 `50.00`；
   - `POST /v1/movements/drafts` 必须返回 400。
2. `local_ledger_credit_card_purchase_and_repayment_preserve_accounting_identity`
   - 银行账户 `1000.00`、信用卡 `0.00`；
   - 信用卡消费 `100.00` 后：资产 `1000`、负债 `100`、净资产 `900`；
   - 银行向信用卡还款 `60.00` 后：银行 `940`、信用卡 `-40`；
   - 汇总为资产 `940`、负债 `40`、净资产仍为 `900`；
   - 负债负余额不触发账户异常。

## 4. 门禁

- `cargo fmt`：通过；
- `cargo test`：115 passed / 0 failed；
- `cargo clippy -- -D warnings`：通过；
- `python tools/contract_check.py`：通过；
- 既有多腿更正 transfer 兼容测试通过。

## 5. 前端配合

Flutter `LocalServerMovementRepository.createTransfer()` 应在 `transferMeta` 中发送：

```json
{
  "fromAccountId": "...",
  "toAccountId": "...",
  "fromAmount": {"amount": "60.00", "currency": "CNY"},
  "toAmount": {"amount": "60.00", "currency": "CNY"}
}
```

服务端仍兼容当前只发送账户 ID 的客户端，但新包应与 OpenAPI 对齐。
