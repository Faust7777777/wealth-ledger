# Pi Agent 非图片附件后端回执

日期：2026-07-28

功能提交：`ddfdb54 feat(agent): support workspace document attachments`

## 已实现

1. 现有附件上传扩展支持 UTF-8 TXT/CSV、PDF、XLSX、ZIP，继续保留 PNG/JPEG/WEBP；单文件上限保持 15 MiB。
2. 所有文件仍保存账号隔离的归档原件和 Agent 工作区副本，metadata/content 回读接口保持不变。
3. 内容校验：文本拒绝 NUL 与无效 UTF-8；PDF 要求 `%PDF-` 和尾部 `%%EOF`；ZIP 解析 EOCD/中央目录边界；XLSX 还要求 `[Content_Types].xml` 与 `xl/workbook.xml`。
4. Pi 运行时只把图片编码为原生视觉输入。其他附件以 JSON metadata 和工作区相对路径加入提示，由 Agent 自主选择读取工具；文件名和内容明确按不可信数据处理。
5. Linux 部署现在要求 `pdftotext`、`unzip`、`python3`。PDF、ZIP/XLSX 分别可用固定系统工具读取；没有新增固定账单解析器或 npm 文档解析依赖。
6. OpenAPI 同步了上传类型、metadata MIME 枚举与原件回读 content types。

## 未包含

- Flutter 文件选择与文件 chip，由 Claude 按独立任务单完成。
- 真实模型读取这些格式的端到端验证，需生产模型配置后进行。
- 压缩包不会自动展开；Agent 应先列目录，只读取任务所需内容。

## 验证

- Node TypeScript check/build：通过；14 passed / 0 failed。
- 覆盖 TXT、CSV、PDF、ZIP、XLSX 归档与回读，伪 XLSX 和路径穿越 ZIP 拒绝。
- npm production audit：0 vulnerabilities。
- OpenAPI/contract check、安装脚本 `bash -n`、`git diff --check`：通过。
- Rust 与 Node 当前源码真实启动 smoke：通过。
