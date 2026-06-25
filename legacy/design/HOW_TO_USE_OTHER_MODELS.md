# 如何用别的模型跑 App 设计（Visual Language + First Screen）

你当前的需求是：用 **不同于当前 Grok 的模型**（比如 Claude 4 Sonnet/Opus、GPT-4.1、Gemini 2.5 Pro、本地模型等）来生成/迭代财富 App 的视觉语言、设计 tokens、线框和第一个可点界面的完整设计文档。

## 推荐方案（按优先级）

### 1. 最推荐：直接使用便携 Prompt（任何模型都能用）

已经为你准备好一个**自包含、高质量的 Prompt 文件**：

**路径**：`design/prompts/visual-language-and-first-screen.md`

**使用方法**：
1. 打开该文件，全选复制。
2. 粘贴到以下任意地方：
   - Claude.ai（新建 Project 或直接聊天 + Artifacts）
   - Cursor Composer（推荐在项目里用）
   - Windsurf
   - Continue.dev（VSCode / JetBrains）
   - Gemini 网页版
   - ChatGPT
   - 本地模型（Ollama + Open WebUI、LM Studio + Continue）

3. 额外建议（提升输出质量）：
   - 在提示最后再加一句："请严格按照文档结构输出，并确保所有代码片段可以直接复制使用。"
   - 如果你有之前的 design doc，可以把它的内容也一起贴上去，并说 "基于上一个版本改进"。

这个 Prompt 已经把你所有的视觉要求、参考链接、输出结构、PR Plan 要求都写得非常详细，能复现甚至超过之前用内置 design skill 的质量。

### 2. 在当前这个环境里切换模型（使用 Opencode）

这个环境内置了 **Opencode** 控制器，可以让你切换底层模型来做设计和开发。

**步骤**：

1. 在对话中输入（或让我帮你执行）：
   ```
   /opencode
   ```
   或者直接使用技能：
   ```
   使用 opencode-controller 技能启动
   ```

2. Opencode 启动后，使用以下斜杠命令：
   ```
   /models
   ```
   → 选择你想要的模型（Claude、OpenAI、Anthropic、Grok 等）

3. 如果是需要登录的提供商，Opencode 会给出一个登录链接，把链接发给我（或复制给你自己登录）。

4. 认证完成后：
   ```
   /agents
   ```
   选择 **Plan**（设计阶段一定要用 Plan，不要直接 Build）

5. 把 `design/prompts/visual-language-and-first-screen.md` 的内容发给 Opencode，让它用 Plan 模式输出设计文档。

6. 设计确认后，再切到 Build 模式让它写代码。

**重要规则（Opencode 工作流）**：
- 设计类任务永远先用 Plan agent
- 不要在 Build 模式里讨论计划
- 想切换模型就随时 `/models`

### 3. 迭代现有设计（推荐做法）

你已经有一个高质量的设计文档了（`C:\Users\15892\tmp\grok-design-doc-d7d51e2a.md`）。

**最佳迭代方式**（推荐）：

把下面这段文字 + 之前的 design doc 一起喂给别的模型：

```
这是我之前用一个设计流程产出的财富 App 视觉语言设计文档。

请作为顶级产品设计师 + Flutter 架构师，基于这个文档，产出一个**改进版本**，重点加强以下几点，同时保持视觉方向完全一致（Monarch + Kikoff + Wonderous）：

1. 补全所有 Rust + flutter_rust_bridge 数据模型（带完整 struct、enum、#[frb]）
2. 调整 PR Plan，把数据契约（contracts + mock）提前
3. 为所有 6 个核心组件都给出完整的 widget 签名 + build 结构
4. 增加详细的 Risks 章节
5. 给出完整的 M1 seed 数据 + LineChartData 示例
6. 保持深石墨背景、净资产作为唯一英雄、平台适配等所有原有约束

输出完整的 Markdown 设计文档。
```

这种“基于已有版本做针对性改进”的方式通常比从零生成效果更好。

### 4. 其他实用技巧

- **Claude Projects**：把整个 `finwealth` 项目文件夹（尤其是 `design/` 和 `lib/theme/`）上传到 Project，然后用上面的 prompt。
- **Cursor Rules**：可以把这个 prompt 的一部分做成 `.cursorrules` 或自定义指令。
- **多模型并行**：同一个 prompt 同时扔给 Claude 和 GPT，看谁的 tokens / PR Plan 写得更好，然后合并。

## 当前项目里已经准备好的文件

- `design/prompts/visual-language-and-first-screen.md` ← **主提示词**
- `design/HOW_TO_USE_OTHER_MODELS.md` ← 本文件
- `lib/theme/` ← 已按之前设计生成的 tokens（可作为参考）
- `README.md` ← 项目概览

需要我现在：
- 帮你把当前 design doc 的关键部分（tokens + PR Plan + seed）也提取到一个独立文件里，方便喂给别的模型？
- 启动 opencode-controller 并切换模型？
- 或者直接生成一个“基于当前设计文档的迭代专用 prompt”？

告诉我你想用哪个模型（Claude？Cursor？），我可以进一步帮你优化 prompt 或准备材料。