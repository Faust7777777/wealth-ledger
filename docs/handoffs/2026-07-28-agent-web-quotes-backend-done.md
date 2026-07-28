# Pi Agent 网页报价候选后端回执

日期：2026-07-28

功能提交：`ad371ae feat(agent): add reviewed web quote candidates`

## 范围

- 只修改 Node Agent sidecar、Agent OpenAPI、后端测试和交接文档。
- 未修改 Flutter `lib/**`、Flutter `test/**`、Rust 账本结构、账本版本或生产配置。
- 结构化 provider 的 `finwealth_refresh_quotes` 保持原行为；网页结果不能绕过审核直接调用它写入。

## 已交付

1. 新 Pi tool：`finwealth_suggest_quote`。支持单个标的报价或单个 FX 汇率，要求正的定点十进制、RFC3339 报价时间、来源名称和实际 http/https 来源 URL。
2. Agent 状态新增账号/账本隔离的 `quoteCandidates`，状态为 `suggested / applied / rejected`；旧状态文件按加法兼容，最多保留 1000 条。
3. 同账本中目标、数值、时间和来源 URL 相同的未审核候选自动复用，避免模型或 tool 重试堆出重复卡片。
4. 新 API：
   - `GET /v1/agent/quote-candidates`
   - `POST /v1/agent/quote-candidates/{candidateId}/review`
5. `reject` 只改变候选状态，不调用账本服务。`apply` 才映射为现有 `POST /v1/quotes/refresh` 的 manual payload；只有响应确认恰好写入一个对应 quote/FX item 后候选才成为 `applied`。
6. 内部写入幂等键稳定为 `agent-quote-{candidateId}`。若报价已写入而 sidecar 在保存候选状态前异常，重试仍由 Rust 幂等层返回原结果，不重复产生写入。
7. 来源 URL 拒绝非 http/https、过长 URL 以及带 username/password 的 URL；候选 API 不包含 shell 输出、网页正文、模型隐藏推理或服务器路径。

## 前端衔接

Claude 后续任务见 `2026-07-28-claude-pi-agent-followup.md`。UI 只展示紧凑候选入口/卡片，采用成功后刷新 quotes、holdings、overview 与估值问题，不添加常驻防御性文案。

## 仍待生产验证

- 尚未配置真实 Pi 模型，因此未实际访问目标报价网站；本轮验证的是候选状态机、审核边界、权威写入映射与幂等。
- 不保证任意网站均允许服务器访问。模型遇到无法访问的来源时应换来源或报告没有候选，不得制造报价。
- 定时抓取和主动通知仍未实现。

## 验证

- Node TypeScript check/build：通过；13 passed / 0 failed。
- `npm audit --omit=dev --audit-level=high`：0 vulnerabilities。
- OpenAPI/contract check：通过，88 paths / 159 schemas。
- `tools/agent_local_smoke.ps1`：Rust 与 Node 当前源码真实启动通过。
- `tools/frontend_agent_smoke.ps1`：Flutter 经 Rust origin 的既有 Agent 联调回归通过。
- `git diff --check`：通过。
