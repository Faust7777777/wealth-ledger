# 2026-07-07 前端回执 + 转后端两项 给 Codex

范围：前端线（Flutter）本轮已完成。以下报告闭环情况，并把两件我审查中发现、但归后端线的问题正式转交。

## 1. 前端已完成（feat/frontend-skeleton，未 push，推送/合并归你）

对应 `docs/handoffs/2026-07-06-frontend-fixes-for-claude.md` 四项 + 自查补漏，提交栈：

- `1b0e6e4` capability gating 骨架 + confirm 结果消费（记录 sheet/添加账户/AI approve/快照；manual/transfer/reconcile 返回 ConfirmResultVm，「已入账」只凭 ledgerWrite）
- `fca794f` 深层写入口 gating（账户详情编辑/归档、各深页添加账户 CTA、发起更正、taxonomy 创建/编辑/合并）
- `78b94aa` 三个稳定性修复：登录/刷新/登出/手动刷新时 `invalidate(capabilitiesProvider)`（否则 server 后起或登录后写入口锁死到重启）；DCA 三按钮防双击；DevApiClient 401 单飞刷新并重放一次
- `4cb5326` ErrorStateView 对 401（去登录）/连接失败（启动指引）给可行动引导
- `e1393fc` 录入确认文案回归测试

交接清单第 1 项 AI 部分、第 3 项契约别名由你先前的 `c939bdc` 已完成，未重做。

验证：`flutter analyze` 净；`flutter test` 40 全绿。

## 2. 转后端：写端点缺幂等键（中优先级）

- 证据：`docs/contracts/openapi_v1.yaml` 声明了约 30 处 `idempotencyKey` 参数；`server-rs/src/main.rs`、`local_ledger.rs` 未见任何读取/去重实现（grep `idempotency` 无命中）。
- 影响：网络重试或用户连点会生成重复候选/草稿。前端已在 DCA 三按钮加防双击缓解，但根治需服务端按 `Idempotency-Key` 头（或请求体键）对 create 类端点去重。
- 建议：`/v1/movements/drafts`、`/v1/dca/reminders/{id}/mark-executed-as-proposal`、`/v1/ai/proposals/from-*` 落库前先查同键是否已处理，命中则返回原结果。

## 3. 转后端/构建：打包产物是只读空壳（中优先级）

- 证据：`tools/package_release.ps1` 与 `.github/workflows/package.yml` 都是 `flutter build windows` / `build apk --debug`，无 `--dart-define=DATA_SOURCE=local_server`。
- 影响：默认 `DATA_SOURCE` 走 realLocal（只读空账本），打出来的 zip/APK 装上后所有写入口都被 capabilities 正确锁死——即产物无法记账。这在引入 gating 后从"点了报错"变成"入口直接禁用"，更需要构建侧明确目标模式。
- 建议：桌面自用包应 `--dart-define=DATA_SOURCE=local_server --dart-define=API_BASE=http://127.0.0.1:8791` 打包，并让安装引导带起本地 server。Android 形态需产品决策（见下）。

## 4. 需产品决策（非前端可自决）：Android 数据源

手机端无本地 Rust server 可连，APK 永远是只读空壳。方向二选一：Rust core 走 FFI 嵌入手机端，或手机连桌面/VPS 的 server。这决定后续排期，留给用户拍板。
