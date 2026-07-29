# Claude 前端后续：AI 图片整理可用性收尾

日期：2026-07-19
基线：Codex 推送本轮图片 provider 后，从最新 `origin/feat/subscription-sync-integration` 派生独立分支。

## 后端行为

接口保持：

```text
POST /v1/ai/proposals/from-image
```

请求体：

```json
{
  "fileName": "receipt.png",
  "mimeType": "image/png",
  "imageBase64": "..."
}
```

- provider 默认关闭时仍返回「待补全」候选。
- `FINWEALTH_AI_PROVIDER=openai_responses` 时，后端识别一张收据、付款截图或交易图片，最多生成一条单账户 `income|expense` 候选。
- 只接受 PNG、JPEG、WEBP；解码后上限 10 MiB。HEIC 不在本轮后端支持范围。
- 400 表示图片字段、格式、Base64、文件头或大小不合法；503 表示 provider 暂时不可用。
- 成功只代表候选已生成。余额在用户确认 atomic group 后才变化。

## 前端改动

1. 图片选择器只保留 PNG/JPEG/WEBP，删除 HEIC。
2. 文件选择是主路径；不要常驻显示大块 Base64 输入框、data URL、MIME 或 10 MiB 说明。若保留粘贴兜底，收进一个低强调的展开项。
3. 选图后显示小预览、文件名和「重新选择」；提交按钮用「整理」或同等级简短动作。
4. 成功后进入现有 AI Review。结构化候选展示标题、账户、金额、币种、时间；待补全候选只提供编辑和拒绝。
5. 400 显示简短中文原因并保留所选图片；503 显示失败和重试，不展示 provider、schema、prompt、环境变量或上游状态码。
6. 创建、编辑、确认或拒绝后刷新 AI pending、首页 pending count、movements、相关账户和 overview。
7. 不新增“AI 不会直接写账”“仅供参考”“请自行核对”“图片只作为证据”等常驻解释文案。

## 必测

1. PNG/JPEG/WEBP 选择、预览和请求映射正确；HEIC 不可选。
2. 真实 Rust smoke：一张测试图片经本地假 provider 返回 expense 候选；确认前余额不变，确认后才扣款。
3. MIME 与文件内容不一致返回 400，图片仍保留且可重新选择。
4. 503 后可重试，不清空页面状态。
5. 360/1200 宽无 overflow；Base64 不在默认页面常驻展示。
6. defensive copy scan 覆盖本任务禁止的解释文案。

只改 Flutter、前端测试和前端 smoke；不改 Rust、OpenAPI、部署脚本、provider 配置或账本格式。
