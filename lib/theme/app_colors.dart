// Wealth Ledger — P0 color tokens.
// 来源真相: project-context/DESIGN_V1.md §7（暖石墨深色默认 + 暖纸浅色）。
// 法则: 正常态不上色，仅偏差上色。每个状态须 色+图标+文案 三重编码。
// 状态: 暂存稿；脚手架就绪后移入 app/lib/theme 并经 `flutter analyze` + WCAG 核验。
import 'package:flutter/painting.dart';

/// 暖石墨 · 深色（默认主题）
abstract final class AppColors {
  // —— 背景与表面（暖石墨阶梯）——
  static const bgBase         = Color(0xFF1A1815); // 应用底
  static const bgInset        = Color(0xFF141210); // 凹槽/图表底
  static const surface1       = Color(0xFF211F1B); // 卡片
  static const surface2       = Color(0xFF272420); // 抬升/浮层
  static const surface3       = Color(0xFF2E2A25); // 菜单/Sheet 顶
  static const hairline       = Color(0xFF322E29); // 细分隔线
  static const hairlineStrong = Color(0xFF423C35);

  // —— 文本（暖灰阶）——
  static const textPrimary    = Color(0xFFF2EDE4);
  static const textSecondary  = Color(0xFFB8B0A4);
  static const textTertiary   = Color(0xFF857D72);
  static const textDisabled   = Color(0xFF5A544C);

  // —— 品牌 / 主动作 / AI 提示（香槟金，克制）——
  static const brand          = Color(0xFFCBB079);
  static const brandHover     = Color(0xFFD9C28E);
  static const brandPressed   = Color(0xFFB89A63);
  static const onBrand        = Color(0xFF1A1815); // 金底上的深色字

  // —— 语义状态（低饱和 calm；正常态不用色）——
  static const neutralDot     = Color(0xFF7E8A80); // fresh / synced / 正常
  static const positive       = Color(0xFF7FA88B); // 涨（暖鼠尾草绿）
  static const positiveText   = Color(0xFF97C0A3); // 小字号用
  static const negative       = Color(0xFFC08267); // 跌 / 负债（陶土）
  static const negativeText   = Color(0xFFD29A82);
  static const warning        = Color(0xFFD69A4E); // 过期 / 离线缓存（琥珀）
  static const warningText    = Color(0xFFE3B06A);
  static const error          = Color(0xFFCC6F5A); // 刷新失败 / 硬错误（陶红）
  static const errorText      = Color(0xFFDD8A77);
  static const conflict       = Color(0xFFB07BA0); // 冲突（梅紫，需人决策）
  static const conflictText   = Color(0xFFC695B9);
  static const info           = Color(0xFF6E8DA8); // 同步中 / 信息（石板蓝）
  static const infoText       = Color(0xFF8FAAC2);
  static const inTransit      = Color(0xFF8E86B3); // 在途资金（鸢尾紫）
  static const inTransitText  = Color(0xFFA9A2CC);

  // —— 其它 ——
  static const focusRing      = brand;
  static const scrim          = Color(0x80000000); // 50% 黑
}

/// 暖纸 · 浅色（备选；语义名与深色一致；P0 校验对比度）
abstract final class AppColorsLight {
  static const bgBase         = Color(0xFFF4F0E8);
  static const bgInset        = Color(0xFFEBE6DC);
  static const surface1       = Color(0xFFFBF8F2);
  static const surface2       = Color(0xFFFFFFFF);
  static const surface3       = Color(0xFFFFFFFF);
  static const hairline       = Color(0xFFE3DCCF);
  static const hairlineStrong = Color(0xFFD2C8B6);

  static const textPrimary    = Color(0xFF221F1A);
  static const textSecondary  = Color(0xFF5A5349);
  static const textTertiary   = Color(0xFF8A8174);
  static const textDisabled   = Color(0xFFB3AB9D);

  static const brand          = Color(0xFF9A7B3C); // 浅底需更深以保对比
  static const brandHover     = Color(0xFF866A31);
  static const brandPressed   = Color(0xFF735A29);
  static const onBrand        = Color(0xFFFFFFFF);

  static const neutralDot     = Color(0xFF6E7A70);
  static const positive       = Color(0xFF3F7A57);
  static const positiveText   = Color(0xFF2F5E42);
  static const negative       = Color(0xFFB0573B);
  static const negativeText   = Color(0xFF8C4128);
  static const warning        = Color(0xFFB07A2A);
  static const warningText    = Color(0xFF8A5E1F);
  static const error          = Color(0xFFB0432E);
  static const errorText      = Color(0xFF8C3322);
  static const conflict       = Color(0xFF8A5680);
  static const conflictText   = Color(0xFF6E4266);
  static const info           = Color(0xFF3E6488);
  static const infoText       = Color(0xFF2E4C6A);
  static const inTransit      = Color(0xFF6A6298);
  static const inTransitText  = Color(0xFF514A78);

  static const focusRing      = brand;
  static const scrim          = Color(0x40000000);
}
