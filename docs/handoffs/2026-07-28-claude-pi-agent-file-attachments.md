# Claude 前端任务：Pi Agent 非图片附件

日期：2026-07-28

## 开始顺序

1. 先完成 `2026-07-28-claude-pi-agent-followup-correction.md` 的多候选紧凑修正。
2. 后端功能提交为 `ddfdb54`；等 Codex 推送后，从 `origin/feat/pi-agent-control-center` 最新 HEAD 新建工作树。
3. 只修改 Flutter `lib/**`、Flutter `test/**`、前端 smoke/golden 和回执。

## 已提供的后端

沿用现有附件三个接口，允许类型扩展为：

- PNG / JPEG / WEBP
- UTF-8 TXT / CSV
- PDF
- XLSX
- ZIP

单文件仍为 15 MiB。文件原样归档并复制到 Agent 专属工作区；图片作为模型视觉输入，其他文件由 Agent 选择工作区工具读取。没有固定账单解析器。

## 前端要求

1. 将选图 seam 泛化为附件选择 seam，允许以上扩展名；按真实文件类型发送准确 MIME。
2. 待发送区：图片显示缩略图；其他文件显示紧凑文件 chip（类型图标、文件名、大小、移除）。不读取或展示文件正文。
3. 历史消息先读附件 metadata：图片才走 `Image.memory`；其他文件显示文件 chip，避免把 PDF/ZIP 字节交给图片解码器。
4. 上传失败保留用户仍可重新选择；同一发送动作只提交一次消息。不要宣称文件“已解析”，只表示已附加。
5. 413、MIME/内容不符、UTF-8 不合法分别给一句简短中文。不要显示 MIME、哈希、工作区路径、解析实现或防御性常驻文案。
6. 真实 smoke 至少上传并回读 CSV、PDF、XLSX、ZIP，断言原始字节一致；`configured=false` 时不声称模型已经读取内容。
7. golden：待发送 CSV/PDF chip、含历史文件的消息，明暗主题；360/1200/1440 无 overflow。

## 边界

- 不增加前端本地固定账单解析器。
- 不把附件长期复制到 Flutter 私有存储。
- 不修改后端、OpenAPI、部署脚本或模型配置。
