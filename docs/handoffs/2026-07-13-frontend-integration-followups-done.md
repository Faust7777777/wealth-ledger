# 2026-07-13 前端集成待办回执

回应后端交接 `finwealth-backend/docs/handoffs/2026-07-13-frontend-integration-followups.md`。
分支 `feat/frontend-skeleton`，未推送。仅改 Flutter 客户端/测试/字体资产/前端文档。

## ✅ P0-1 Idempotency-Key（`cc0251a`）

`DevApiClient` 现在对所有非 auth 写入（POST/PATCH/PUT/DELETE）发送 `Idempotency-Key`。

- 每个逻辑写生成一次 128-bit key（`Random.secure()`，32 位小写 hex），在首次
  `_dispatch` 前生成、显式透传。
- 401 → refresh → 重放复用**同一个** key（不重新生成），服务端据此去重而非当新写。
- GET 与 `/v1/auth/*` 不带 key；每个新用户操作用新 key；key 不持久化、不记录。
- 4 个回归测试（`test/auth_client_test.dart`）：POST/PATCH 带 hex key、GET 不带、
  两次独立写 key 不同、**401 重放复用同一 key 且 auth refresh 不带**。

## ✅ P0-2 字体合规（`8cba3fc`）

原 `MiSans.ttf`（WPS 缓存、无许可来源）已移除，改用 OFL 字体并附许可与来源。

- 正文/UI：Google **Noto Sans SC**（SIL OFL 1.1）子集，从本机 `NotoSansSC-VF`
  定格 wght=400、裁 ASCII + CJK U+4E00-9FFF + 标点 + 货币/数学/箭头/几何符号，7.1MB。
- 标题/Hero：**Noto Serif SC**（OFL 1.1）子集（原已引入，本次补齐许可与来源）。
- 许可：`assets/fonts/licenses/{NotoSansSC,NotoSerifSC}-OFL.txt`（取自 google/fonts 官方
  OFL.txt）；来源与可复现 instancer+pyftsubset 命令：`assets/fonts/SOURCE.md`。
- **人工 fallback 检查**（交接门禁项）当场发现涨跌 `▲▼`、报价 `◐` 不在首版 CJK-only 子集、
  在静默靠系统字体兜底；已把 U+21xx/22xx/25xx 符号区补进子集，改为自带渲染。
- `AppType` 回退链 MiSans→NotoSansSC；`family='Inter'` 仍未打包→回退首选 NotoSansSC。

## 前端视觉线提交清单（补齐 2026-07-11 文档未覆盖部分）

- `ba239e7` 宽屏 256px 扩展侧栏（`>=bpExpanded`，用 railWidth token）
- `2f67ad2` 首屏空态品牌插画（Codex 生成，金线日出）
- `0d5d95b` 浅色 overview golden 预览用例
- `3b530f2` Noto Serif SC 标题/Hero 衬线层级
- `00e1f9a` 资产构成环形图（替代扁条，中心总资产 + 类·%·额 图例）
- `99c1fc8` nav icon theme 格式化收口
- `0fc6ba0`/`d6cb85a`/`ecaab1d` `LeadingAvatar` 原语 + 全列表行首徽标（概览/投资/
  账户/负债/账户详情：持仓用符号首字母 monogram，账户用类型图标，品牌金 tint）
- `bf2eff3` 投资空态第二枚品牌插画（金线同心弧+圆，与首屏日出成套）
- `b340535` 衬线字重反差（Hero display=700、各级标题=500；打包 NotoSerifSC-500/700
  两个 OFL 子集，替代原单一 600）
- 更早：子主题、动效原语（Reveal/PressableScale/AnimatedMoneyText/Shimmer）、
  骨架屏、capability gating、401 自动刷新，见 `2026-07-07`/`2026-07-11` 文档。

**字体资产现状（供合并核对）**：`assets/fonts/` = NotoSansSC-400（正文，7.1MB）、
NotoSerifSC-500 + NotoSerifSC-700（标题/Hero，各 ~320KB），均 OFL；`licenses/` 两份
OFL.txt + `SOURCE.md`。原 MiSans.ttf 与 NotoSerifSC-600.ttf 已移除。
`assets/illustrations/` = net-worth-empty-state.png + investment-empty-state.png（两枚
Codex 生成的金线徽记）。

## 预览自检工具

`test/preview_golden_test.dart`：加载真实 Noto Sans/Serif SC + MaterialIcons，把
overview(手机/桌面/空态)、form(深/浅)、light overview 渲成 PNG。默认在 `flutter test`
跳过（golden 跨机不稳，不做门禁）；`PREVIEW_GOLDENS=1 flutter test --update-goldens
test/preview_golden_test.dart` 重生成，PNG 已 gitignore。

## 未做（按交接不自行实现）

- P1 视觉线并集合并（`feat/frontend-skeleton` × `feat/redesign`，含 MoneyText/
  LeadingAvatar/StatusPill 吸收）——归 Codex 合并线。
- 产品决策：Android 可写数据源（Rust FFI vs 连认证 VPS）、桌面三栏 inspector、
  Android 下拉刷新、OpenContainer。

## 完成门禁

- `flutter analyze`：净。
- `flutter test`：48 通过（+6 预览跳过），含幂等 401 重放 key 复用测试。
- dark/light golden 已重生成并人工看过字体与符号 fallback。
- 字体来源与 OFL 许可文件完整。
- `tools\package_release.ps1 -WindowsOnly`：见本次验证输出（可写 Windows 自用包）。
- 与 `feat/backend-hardening` 合并后的 Rust/contract/smoke/Windows 包联合验证：归合并线。
