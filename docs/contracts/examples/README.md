# Contract Examples

这些 JSON 是接口载荷示例，用于前端/后端对齐字段和状态。

它们不是 debug fixture 种子，不得写入正式账本，也不得参与同步。

## 文件

- `ledger_bootstrap_empty.response.json`  
  新设备 / 空账本启动响应。

- `portfolio_overview_empty.response.json`  
  首页空状态：没有账户、没有快照、没有持仓。

- `portfolio_overview_degraded.response.json`  
  首页降级状态：报价过期、在途、DCA 到期、AI 待确认、账户异常并存。

- `ai_modify_movement_diff.response.json`  
  AI 修改已有记录的 old → new diff 示例。

- `dca_mark_executed_proposal.response.json`  
  DCA“记录已执行”只生成候选 atomic group，不下单、不转账。

- `quote_refresh_stale.response.json`  
  报价/汇率刷新部分失败，使用 stale / offline cache 的示例。

