// Wealth Ledger — shared presentation widgets (theme-aware).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_dimens.dart';

/// 入场动画：挂载时淡入 + 轻微上移。用于首屏关键块，克制而非炫技。
/// 只动透明度/位移，不触碰金额数值；尊重系统「减弱动态效果」设置。
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 380),
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _anim = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 无障碍：减弱动态效果时直接呈现，不做位移/淡入。
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) => Opacity(
        opacity: _anim.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - _anim.value) * 8),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// 骨架微光：低对比往返呼吸，占位加载态。比裸转圈更能预示内容结构。
/// 尊重减弱动态效果（静态占位块）。
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  // 在 initState 创建（非 late），避免 dispose 时惰性初始化触碰已失活的元素树。
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 减弱动态效果时不重复动画（也避免测试因无限动画无法 settle）。
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return Opacity(opacity: 0.5, child: widget.child);
    }
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.35,
        end: 0.7,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}

/// 单个骨架块（圆角占位条）。
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadius.sm,
  });
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).dividerColor,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 列表加载骨架：N 行「标题条 + 右侧金额条」，替代裸 CircularProgressIndicator。
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.rows = 5});
  final int rows;

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.base),
        itemCount: rows,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.lg),
        itemBuilder: (context, i) => Row(
          children: [
            const SkeletonBar(width: 40, height: 40, radius: AppRadius.md),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBar(width: 140 - (i % 3) * 24),
                  const SizedBox(height: AppSpacing.sm),
                  const SkeletonBar(width: 88, height: 11),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            const SkeletonBar(width: 72, height: 16),
          ],
        ),
      ),
    );
  }
}

/// 按压反馈：按下时轻微缩放（tactile feedback），松开或取消回弹。
/// 给可点击的卡片/行/主动作加触感；尊重减弱动态效果。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: (_pressed && !reduceMotion) ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 行首徽标：品牌金 tint 圆角方块内放单字 monogram 或类型图标。
/// 给纯文字列表行加视觉锚点与节奏（持仓用符号首字母，账户用类型图标）。
class LeadingAvatar extends StatelessWidget {
  const LeadingAvatar.mono(this.mono, {super.key, this.size = 36})
    : icon = null;
  const LeadingAvatar.icon(this.icon, {super.key, this.size = 36})
    : mono = null;

  final String? mono;
  final IconData? icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brand = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: brand.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: mono != null
          ? Text(
              String.fromCharCodes(mono!.runes.take(1)).toUpperCase(),
              style: TextStyle(
                color: brand,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
              ),
            )
          : Icon(icon, size: size * 0.5, color: brand),
    );
  }
}

/// 金额切换动画：值变化时新值淡入上滑、旧值淡出。左对齐，等宽数字保持成列。
/// 不伪造中间数字（遵守「金额不过 double」），只在真实值之间过渡。
class AnimatedMoneyText extends StatelessWidget {
  const AnimatedMoneyText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Text(text, key: ValueKey<String>(text), style: style),
    );
  }
}

/// 宽屏内容限宽居中（桌面可读性；窄屏宽度 < maxWidth 时无副作用）。
class ContentMaxWidth extends StatelessWidget {
  const ContentMaxWidth({
    super.key,
    required this.child,
    this.maxWidth = AppLayout.contentMax,
  });
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// 空状态：图标或插画 + 一句话 + 可选动作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.illustration,
    this.action,
  });
  final String title;
  final String? message;
  final IconData? icon;

  /// 可选插画（优先于 icon）：用于首屏等重点空态，其余仍用简洁 icon。
  final Widget? illustration;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (illustration != null) ...[
              illustration!,
              const SizedBox(height: AppSpacing.lg),
            ] else if (icon != null) ...[
              Icon(icon, size: 40, color: t.colorScheme.outline),
              const SizedBox(height: AppSpacing.base),
            ],
            Text(
              title,
              style: t.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                style: t.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 区块标题 + 可选尾部动作。
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, AppSpacing.lg, 0, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 写入口统一提示：当前数据源无对应写能力时的原因文案。
const String kReadOnlyHint =
    '当前数据源只读：请以 local_server 可写模式启动（tools\\run_self_use_windows.ps1）';

/// 写入口 gating 包装：capability 为 false 时禁用 [child] 并在下方给出原因。
/// UI 只凭服务端 capabilities 决定可写性，不按数据源名称猜测。
class WriteGate extends StatelessWidget {
  const WriteGate({
    super.key,
    required this.enabled,
    required this.child,
    this.reason = kReadOnlyHint,
  });
  final bool enabled;
  final Widget child;
  final String reason;

  @override
  Widget build(BuildContext context) {
    if (enabled) return child;
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AbsorbPointer(child: Opacity(opacity: 0.45, child: child)),
        const SizedBox(height: AppSpacing.xs),
        Text(
          reason,
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.outline),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// 错误态（结构化错误展示；不静默吞错）。
/// 对两类高频错误给出可行动引导：401 → 去登录；本地服务连不上 → 启动指引。
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  bool get _isAuth => message.contains('401');
  bool get _isConnection =>
      message.contains('SocketException') ||
      message.contains('Connection refused') ||
      message.contains('ClientException');

  @override
  Widget build(BuildContext context) {
    final (icon, title, hint) = _isConnection
        ? (
            Icons.cloud_off_outlined,
            '无法连接本地服务',
            '请先启动本地服务（tools\\run_self_use_windows.ps1），或到设置检查 API 地址。',
          )
        : _isAuth
        ? (Icons.lock_outline, '需要登录', null)
        : (Icons.error_outline, '出错了', null);
    return EmptyState(
      icon: icon,
      title: title,
      message: hint == null ? message : '$hint\n\n$message',
      action: Wrap(
        spacing: AppSpacing.sm,
        alignment: WrapAlignment.center,
        children: [
          if (_isAuth)
            FilledButton(
              onPressed: () => GoRouter.of(context).push('/settings'),
              child: const Text('去登录'),
            ),
          if (onRetry != null)
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
