# 2026-07-11 前端视觉与动效批次

分支 `feat/frontend-skeleton`，未 push（推送/合并归 Codex）。本轮把「token 好但落地是 stock M3 + 系统字体」的差距补上，并加了一层克制的动效。

## 已落地（提交栈，均 analyze 净 / test 绿 / Windows build 通过）

1. `8db6371` 动效地基：`AnimatedMoneyText`（净值在真实值间过渡，**不经 double、不伪造中间数字**）、全局淡入页面转场（`pageTransitionsTheme`）、`Reveal` 入场原语（尊重 reduce-motion）
2. `37e2e65` **组件子主题**：把 Card/输入/按钮/Chip/导航/ListTile/Dialog/Sheet/SnackBar/Tooltip 全接到 token——卡片 surface1+hairline 无阴影、灭掉 M3 色调抬升、主按钮香槟金、输入框 filled+品牌聚焦环。视觉跃升最大的一项
3. `ac8a506` `PressableScale` 按压缩放，用于概览可点行
4. `c1a609d` `Shimmer/SkeletonBar/ListSkeleton` 骨架屏替裸转圈（账户/投资/负债/快照）
5. `73aab68` **打包 MiSans 字体**，让 tabular figures 真正渲染（此前回退系统字体）
6. `77…`（accounts/liabilities 行错峰入场 + 按压）、account-detail 估值套用 money 动效

## 需要你/Codex 注意的两点

- **字体来源**：`assets/fonts/MiSans.ttf`（7.9MB）取自本机 WPS 字体缓存。MiSans 小米开源可商用，但建议换成**官方发行版**重新打包；Inter 官方 TTF 到位后可把 `AppType.family` 设回 Inter 首选（当前 Inter 未打包，回退链落到 MiSans）。
- **与 `feat/redesign` 分支可能冲突**：redesign 线也动过 `app_theme.dart`/字体/Hero。本轮子主题与字体若和 redesign 合并会撞 `app_theme.dart`；合并时以「子主题接 token」为准取并集。

## 仍可做（未做，留给你拍板）

- **桌面三栏布局**：`app_dimens.dart` 定义了 `inspectorWidth/railWidth` 但未用；宽屏仍是单列。收益大但改动大、易回归，需专门一轮。
- **下拉刷新**（RefreshIndicator）：主要利好 Android；桌面已有顶栏刷新。
- **OpenContainer**（FAB→记录 sheet 容器变形）：需引入 `animations` 包（本地 pub 缓存已有 2.1.2）。
- Inter 官方字体打包（见上）。
