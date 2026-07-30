# 持仓快照自动生成估值候选

## 问题

图片、PDF 或表格中的交易所/券商持仓已经能生成待审核快照，但快照工具结束后是否继续查询报价依赖模型自行决定。结果可能只有数量候选，没有对应标的报价与折算汇率候选；用户确认持仓后仍无法估值。

## 后端实现

- crypto 与 investment 持仓快照工具在 ensure 和快照提案成功后，确定性触发一次结构化报价 lookup。
- 只查询来源中正数量的真实 `instrumentId`；零数量项不产生无意义报价。
- sidecar 读取目标账户的 `defaultCurrency`，根据每个标的的 `quoteCurrency` 自动请求所需 FX 路径：
  - AAPL/USD 在 CNY 账户中同时请求 USD/CNY；
  - SOL/USDT 在 CNY 账户中由 Rust 展开为 USDT/USD 与 USD/CNY。
- lookup 返回的标的报价与 FX 都保存为独立 `suggested` 候选，快照与报价分别审核。
- 模型不会收到第二次手动查价指令，工具提示明确禁止对同一批标的重复调用报价工具。
- lookup 发生离线、超时、返回缺项或用户在快照之后取消运行时，不会把已持久化的快照误报为失败，也不会重试快照；工具结果用 `quoteLookupCompleted=false` 表示附属步骤未完成，后续定时刷新仍可补齐。
- 没有自动确认持仓、自动采用报价或直接改变估值。

## 回归

- 新增投资快照回归：一笔 AAPL 快照严格按 `ensure → snapshot → account → lookup` 顺序执行，同时生成一个标的候选和一个 USD/CNY 候选，两者均保持 `suggested`。
- 新增失败隔离回归：快照已经返回 pending 后，报价 provider 失败只记录 lookup 未完成；工具仍成功且 ensure/snapshot 各只调用一次。
- 契约检查现在要求 snapshot callback、结构化 lookup、候选持久化和 Pi Engine 生产接线同时存在。
- 本地门禁：Rust `160 passed`、Agent `35 passed`、TypeScript check/build、Python compile、OpenAPI/契约检查、`git diff --check` 和 npm audit 全绿，production audit 为 0 个已知漏洞。

## 真实 Grok 隔离验收

- VPS 使用临时端口、临时账本、临时 Agent state 和候选 dist，复用生产 Grok 连接读取四资产 OKX PNG。
- Grok 一次创建 BTC/ETH/USDT/SOL 的单个持仓审核组，数量逐项与图片一致。
- 工具自动生成 4 个标的报价候选和 2 个 FX 候选（USDT/USD、USD/CNY），全部为 `suggested`。
- 模型运行结束时确认权威持仓和权威报价均未改变。
- 测试程序随后模拟用户明确确认持仓并逐项采用报价；确认前持仓没有市值，采用后四项均同时拥有 CNY `marketValue` 与 `accountMarketValue`。
- 测试完成后临时服务、账本、Agent state、会话、附件、图片与源码均已清理，没有写生产账本。

## 部署

- 实现提交 `8a5e086` 已推送 `origin/feat/integration-self-use`。
- VPS 候选重新执行 Agent 35 项、TypeScript build 与 production audit。
- 部署前 Agent 状态备份：`/var/backups/finwealth-agent/20260730-214920Z`。
- 当前部署的旧 dist 回滚目录：`/opt/finwealth/rollback-20260730-215109Z`。
- 第一次替换探针在 Agent 尚未开始监听时过早请求，按设计恢复旧 dist；随后改为最长 20 秒的就绪轮询并重新部署。最终安装目录与候选逐文件一致。
- Rust/Agent 服务均为 active，公网 `https://wuwaidut.com` readiness 通过，根分区约 39 GB 可用。
- 未修改 Flutter、Rust 二进制、生产账本、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。

## 前端现状

现有 Flutter 已在持仓快照工具完成和 run 结束时刷新待审核与报价候选，因此无需新增 API。新版后端上线后，用户上传 OKX/券商持仓并等待本轮对话结束，即应同时看到持仓审核组和紧凑的“报价建议 N”入口。
