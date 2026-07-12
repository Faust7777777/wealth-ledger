// Wealth Ledger — P0 typography tokens.
// 来源真相: project-context/DESIGN_V1.md §8。
// 中文优先(Noto Sans SC) + Latin/数字(Inter)；货币统一开启 tabular figures 对齐成列。
// Hero 仅在 NetWorthHero 用 display（移动端降至 40）。
// 字体(均 OFL,见 assets/fonts/SOURCE.md): 正文=NotoSansSC 子集；标题/Hero=NotoSerifSC 子集。
//       family='Inter' 未打包，回退链首选 NotoSansSC，故全局以其渲染，tabular figures 生效。
import 'package:flutter/painting.dart';

abstract final class AppType {
  static const family = 'Inter';
  static const familyFallback = <String>[
    'NotoSansSC',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans SC',
    'sans-serif',
  ];

  /// 编辑感衬线：仅用于 Hero 大数字与各级标题（display/h1/h2），
  /// 与无衬线正文形成反差＝高端信号。缺字回退无衬线正文体（NotoSansSC）。
  static const serifFamily = 'NotoSerifSC';
  static const serifFallback = familyFallback;

  /// 货币/数字统一等宽数字
  static const tnum = <FontFeature>[FontFeature.tabularFigures()];

  // family + fallback 直接烘进每个样式：这些 AppType.* 会被组件子主题（AppBar/
  // ListTile/Chip/Input 等）直接引用，不走 ThemeData.textTheme 的字体应用；若不
  // 内置 family，list 行标题/顶栏标题等会脱离正文体、落到系统字体（与货币数字不一致）。
  static const display = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    fontSize: 52,
    height: 1.05,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    fontFeatures: tnum,
  ); // Hero 净值（衬线；移动端覆盖为 40）
  static const h1 = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    fontSize: 22,
    height: 1.30,
    fontWeight: FontWeight.w600,
  );
  static const h2 = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: serifFallback,
    fontSize: 18,
    height: 1.35,
    fontWeight: FontWeight.w600,
  );
  static const titleM = TextStyle(
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 16,
    height: 1.40,
    fontWeight: FontWeight.w500,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 14,
    height: 1.50,
    fontWeight: FontWeight.w400,
  );
  static const bodyStrong = TextStyle(
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 14,
    height: 1.50,
    fontWeight: FontWeight.w500,
  );
  static const caption = TextStyle(
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 12,
    height: 1.40,
    fontWeight: FontWeight.w400,
  );
  static const micro = TextStyle(
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 11,
    height: 1.30,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
  ); // pill / badge
  static const moneyRow = TextStyle(
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 14,
    height: 1.40,
    fontWeight: FontWeight.w500,
    fontFeatures: tnum,
  ); // 流水 / 账户金额
}
