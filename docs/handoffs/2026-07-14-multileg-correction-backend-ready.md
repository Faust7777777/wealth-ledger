# 2026-07-14 多腿交易更正后端回执

## 1. 分支与基线

- 分支：`feat/multileg-correction-proposals`
- 基线：`feat/subscription-sync-integration@1394c3a`
- 范围：Rust real-local 后端、OpenAPI/Markdown 契约、contract checker、Rust/真实 HTTP smoke。
- 未修改 Flutter 页面或 Repository。

## 2. 新能力

`POST /v1/movements/corrections` 保留原有单分录 `proposedDiffs`，新增：

```json
{
  "targetMovementId": "movement_id",
  "reason": "实际只转了 25 元",
  "replacementEntries": [
    {
      "accountId": "source_account",
      "amount": "25.00",
      "currency": "CNY",
      "direction": "out",
      "role": "source"
    },
    {
      "accountId": "destination_account",
      "amount": "25.00",
      "currency": "CNY",
      "direction": "in",
      "role": "destination"
    }
  ]
}
```

`replacementEntries` 是整笔交易更正后的完整分录，不是局部 patch。后端生成一个
pending correction movement，其中依次包含：

1. 原 movement 每条 entry 的反向腿；
2. replacement 的全部新腿。

确认前不改变余额/持仓；确认时作为一个 atomic group 原子应用。原 confirmed movement
和原 movement entries 永不改写。

## 3. 安全边界

- replacement 必须是非空完整分录数组。
- 客户端传入的 entry ID 被忽略，由服务端重新生成。
- replacement 的账户、金额、方向和 role 复用正式 movement entry 校验。
- 按 account/currency/instrument 聚合后的账本效果与原记录相同时返回 400，禁止 no-op。
- 同一 target 同时最多一个 pending correction；重复候选返回 409。
- correction 确认后继续追加 `operation=correction` 的 movement sync outbox change。
- 不使用 last-write-wins，也不原地编辑 confirmed 数据。

## 4. 验证结果

- Rust targeted correction tests：2 passed。
- Rust full suite：109 passed。
- Clippy `--all-targets -- -D warnings`：通过。
- rustfmt check：通过。
- OpenAPI/contract checker：通过，OpenAPI 现为 116 schemas。
- real-local ledger smoke：通过，包含 transfer 40→25 的真实多腿更正。
- mock/dev/Rust server smoke：通过。
- Python syntax check：通过。

真实回归验证了：

- 原 transfer 确认后余额 60/40；
- correction pending 时仍为 60/40；
- correction 确认后原子变为 75/25；
- 原 movement 仍保留 40/40；
- correction proposal 有四条腿；
- no-op 返回 400，重复 pending correction 返回 409。

## 5. 前端后续

当前 Flutter `CreateCorrectionInput` 仍只有 `oldAmount/newAmount`，多腿页面尚未提交
`replacementEntries`。前端后续应：

1. 对多腿 movement 提供完整 entry 编辑表单；
2. 发送完整 `replacementEntries`；
3. 展示后端返回的反向腿和 replacement 腿 diff；
4. 保持确认前余额不变，确认后再刷新 accounts/movements/overview；
5. 处理 no-op 400 和重复 pending 409。

在该前端接线完成前，API 和真实账本能力已可用，但 Windows UI 仍不会暴露多腿更正入口。

