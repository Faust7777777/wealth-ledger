# 2026-07-13 前端集成待办给 Claude

范围：只改 Flutter 客户端、前端测试、字体资产与前端交接文档。不要改
Rust ledger、VPS 脚本或后端契约；后端当前分支是
`feat/backend-hardening@ff083b3`。

## 当前分支与发布状态

- 最新前端：`feat/frontend-skeleton@99c1fc8`，本地未推送。
- 已公开备份的安全前缀：`backup/frontend-pre-font-20260711@c1a609d`。
- 后端：`feat/backend-hardening@ff083b3`，已推送。
- 重设计：`feat/redesign@68835ac`，已推送；其工作树另有未提交 import。
- 后端与最新前端的 `merge-tree` 当前无冲突；完整前端暂不能公开的原因是
  字体许可与来源，而不是 Git 冲突。

## P0：补齐 Idempotency-Key，否则所有真实写入都会失败

后端所有非 auth 持久化 `POST/PATCH/PUT/DELETE` 均要求
`Idempotency-Key`（1–128 字节可见 ASCII）。当前
`lib/data/api_mock_repositories.dart` 的 `DevApiClient` 没有发送该 header，
所以打成 `local_server` 的 Windows 客户端会在业务写入时收到 400
`invalid_idempotency_key`。

实现要求：

1. 每次逻辑写操作只生成一个高熵 key；建议用 `Random.secure()` 生成至少
   128 bit，再编码为小写 hex 或 URL-safe base64。
2. key 必须在进入 `_send()` 的第一次写调用前生成，并显式传给
   `_dispatch()`；不能在每次网络 attempt 内重新生成。
3. 当前 `_send()` 遇到 401 会 refresh 后递归重放。重放必须复用第一次请求
   的同一个 key。
4. `GET` 与 `/v1/auth/*` 不要求该 header。新的独立用户操作应使用新 key。
5. 不要持久化或记录 key；它只需要覆盖一个逻辑请求及其自动重放生命周期。

必须增加 HTTP client 回归测试：

- 首次业务 POST 返回 401、refresh 成功、业务 POST 重放成功；断言两次业务
  请求的 `Idempotency-Key` 完全相同。
- 两次独立业务写调用得到不同 key。
- PATCH 同样带 key。
- GET 与 auth refresh 不依赖业务幂等 key。

后端 `tools/package_release.ps1` 现在 fail-closed：实现和测试中都出现
`Idempotency-Key` 后才允许生成“可写 Windows 自用包”。静态门禁只是防止
误打包，以上行为测试才是完成证据。

## P0：替换不可公开分发的 MiSans 原始字体

`assets/fonts/MiSans.ttf` 来自 WPS 缓存，字体 metadata 没有 license/URL。
小米官方许可允许在 App 作品中使用字体，但限制进一步单独分发字体文件，
且要求副本保留许可。把原始 TTF 放进公开源码分支不应继续。

处理建议：

1. 用明确允许源码再分发的 OFL 字体替代 MiSans，例如官方 Noto Sans SC；
   不要仅用另一个本机缓存文件替换。
2. 为每个字体在仓库中加入对应许可文本与来源说明，建议放在
   `assets/fonts/licenses/`。
3. `NotoSerifSC-600.ttf` 虽声明来自 OFL 字体，但当前是自制子集、metadata
   标记 `non-release`，且未随附 OFL。补充官方来源、OFL 文本，以及可复现的
   subset 字符集/命令说明。
4. 更新 `pubspec.yaml`、`AppType` fallback 和 dark/light golden，再检查缺字
   时的 fallback。

参考官方许可：

- MiSans：https://hyperos.mi.com/font/en/download/
- Noto Serif SC OFL：https://github.com/google/fonts/blob/main/ofl/notoserifsc/OFL.txt

完成前不要推送包含这两个当前二进制的完整前端历史到公开仓库。

## P1：合并视觉线时取并集，不要直接选一边

`feat/frontend-skeleton` 与 `feat/redesign` 的模拟合并会冲突于：

- `lib/features/account_detail_page.dart`
- `lib/features/accounts_page.dart`
- `lib/features/ai_review_page.dart`
- `lib/features/liabilities_page.dart`
- `lib/features/overview_page.dart`
- `lib/theme/app_theme.dart`

合并原则：

- 保留最新前端的 token 驱动组件子主题、reduce-motion、skeleton、
  `PressableScale`、`AnimatedMoneyText`、宽屏 sidebar、空态插画和资产环图。
- 吸收 redesign 的 `MoneyText`、`LeadingAvatar`、`StatusPill` 与已验证页面布局，
  避免复制出第二套主题/字体/Hero。
- `feat/capabilities-gating@f0ae594` 不是最新前端祖先，但最新前端已有更完整的
  gating；按行为与测试对照，不要机械 cherry-pick 旧 slice。

## P1：补齐最新前端交接文档

现有 `2026-07-11-frontend-visual-polish.md` 没覆盖后续提交。更新时至少记录：

- `ba239e7` 宽屏 256px sidebar
- `2f67ad2` 首次使用空态品牌插画
- `0d5d95b` light overview golden
- `3b530f2` Noto Serif SC 标题层级及许可待办
- `00e1f9a` 资产构成环图
- `99c1fc8` nav icon theme 格式化收口

## 产品决策项（不要自行实现）

- Android 可写数据源仍需在 Rust FFI 与连接认证 VPS 之间选择。
- 桌面三栏 inspector、Android 下拉刷新、OpenContainer 转场属于体验迭代，
  优先级低于幂等集成、字体合规与分支收敛。

## 完成门禁

```powershell
flutter analyze
flutter test
powershell -ExecutionPolicy Bypass -File tools\package_release.ps1 -WindowsOnly
```

验收还需要：

- 幂等 401 重放测试证明 key 复用。
- dark/light golden 通过并人工看过字体 fallback。
- 字体来源与许可文件完整。
- 与 `feat/backend-hardening` 合并后运行 Rust、contract、smoke 与 Windows 包验证。
