// Wealth Ledger — P0 token preview / visual-QA screen (dev only).
// 验证: 暖石墨主题、香槟金主动作、状态语义族(色+图标+文案)、字体阶梯、间距。
// 非业务屏；上线前移除或置于 dev 入口。
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class TokensPreview extends StatelessWidget {
  const TokensPreview({super.key, required this.isDark, required this.onToggleTheme});

  final bool isDark;
  final VoidCallback onToggleTheme;

  Color get _textPrimary => isDark ? AppColors.textPrimary : AppColorsLight.textPrimary;
  Color get _textSecondary => isDark ? AppColors.textSecondary : AppColorsLight.textSecondary;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('P0 设计 token 预览'),
        actions: [
          IconButton(
            tooltip: isDark ? '切换浅色' : '切换深色',
            onPressed: onToggleTheme,
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        children: [
          _hero(context),
          const SizedBox(height: AppSpacing.xxl),
          _section('状态系统 · 正常静默，偏差上色'),
          _stateWrap(),
          const SizedBox(height: AppSpacing.xxl),
          _section('表面与品牌'),
          _surfaces(),
          const SizedBox(height: AppSpacing.xxl),
          _section('字体阶梯'),
          _typeRamp(),
          const SizedBox(height: AppSpacing.xxl),
          _section('间距 · 4pt 基'),
          _spacing(),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.base),
        child: Text(t, style: AppType.h2.copyWith(color: _textPrimary)),
      );

  Widget _hero(BuildContext context) {
    final pos = isDark ? AppColors.positive : AppColorsLight.positive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('净资产 · CNY', style: AppType.caption.copyWith(color: _textSecondary)),
        const SizedBox(height: AppSpacing.sm),
        Text('≈ ¥245,678.90', style: AppType.display.copyWith(color: _textPrimary)),
        const SizedBox(height: AppSpacing.xs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_upward, size: 16, color: pos),
            Text(' ¥1,245.67  +0.51%  今日', style: AppType.body.copyWith(color: pos)),
          ],
        ),
      ],
    );
  }

  Widget _stateWrap() {
    final d = isDark;
    final specs = <(String, Color, String)>[
      ('实时', d ? AppColors.neutralDot : AppColorsLight.neutralDot, '●'),
      ('过期·缓存', d ? AppColors.warning : AppColorsLight.warning, '◐'),
      ('离线', d ? AppColors.warning : AppColorsLight.warning, '☁'),
      ('刷新失败', d ? AppColors.error : AppColorsLight.error, '⚠'),
      ('报价冲突', d ? AppColors.conflict : AppColorsLight.conflict, '⇄'),
      ('无法估值', d ? AppColors.textTertiary : AppColorsLight.textTertiary, '—'),
      ('已同步', d ? AppColors.neutralDot : AppColorsLight.neutralDot, '✓'),
      ('同步中', d ? AppColors.info : AppColorsLight.info, '⟳'),
      ('AI 待确认', d ? AppColors.brand : AppColorsLight.brand, '✦'),
      ('在途·非支出', d ? AppColors.inTransit : AppColorsLight.inTransit, '⇅'),
      ('负债', d ? AppColors.negative : AppColorsLight.negative, '−'),
    ];
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [for (final s in specs) _pill(s.$1, s.$2, s.$3)],
    );
  }

  Widget _pill(String label, Color c, String glyph) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: c.withValues(alpha: 0.5)),
        ),
        child: Text('$glyph  $label', style: AppType.micro.copyWith(color: c)),
      );

  Widget _surfaces() {
    final d = isDark;
    final items = <(String, Color)>[
      ('bgBase', d ? AppColors.bgBase : AppColorsLight.bgBase),
      ('surface1', d ? AppColors.surface1 : AppColorsLight.surface1),
      ('surface2', d ? AppColors.surface2 : AppColorsLight.surface2),
      ('surface3', d ? AppColors.surface3 : AppColorsLight.surface3),
      ('brand', d ? AppColors.brand : AppColorsLight.brand),
    ];
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.md,
      children: [for (final i in items) _swatch(i.$1, i.$2)],
    );
  }

  Widget _swatch(String name, Color c) {
    final border = isDark ? AppColors.hairlineStrong : AppColorsLight.hairlineStrong;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 48,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: border),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(name, style: AppType.micro.copyWith(color: _textSecondary)),
      ],
    );
  }

  Widget _typeRamp() {
    Widget row(String label, TextStyle s) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Text('$label — 净资产 ¥245,678.90',
              style: s.copyWith(color: _textPrimary)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('display', AppType.display),
        row('h1', AppType.h1),
        row('h2', AppType.h2),
        row('titleM', AppType.titleM),
        row('body', AppType.body),
        row('caption', AppType.caption),
        row('moneyRow', AppType.moneyRow),
      ],
    );
  }

  Widget _spacing() {
    final c = isDark ? AppColors.brand : AppColorsLight.brand;
    final vals = <(String, double)>[
      ('xs', AppSpacing.xs),
      ('sm', AppSpacing.sm),
      ('md', AppSpacing.md),
      ('base', AppSpacing.base),
      ('lg', AppSpacing.lg),
      ('xl', AppSpacing.xl),
      ('xxl', AppSpacing.xxl),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final v in vals)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Text(v.$1, style: AppType.micro.copyWith(color: _textSecondary)),
                ),
                Container(width: v.$2, height: 12, color: c),
              ],
            ),
          ),
      ],
    );
  }
}
