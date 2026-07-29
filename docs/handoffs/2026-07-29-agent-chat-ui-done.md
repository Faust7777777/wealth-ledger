# 2026-07-29 Agent 对话渲染改造 · 回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-29-claude-agent-chat-ui.md`。

基线：`origin/feat/pi-agent-control-center @ 4cd3e17`。
分支：`fix/agent-chat-ui`（独立工作树 `finwealth-agent-chat`）。
边界核对：对 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、
部署与发布脚本的改动为空。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `086bbea` | 渲染层替换：适配层 + flutter_chat_ui 承载对话 + 面板接线 |
| `ac14219` | 10 条 P0 回归 + 三组新视觉预览 + 代码块样式 |
| `d966908` | 与本次无关的既有失效用例修正（见 §8） |
| （最后一笔） | 本回执 |

## 2. 依赖与许可

| 包 | 版本 | 许可 |
| --- | --- | --- |
| `flutter_chat_ui` | 2.11.1 | Apache-2.0（flyerhq） |
| `flutter_chat_core` | 2.9.0 | MIT（FLYER LABS LTD） |
| `gpt_markdown` | 1.1.8 | BSD-3-Clause（The Infinitix Authors） |

未从 Chatbox / Cherry Studio / Open WebUI / LobeHub 复制任何代码；
deepchat 只作为"紧凑工具活动 + 输出层级"的交互参照，未引入其代码。

传递依赖新增较多（`dio`、`provider`、`cross_cache`、`idb_shim/sembast`、
`flutter_svg`、`flutter_math_fork`、`path_provider` 全平台实现等）。
其中 `path_provider_android 2.3.1` 会带入 `jni`/`jni_flutter`，
因此 `windows/flutter/generated_plugins.cmake` 的 FFI 列表多出 `jni`
（该文件由 `flutter pub get` 生成，已随提交）。真实构建结果见 §7。

## 3. 映射边界（`lib/features/agent_chat_adapter.dart`）

纯函数、无 Riverpod 依赖、可独立测试：

- `user` → 用户文本消息，附件 ID 走 `metadata`，不进正文；
- `assistant + queued/streaming` → 包的流式文本消息（`Message.textStream`）；
- `assistant + completed/failed` → Markdown 文本消息；
- `system` → 返回 `null`，不进入可见对话流；
- Finwealth 的消息 ID **原样**作为包内消息 ID，同一条消息在流式与完成两个阶段
  ID 不变，因此快照 + 重放不会新增行。

SSE 合并、游标续接、会话切换仍然只在 `agentChatProvider`。
渲染层通过 `didUpdateWidget` 与领域状态对账：ID 序列不变时逐条 `updateMessage`，
序列变化才 `setMessages`；包内不持有第二份会话存储。

## 4. 交互实现（`lib/features/agent_chat_view.dart`）

- 助手消息：整宽、无底色的阅读区（`decoration == null`，有测试断言），
  正文按 Markdown 渲染，段落/列表/强调/链接/行内代码/围栏代码都走渲染器。
- 用户消息：右侧紧凑气泡，宽度跟随内容，上限 420。
- 流式：`textStreamMessageBuilder` 里只 `select` 这一条消息的正文，
  增量到达时不整表重建，也不是一个不断重建的巨型 `Text`。
- 真实换行由 Markdown 渲染器成段；**Flutter 侧没有做任何 `\n` 两字符替换**。
- 工具活动：底部一行低强调 `AgentActivityRow`（转圈 + 中文说明），
  `tool.completed` 后由控制器清空，不留常驻卡片；顺带补上
  `finwealth_lookup_fx_candidate → 正在查询汇率…` 的映射，未知工具仍回落到
  「正在处理…」，任何情况下都不显示工具标识或参数。
- 附件：历史图片仍先读元数据再解码字节，PDF/TXT/CSV/XLSX/ZIP 仍是紧凑文件 chip，
  绝不交给图片解码器（既有 `AgentAttachmentPreview` 原样复用）。
- 报价建议、记忆审批、通知入口、断线提示、composer 全部留在面板层，
  没有被序列化进助手正文。
- composer 仍由面板提供（包自带 composer 用 `SizedBox.shrink()` 关掉），
  安全区与键盘避让维持原状；列表 `handleSafeArea: false` 避免重复留白。
- 新增文案只有「还没有对话」（原有空态）与工具活动说明，
  没有加入任何解释性/免责性文案，`defensive_copy_scan_test` 通过。

代码块与行内代码统一用应用字族 + 等宽数字，不额外打包等宽字体：
`monospace` 在 Windows 上并不是可靠的字族名，golden 环境也没有该字体，
用系统等宽会得到不可核验的字形。

## 5. P0 回归覆盖

新增 `test/agent_chat_ui_test.dart`（10 条，全绿）：

| 任务单条目 | 用例 |
| --- | --- |
| 1 真实换行成段、无字面 `\n` | `真实换行渲染成多段，且看不到字面 \n` |
| 2 1500 字中文 360x640 / 720x1280 不溢出且不着色 | `1500 字中文回答…` |
| 3 短用户消息紧凑右气泡 | `短用户消息是右侧紧凑气泡，不铺满整行` |
| 4 增量 A/B/C 单条 + 完成后正好 ABC | `增量 A/B/C 只更新同一条…` |
| 5 快照 + 重放不重复不翻倍 | `快照 + 重放：仍是一条助手消息，正文不翻倍` |
| 6 Markdown 列表/行内码/围栏码/链接，明暗主题 | `Markdown 列表、行内代码、围栏代码与链接…` |
| 7 工具活动紧凑且无内部标识 | `工具活动只有一行中文说明，不出现内部标识` |
| — 映射纯函数 | `system 不进入可见对话流；ID 原样保留` 等 3 条 |

任务单第 8/9/10 条由既有用例覆盖，本次改造后仍全绿：

- 8 历史 PNG 缩略图 / 历史 PDF 只出 chip 且不取字节 →
  `agent_panel_test.dart` 的 `历史附件` 组（3 条）。
- 9 10 条候选仍只占紧凑入口、聊天区高度不被挤压 →
  `agent_panel_test.dart` 的同名用例；其中"聊天区"的量取点从
  `ListView` 改为 `AgentTranscript`（对话流不再是 `ListView`），断言阈值未放松。
- 10 键盘、返回键、会话 sheet、模型 sheet、NavigationRail →
  `agent_session_menu_test.dart`（真实触摸）与 `agent_panel_test.dart`
  的宽度矩阵用例。

## 6. 视觉证据

`PREVIEW_GOLDENS=1 flutter test --update-goldens test/preview_golden_test.dart`
共 65 条通过。新增三组（明/暗各一）并逐张肉眼核验：

- `agent_chat_markdown_{light,dark}`：360 宽的多段 Markdown 回答；
- `agent_chat_activity_{light,dark}`：附件 chip + 一行工具活动；
- `agent_chat_wide_panel_{light,dark}`：1280 窗口内 360 宽右栏 + 长回答。

既有 `agent_panel_streaming_{light,dark}` 即"短用户消息 + 流式回复"，已重新生成。

核验结论：没有字面 `\n`、没有工具标识或内部 ID、助手侧没有大块着色气泡、
composer 未被裁切、无横向溢出；观感是文档式对话而不是堆叠通知卡。
（golden PNG 按仓库约定不入库。）

`_settleEntrance` 多推进两拍：对话列表首帧后会排一次"滚动到底"（延时 + 有限动画），
不推进会在测试结束时留下 pending timer。

## 7. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- Agent 专项：`agent_chat_ui_test` 10、`agent_panel_test`、`agent_session_menu_test`、
  `agent_controller_test`、`agent_mapping_test`、`agent_automations_test`、
  `agent_expired_session_test` 合计 103 条全绿。
- `flutter test`：**322 passed / 75 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：通过。
- `git diff --check`：零输出。

新依赖会带入 `jni` FFI 插件并改写 `generated_plugins.cmake`，
所以额外做了两次真实构建（不在任务单要求内）：

- `flutter build windows --release`：117.5s，产出 `finwealth.exe`。
- `flutter build apk --debug`：Gradle 121.3s，产出 `app-debug.apk`。

两个平台的构建链路都没有因为新依赖断掉。

## 8. 与本次改造无关的既有失效

`test/subscription_next_charge_test.dart` 的
`本月已续费：手动改下次扣费日为更晚日期并提交` 写死了当月 28 日，
过了 28 号之后日期选择器不允许回选，用例必然失败（今天 29 号）。
已改为按当月最后一天推导（`d966908`）。

同一处修正也存在于 `fix/android-self-update-corrections`（当时同样命中），
两条分支若一起合入，这个文件会有一处可直接取任一侧的冲突。

## 9. 未完成 / 真机缺口

- 仍未启动 AVD（约定不抢占前台）。Android 真机上的键盘避让、返回键层级、
  长回答滚动手感、Markdown 在真实字体下的行距，需要在设备验收清单里过一遍。
- 桌面端右栏的实际观感只有 golden 证据，没有在真实窗口里拖拽过宽度。
- 传递依赖显著变多（见 §2）。若发布体积或 Android 构建有顾虑，
  可以在集成时评估是否要收敛 `gpt_markdown` 的可选能力（LaTeX/SVG 相关）。

本回执不含 token、密码、认证文件内容或真实账本数据。
