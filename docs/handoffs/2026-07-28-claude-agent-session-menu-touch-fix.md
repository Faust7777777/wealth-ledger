# Claude 任务单：Agent 会话菜单 Android 触摸修复

日期：2026-07-28

## 基线与边界

- 从 Codex 推送后的 `origin/feat/pi-agent-control-center` 新建独立工作树和分支。
- 只改 Flutter 前端、前端测试、必要的 Android 前端集成测试、golden 与本回执；不要改 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、部署脚本或生产数据。
- 完成后推送独立分支，不直接推集成线。

## P0：会话菜单在 Android 上无法真实选择

### 已复现现象

- 环境：Android 36.1 `Small_Phone` AVD，720×1280，最新集成 APK。
- Agent 全屏页打开右上角“会话”菜单后，菜单项在语义树中是 enabled/clickable。
- 真正用 Android 触摸选择另一个会话时，只关闭菜单；当前会话标题和消息不变。
- 同一次触摸会落到菜单下方的 composer，可能顺带弹出输入法。
- Flutter 当前实现位于 `lib/features/agent_panel.dart` 的 `_ConversationHeader`，使用 `PopupMenuButton<String>`。
- 既有 widget 测试只覆盖回调/状态，没有覆盖 Android overlay 的真实 hit-test，因此此前全绿仍漏掉该问题。

### 必须修复

1. 会话选择、新建、重命名、归档在 Android 真触摸下均由菜单项自身消费事件。
2. 选择另一个会话后：标题、消息快照和该会话模型选择同步切换。
3. 点菜单项不得把焦点交给 composer，不得弹出键盘；点菜单外区域只关闭菜单。
4. Android 返回键先关闭已打开的菜单，再按一次才退出 Agent 页。
5. Windows 右栏和窄屏全屏页均不能出现布局回归；不要增加解释性常驻文案。

不要只直接调用 `onSelected` 来证明修复。至少增加一条能执行“打开菜单 → 在 overlay 上真实 tap 某个会话标题 → 断言活动会话变化”的测试；再用 Android integration test 或 AVD 真触摸复验同一路径。若最终不用 `PopupMenuButton`，保持菜单紧凑、可滚动并支持长会话名省略。

## P1：窄屏附件大小不要过度截断

本次 Android 720×1280 真机验收中，`finwealth-acceptance.csv · 41 B` 的 chip 显示成 `finwealth-acceptance.csv · 4…`。功能正确，优先级低于 P0。请在不挤压移除按钮、不引入横向 overflow 的前提下，让短小文件的完整大小优先可见；超长文件名可省略。

需覆盖图片缩略图、CSV/PDF/XLSX 等文件 chip，以及 360×640、720×1280 两种窄屏。历史非图片附件仍不得读取内容字节并送入图片解码器。

## 门禁与回执

- `dart format --output=none --set-exit-if-changed lib test integration_test`
- `flutter analyze`
- Agent 专项测试及 `flutter test`
- `pwsh -NoProfile -File tools/frontend_agent_smoke.ps1`
- `pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1`
- Windows 打包 readiness
- Android AVD 上真实触摸复验，不得只用 `onSelected` 单元测试代替

回执需列出分支、提交、真实触摸复验环境与结果、测试数量、golden，以及未完成项。
