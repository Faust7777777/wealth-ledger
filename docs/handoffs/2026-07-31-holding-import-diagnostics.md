# 持仓导入逐项诊断与部署回执

## 问题

Rust 已能为 crypto 与非 crypto 持仓来源确定性登记或复用真实标的，但 Agent sidecar 对非 2xx 响应只保留错误码。模型因此看不到 Rust 返回的 `instruments[index]` 校验信息，缺市场、计价币或匹配冲突时只能重复猜测。

## 修复

- sidecar 新增类型化 `FinwealthRequestError`，保留 HTTP status、稳定错误码和有界诊断。
- 优先读取 `error.details.errors`；最多保留 10 条、每条最多 300 个 Unicode 字符，并清除控制字符。没有逐项错误时才使用服务端 message。
- 投资标的匹配歧义和计价币冲突保留原始 `instruments[index]`，不再只返回代码与市场。
- 不改变 fail-closed 语义：任何缺失映射、歧义或冲突仍在创建持仓审核组前失败，不产生部分标的、部分持仓或报价写入。

## 验证

- Rust：`163 passed`。
- Agent：`38 passed`；TypeScript check/build 与 `npm audit --omit=dev` 通过。
- OpenAPI/契约检查与 Python compile 通过，`git diff --check` 无输出。
- 新增真实 HTTP 形状测试，确认 sidecar 收到两个 `instruments[1]` 错误后保留下标和具体字段，且不会用笼统 message 覆盖逐项诊断。
- Rust 路由测试确认 400 `details.errors` 和 409 message 均保留输入下标。

## 部署

- 实现提交：`ec82309`，已推送 `origin/feat/integration-self-use`。
- ledger/auth 备份：`/var/backups/finwealth/20260730-231542Z`。
- Agent state 备份：`/var/backups/finwealth-agent/20260730-231542Z`。
- 旧 Rust 与 Agent dist：`/opt/finwealth/rollback-20260730-231542Z-holding-diagnostics`。
- 安装 Rust SHA-256：`c3e76ab2cac40329eaefe32b987840b999e019ed0e4bc602bcfc2e48fa975fd6`。
- 安装资产与 Linux 构建候选逐字节一致；Rust、Agent active，公网 readiness 通过。
- 未修改生产账本内容、Agent state、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
