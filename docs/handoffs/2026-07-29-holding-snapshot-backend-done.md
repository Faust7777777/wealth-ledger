# 多资产持仓快照后端回执

## 实现

- 新增 `POST /v1/accounts/{accountId}/holding-snapshot-proposals`。
- 同一请求的全部变化项共用一个 atomic group，每项保存 previous/target/delta movement。
- 未变化项进入 `skippedPositions`；全部未变化返回冲突，不制造空候选。
- 输入、账户、标的、计价币种、pending adjustment 和 pending interest 在落盘前统一校验。
- 整组沿用既有确认/拒绝机制；确认前不改变 holdings，确认失败不会部分落盘。
- 新增 Agent 工具 `finwealth_propose_holding_snapshot`。它要求先查真实账户和标的，只能生成待审核组，没有确认或报价采用能力。

## 边界

- 没有重做 Account/Holding/Instrument 模型。
- 没有自动创建标的、自动采用报价或自动确认持仓。
- 没有修改 Flutter 前端和生产账本数据。
