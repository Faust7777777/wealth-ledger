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

/// 空状态：图标 + 一句话 + 可选动作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.action,
  });
  final String title;
  final String? message;
  final IconData? icon;
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
            if (icon != null) ...[
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
