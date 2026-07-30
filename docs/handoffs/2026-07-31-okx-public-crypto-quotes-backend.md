# OKX 任意加密资产结构化报价后端回执

## 目标

让已登记的 SOL、1INCH 等加密资产可以通过服务端只读结构化 provider 查询 USDT 现货最新价，修复“标的已登记但只能依赖模型网页搜索报价”的断链。

## 实现

- `FINWEALTH_QUOTE_PROVIDER=public` 保持 BTC、ETH、USDT 走 CoinGecko，其他 `type=crypto` 且 `quoteCurrency=USDT` 的标的走 OKX 公共 ticker。
- OKX 请求只使用账本中已登记并规范化的 symbol，逐项校验请求/响应 `instId`、正数价格和毫秒时间戳。
- 空数据、不存在交易对、ticker 不匹配、非法数值、非法时间戳、HTTP/网络失败及 OKX 限流码都按单个目标失败，不生成价格。
- CoinGecko 与 OKX 的错误相互隔离；一个 provider 失败不阻止另一个 provider 的目标继续查询。
- lookup 仍然只读。Agent 只能将成功结果转换为 `suggested` 报价候选；用户采用前不写权威报价、不改变估值。
- 不访问用户 OKX 账户，不需要 OKX API key，不读取交易或余额。

## 验证

- Rust 全量：155 passed。
- OKX mock 覆盖 SOL-USDT 成功、空数据、pair 不匹配、非法价格/时间戳、`50011` 限流码和网络失败。
- BTC/ETH/USDT 继续由既有 CoinGecko 专项测试覆盖；非 crypto、非 USDT 和不安全 symbol 不进入 OKX 路径。
- Agent：31 passed；TypeScript check/build 通过。
- OpenAPI/contract check、Rust + Node 双进程 Agent smoke、格式与 diff 检查通过。
- OKX 公共 REST 实探只核验成功码、pair、正数价格和时间戳，不记录具体报价。

## 边界

- 本批不修改 Flutter。
- 初期 OKX 结构化路径只覆盖 USDT 现货交易对；USD/CNY 等估值继续复用现有 Quote + FX 多跳路径。
- 不自动采用候选，不为不存在的交易对 fallback 造价，不配置模型 fallback。
- 未修改 Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站。

## 部署

待提交、备份与生产只读验证后补充。
