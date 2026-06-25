// Wealth Ledger — P0 typography tokens.
// 来源真相: project-context/DESIGN_V1.md §8。
// 中文优先(MiSans) + Latin/数字(Inter)；货币统一开启 tabular figures 以对齐成列。
// Hero 仅在 NetWorthHero 用 display（移动端降至 40）。
// 状态: 暂存稿；字体 .ttf 待打包，未打包前回退系统字体（不影响 analyze）。
import 'package:flutter/painting.dart';

abstract final class AppType {
  static const family = 'Inter';
  static const familyFallback = <String>[
    'MiSans', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans SC', 'sans-serif',
  ];

  /// 货币/数字统一等宽数字
  static const tnum = <FontFeature>[FontFeature.tabularFigures()];

  static const display = TextStyle(
    fontSize: 52, height: 1.05, fontWeight: FontWeight.w600,
    letterSpacing: -0.5, fontFeatures: tnum,
  ); // Hero（移动端覆盖为 40）
  static const h1         = TextStyle(fontSize: 22, height: 1.30, fontWeight: FontWeight.w600);
  static const h2         = TextStyle(fontSize: 18, height: 1.35, fontWeight: FontWeight.w600);
  static const titleM     = TextStyle(fontSize: 16, height: 1.40, fontWeight: FontWeight.w500);
  static const body       = TextStyle(fontSize: 14, height: 1.50, fontWeight: FontWeight.w400);
  static const bodyStrong = TextStyle(fontSize: 14, height: 1.50, fontWeight: FontWeight.w500);
  static const caption    = TextStyle(fontSize: 12, height: 1.40, fontWeight: FontWeight.w400);
  static const micro      = TextStyle(
    fontSize: 11, height: 1.30, fontWeight: FontWeight.w500, letterSpacing: 0.3,
  ); // pill / badge
  static const moneyRow   = TextStyle(
    fontSize: 14, height: 1.40, fontWeight: FontWeight.w500, fontFeatures: tnum,
  ); // 流水 / 账户金额
}
