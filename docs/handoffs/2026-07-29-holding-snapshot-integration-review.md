# 持仓快照前端集成审阅

## 结论

`feat/holding-snapshot-ui @ 0df4fc3` 已快进合入 `feat/integration-self-use`。多资产账户、整组审核、Agent 刷新、支持币种和批量更新持仓符合任务单。

任务单文案从“待补报价”改成“未计入合计”的条件分支是正确修正：当服务端返回的价值币种与账户默认折算币种不一致时，它不等于缺报价。

## 集成时修复

发现并修复一个跨前后端刷新缺口：创建接口的 `skippedPositions` 原先只存在于即时响应，刷新 `/v1/ai/proposals/pending` 后会丢失。现在每条快照 movement 都保存结构化 `holdingSnapshot` 元数据；待审核投影会恢复组标题、目标账户和未变化项。

真实 local-server 联调已增加“POST 后重新读取 pending，再确认”的路径，避免只验证即时响应。

## 门禁

- Flutter analyze 无问题。
- Flutter 全量 418 passed / 92 skipped / 0 failed。
- Rust 全量 150 passed。
- holding snapshot 专项 18 passed。
- frontend local-server smoke 通过。
- OpenAPI / contract check 通过。
