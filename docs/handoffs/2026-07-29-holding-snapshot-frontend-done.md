# 2026-07-29 多资产账户与持仓快照前端 · 回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-29-holding-snapshot-frontend-task.md`。

基线：`origin/feat/integration-self-use @ d470766`。
分支：`feat/holding-snapshot-ui`（独立工作树 `finwealth-holding-snapshot`）。
边界核对：对 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、
部署与发布脚本的改动为空（唯一的 `tools/` 改动是把新增的联调用例加进
`frontend_local_server_smoke.ps1` 的测试清单）。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `a1a1d35` | 数据层：VM、映射、仓库方法 |
| `99cd4d5` | P0.1–P0.7 与 P1 界面 |
| `8ef9510` | 18 条回归 + 四组视觉预览 |
| `7105f70` | 真实 local_server 联调用例并接入 smoke |
| （最后一笔） | 本回执 |

## 2. 数据层

- `MovementVm` 增加 `tags` 与 `holdingAdjustment`
  （`previousQuantity` / `targetQuantity`，十进制字符串，不经 double）。
- `AiAtomicGroupVm` 保留**全部** `proposedMovements` 与 `skippedPositions`；
  原来只留第一条，多资产快照会丢掉其余标的。`proposedMovement` 仍是第一条，
  既有调用点行为不变。
- `PortfolioRepository.proposeHoldingSnapshot(accountId, positions, asOf, note)`
  → `POST /v1/accounts/{id}/holding-snapshot-proposals`，
  Idempotency-Key 由 `DevApiClient` 统一生成，401 刷新后重放复用同一个 key。
  DEMO 与 `real_local` 抛 `UnsupportedError`，不伪造成功。
- `CreateAccountInput` 增加 `supportedCurrencies`；发送时默认币种恒在首位。

## 3. P0 界面

1. **多资产判定**（`accountIsMultiAsset`）：`exchange` / `wallet` /
   `balanceMode=holdings` / `mixed` 都按多资产展示，负债账户除外。
2. **逐项信息**：名称 · 代码、原始数量、报价单位（取自 instrument 的
   `quoteCurrency`）、折算价值、报价状态（偏旧/离线缓存/不完整/暂无报价/获取失败；
   正常报价不加标注）。数量永远可见，不会被折算成一个总余额。
3. **合计**：只累加币种与账户折算币种一致且能折算的部分，用 `BigInt` 定点相加，
   不经 double。缺报价或币种不一致的项**被排除而不是按 0 计入**。
4. **低强调入口**：全部因缺报价被排除时显示「N 项待补报价」；
   若存在"有价值但币种不一致"的项，文案改为「N 项未计入合计」，
   不谎称缺报价。点击复用既有估值状态弹窗，没有常驻解释段落。
5. **快照审核卡**（`HoldingSnapshotCard`）：同一 atomic group 里带
   `holding_snapshot` 标签的候选合成一张卡，默认只报「N 项数量变化」
   （以及「N 项数量未变化」），展开后逐项 `previous → target`。
   动作仍只有「接受整组」「拒绝整组」。
6. **Agent 刷新**：`finwealth_propose_holding_snapshot` /
   `finwealth_propose_movement` 的 `tool.completed` 之后，以及
   `run.completed` / `run.failed` 之后刷新待审核入口；工具活动文案
   新增「正在整理持仓…」。创建成功只提示「已加入待确认」+「前往审核」，
   不宣称持仓已更新。
7. **账户编辑**：多资产类账户（exchange/wallet/brokerage/platformWallet）
   新增「支持币种」多选，默认折算币种单独选择且恒被选中、不可取消。
   期初余额表单未被改造成持仓编辑器。

## 4. P1 更新持仓

`HoldingSnapshotDialog`：账户详情持仓区的「更新持仓」入口。

- 一次编辑现有多项数量，只提交**真的改过且格式合法**的行；全部未改动时
  就地提示「没有数量变化」，不发请求。
- 「添加资产」打开可搜索的标的选择器，只列服务端返回的真实 instrument，
  已在列表中的自动排除；**前端不生成 instrumentId**。
- 一次提交一个 Idempotency-Key，401 刷新后重放仍是同一个 key（有断言）。
- 409 → 刷新账户持仓、全局持仓与待审核列表，**弹窗保留、用户输入不清空**。

## 5. 测试

新增 `test/holding_snapshot_test.dart`（18 条，全绿）：

| 任务单必测 | 用例 |
| --- | --- |
| 1 窄屏与矮窗口不溢出 | 多资产列表、审核卡各一条（360x640 / 1200x520） |
| 2 三项一张卡、确认只发一次 | `三项只出一张卡…`、`确认只发一次整组确认请求` |
| 3 pending 期间数量与 overview 不变，确认后一起刷新 | `待确认期间持仓与 overview 不变…` |
| 4 某项清零可提交 | `某项清零可提交`（请求体 `targetQuantity: '0'`） |
| 5 unchanged 不渲染成变化、全 unchanged 409 | `unchanged 不渲染成变化项…`、`全部未变化的 409…` |
| 6 缺 BTC 报价时数量可见、合计不当 0 | `缺 BTC 报价：数量仍可见，合计不把它当 0` |
| 7 401 重放幂等键不变、重复点击只一次 | 两条独立用例 |
| 8 golden | 见 §7 |

另有：逐项数量/单位/合计、币种不一致的入口文案、搜索添加真实标的、
组内候选与 skippedPositions 映射、普通候选不被误判、多资产判定矩阵。

**真实写入验收**：新增
`test/local_server_holding_snapshot_integration_test.dart` 并接入
`frontend_local_server_smoke.ps1`，在真实 local_server 上跑通：
一次提交 BTC/ETH/USDT → 一个审核组三条候选 → 确认前账户零持仓 →
整组确认后三项同时生效；只改一项时未变化项进 `skippedPositions` 且不生成
movement；全部未变化返回 409；清零后数量归零。

## 6. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- 新增专项：18 条全绿；既有持仓校准、账户、投资等用例未受影响。
- `flutter test`：**418 passed / 91 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过（10 个联调用例，
  含新增的持仓快照）。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：通过。
- `pwsh tools/package_remote_android.ps1 -CheckReadinessOnly`：
  `Android server client readiness passed (endpoint mode: runtime)`。
- `git diff --check`：零输出。

## 7. 视觉证据

`PREVIEW_GOLDENS=1 ... --update-goldens` 共 81 条通过。相关四组逐张核验：

- `account_multi_asset_{light,dark}`（400 宽，既有组，已按新版式重生成）；
- `account_multi_asset_narrow_{light,dark}`（360 宽）：合计 + 低强调入口 +
  三行资产各带数量、单位、价值与状态；
- `holding_snapshot_review_{light,dark}`（360 宽，收起）：一张卡、
  「2 项数量变化 / 1 项数量未变化」、只有整组动作；
- `holding_snapshot_review_expanded_{light,dark}`：逐项 `0.25 → 0.4`。

核验结论：窄屏无溢出、无横向滚动；界面只报事实状态与可执行动作，
没有"仅供参考""请自行核实"一类防御性说明（`defensive_copy_scan_test` 通过）。

## 8. 说明与未完成项

- 任务单示例文案是「2 项待补报价」；当被排除的项里存在"有报价但币种与账户
  折算币种不同"的情况时，我改用「N 项未计入合计」。原文案在那种情况下是错的，
  这是唯一一处对任务单文案的偏离。
- 真实 OKX 导出文件的联调（CSV/XLSX/截图 → Pi Agent → 快照审核组）
  未做：需要真实模型与真实文件，按约定不在本批。
- 未启动 AVD。窄屏触摸、更新持仓弹窗在真机键盘下的可用性需要设备验收覆盖。
- 「缺少标的时的创建/匹配流程」按你的排期属于后端下一项；当前前端在
  「添加资产」里只能选已登记的标的，选择器为空时会明确显示没有匹配项。

本回执不含 token、密码、认证文件内容或真实账本数据。
