# Agent 扫描 PDF 视觉读取与附件链路验收

## 问题

PDF/XLSX 已经会上传到 Agent 专属工作区，并在模型运行前使用隔离工具提取内容；但没有文本层的扫描 PDF 会让 `pdftotext` 成功返回空白。旧实现仍把它视为已提供 PDF 文本，模型实际上只知道文件名和路径，看不到页面内容。

## 实现

- PDF 先沿用 `pdftotext`；只有提取结果去除空白后为空，才进入页面视觉路径。
- `pdftoppm` 继续运行在既有 bubblewrap 沙箱中，只挂载当前用户专属 workspace。
- 每页最长边限制为 2000 像素，JPEG 质量 80；整轮附件合计最多 8 页、16 MiB，单页最多 4 MiB，渲染最长 30 秒。
- 逐页检查 JPEG 头尾；渲染目录由服务创建在 workspace 内，并在成功、失败、超时和取消路径统一删除。
- 页面图只发送给当前已选模型；模型不支持图片时明确返回 `agent_model_image_unsupported`，不选择第二模型、不做 provider fallback。
- 普通文本 PDF、XLSX、CSV/TXT、图片上传和持仓审核逻辑保持原路径。
- VPS 安装检查新增 `pdftoppm`；它与既有 `pdftotext` 同属 `poppler-utils`。
- `agent_vps_holding_snapshot_smoke.py` 泛化为 PNG/TXT/CSV/PDF/XLSX 附件 smoke，同一验收继续检查真实标的登记、单一持仓审核组、报价候选和确认前无权威写入。

## 回归与真实验收

- Agent 全量 `37 passed`，新增：
  - 空文本 PDF 转为视觉输入，并产生可观察的渲染工具事件；
  - 多 PDF 的页面限制按整轮附件集合计算，不是逐文件放大。
- Rust 全量 `162 passed`；TypeScript check/build、OpenAPI/契约检查、Python compile、`git diff --check` 全绿。
- npm production audit：0 个已知漏洞。
- Linux workspace bubblewrap 边界 smoke 通过。
- VPS 生产用户加 `no-new-privileges` 实测：文本 PDF 与 XLSX 提取器均能读取标记；真正无文本层 PDF 能在候选代码中生成合法 JPEG，且没有渲染临时目录残留。
- 使用临时端口、临时账本、临时 Agent state 和复制出的临时 Grok 配置分别完成真实 CSV、文本 PDF、XLSX 验收：
  - CSV/PDF 精确生成 BTC、ETH、USDT、SOL 四项持仓；
  - XLSX 精确生成 AAPL 与 510300 两项投资持仓；
  - 均只有一个 atomic review group，并生成独立 suggested 报价/FX 候选；确认前不改变持仓或权威报价。
- 真实 Grok 扫描 PDF 验收使用标准字体先栅格化、再封装成无文本层 PDF；Grok 精确恢复四项数量并走完同一审核和估值闭环。
- 所有隔离服务、测试账本、会话、附件、模型副本和临时端口均已清理；生产账本没有写入测试数据。

## 部署

- 实现提交：`af05fb6`，已推送 `origin/feat/integration-self-use`。
- VPS 从该提交归档执行 TypeScript check/build、Agent 37 项测试和 production audit；安装 dist 与候选逐文件一致。
- Agent state/模型凭据备份：`/var/backups/finwealth-agent/20260730-224111Z`。
- 精确上一提交 `b877bc4` 的回滚 dist：`/opt/finwealth/rollback-agent-20260730-224228Z`。
- Rust 与 Agent 服务均为 active；公网 `https://wuwaidut.com` readiness 与 health 通过，根分区约 39 GB 可用。
- 未修改 Flutter、Rust 二进制、生产账本、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。

## 部署事件

首次部署脚本错误假定 `/opt/finwealth/tools/backup_vps_agent.sh` 已安装。备份命令在任何旧 dist 复制前失败，而回滚函数没有区分“尚未进入替换阶段”，错误删除了当前 dist，造成 Agent 短暂不可启动；Rust 和生产账本始终正常。

发现后立即从已完成全部门禁的 VPS 候选恢复 dist，Agent 与公网 readiness 随后通过；Agent state 和模型目录未被删除或改写。之后从候选源码运行正式备份脚本，并从 `b877bc4` 重新构建精确旧 dist，补齐备份与回滚资产。

后续部署脚本必须遵守：备份或旧版本复制失败时直接退出，不调用会删除当前安装的回滚函数；只有成功完成旧版本复制并实际交换目录后，才允许执行恢复替换。
