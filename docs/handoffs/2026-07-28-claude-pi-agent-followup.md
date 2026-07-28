# Claude 前端后续任务：Pi Agent 收尾与报价候选

日期：2026-07-28

## 基线与边界

- 当前已集成基线：`origin/feat/pi-agent-control-center @ 0d83fcf`。
- 报价候选后端提交为 `ad371ae`；等 Codex 推送后执行 `git fetch origin`，从 `origin/feat/pi-agent-control-center` 最新 HEAD 新建独立工作树。
- Claude 只修改 Flutter `lib/**`、Flutter `test/**`、前端 smoke、golden 与前端回执；不修改 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、`deploy/**`。

## A. 现有 Agent 前端收尾

1. 给文件选择器增加可注入测试 seam，补一张“待发送图片”草稿区 golden；不要在测试里驱动真实系统文件选择器。
2. 在用户方便运行 App 时，人工目验一次 Windows 右栏和 Android 全屏：打开/关闭、切换会话、输入法顶起、返回键、历史图片。记录结果即可，不为截图抢占用户前台。
3. 真实付费视觉模型、服务器凭据和生产部署归 Codex；Claude 不配置 key，也不把 `configured=false` 当作前端缺陷。

## B. 报价候选审核 UI（后端完成后实施）

后端将提供：

- `GET /v1/agent/quote-candidates`
- `POST /v1/agent/quote-candidates/{candidateId}/review`
  - body：`{"decision":"apply"}` 或 `{"decision":"reject"}`
  - 所有 POST 保持既有 `Idempotency-Key` 与 401 同 key 重放规则。

要求：

1. Agent 面板只对 `suggested` 候选显示一个低强调入口或紧凑卡片；不要把审核表单常驻占满聊天区。
2. 卡片展示标的/币对、报价或汇率、计价单位、报价时间、来源名称和来源域名。可点击来源 URL；不显示内部 ID、哈希、tool 名或存储字段。
3. 用户可以“采用”或“忽略”。采用成功后刷新 quotes、holdings、overview 和估值问题；忽略后候选消失。
4. 采用失败时保留候选并显示服务端简短错误；409 重新拉取列表；重复点击只能产生一次请求。
5. 不显示“AI 可能不准”“仅供参考”“请自行核验”等常驻防御性文案。信息本身只通过来源、时间和数值呈现。
6. fixture/MockClient 不得伪造权威报价已经写入；真实联调必须经过 Rust origin，验证建议状态不改变估值、采用后才更新报价、忽略永不写入。
7. 将已知 tool `finwealth_suggest_quote` 映射成简短活动行“正在整理报价…”；仍不暴露内部 tool 名。

## 暂不分配给前端

- PDF/CSV/XLSX/ZIP 非图片附件上传与工作区读取（文件原样进入 Agent 工作区，由 Agent 选择读取工具并交给模型理解；不做固定账单解析器）。
- 定时任务、主动通知。
- 插件安装与审批。
- 真实模型配置和生产部署。

这些后端能力尚未交付，不能先做假按钮或 fixture 成功路径。
