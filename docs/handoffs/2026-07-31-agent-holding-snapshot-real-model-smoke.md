# Grok 图片持仓快照隔离验收

## 目的

验证生产 Grok 连接能够把交易所截图转成真实、可审核的多资产持仓快照，同时不向生产账本写入测试账户、标的、持仓或待审核项。

## 新增工具

- `tools/agent_vps_holding_snapshot_smoke.py` 只接受 loopback HTTP，并明确拒绝生产 Rust/Agent 端口。
- 调用方必须启动使用临时账本与临时 Agent state 的隔离 Rust 和 sidecar；模型目录可只读复用生产 Grok 连接。
- 脚本创建 CNY 展示的临时 exchange 账户，上传合成 OKX PNG，并要求 Grok 一次提交 BTC、ETH、USDT、SOL 的 `symbol + targetQuantity`。
- 验收检查服务端登记出的真实标的、SOL/USDT 计价、账户支持币种、四项精确数量、单一 atomic review group、`holding_snapshot` 标签、确认前空持仓和权威报价不变。

## 真实运行结果

- VPS 上使用临时端口 `19090/19092`、临时账本和临时 Agent state 运行；生产 Rust 与 Agent 全程保持 active。
- 生产 Grok 原生读取 PNG，`finwealth_propose_holding_snapshot` 成功完成。
- 四个图片资产被服务端登记或复用并进入同一个待审核组；每项目标数量与图片一致。
- 非内置 SOL 的 `quoteCurrency` 为 USDT；账户 `defaultCurrency` 仍是 CNY，并补入 USDT 支持。
- 确认前账户持仓为空，权威报价摘要前后完全一致；脚本没有调用确认、批准或报价采用。
- 两次运行均通过，第二次增加逐 symbol 精确数量断言后再次通过。
- 隔离服务、临时账本、Agent 会话、附件与上传脚本已删除；生产公网 readiness 随后通过。

## 边界

- 本轮没有修改 Flutter、生产账本、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
- 工具用于部署验收，不会自动确认快照，也不会把建议报价写入权威估值。
