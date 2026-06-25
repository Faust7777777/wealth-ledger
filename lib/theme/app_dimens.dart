// Wealth Ledger — P0 spacing / radius / stroke / elevation / layout tokens.
// 来源真相: project-context/DESIGN_V1.md §9（断点已按三栏数学修正：1360 / 960 / 600）。
// 深色主题以「表面色 + 细线」表达层级，阴影仅用于浮层。
// 状态: 暂存稿；脚手架就绪后移入 app/lib/theme 并经 `flutter analyze` 验证。
import 'package:flutter/painting.dart';

abstract final class AppSpacing { // 4pt 基
  static const double xxs = 2, xs = 4, sm = 8, md = 12, base = 16,
      lg = 20, xl = 24, xxl = 32, xxxl = 40, huge = 48, giant = 64;
}

abstract final class AppRadius {
  static const double sm = 8, md = 12, lg = 16, xl = 20, pill = 999;
}

abstract final class AppStroke {
  static const double hairline = 1, focus = 2;
}

abstract final class AppElevation {
  /// 卡片靠 surface + hairline 表达，无阴影
  static const List<BoxShadow> card = <BoxShadow>[];

  /// 浮层（菜单/Sheet/覆盖层）
  static const List<BoxShadow> overlay = <BoxShadow>[
    BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

abstract final class AppLayout {
  static const double railWidth = 256;      // Windows 左栏
  static const double railCollapsed = 72;   // 图标栏（窄窗）
  static const double inspectorWidth = 384; // Windows 右栏
  static const double contentMax = 720;     // 中栏内容最大宽
  static const double contentMin = 560;     // 中栏可接受最小宽
  static const double gutterDesktop = 24;
  static const double gutterMobile = 16;

  // 断点（三栏数学 256 + 24 + 560..720 + 24 + 384 ≈ 1248..1408 → 取 1360）
  static const double bpCompact = 600;   // <600 手机：底栏 + FAB
  static const double bpRailIcon = 960;  // <960：Rail 收为图标栏
  static const double bpExpanded = 1360; // >=1360：完整三栏；600–1359：栏+主栏，右栏 slide-over
}
