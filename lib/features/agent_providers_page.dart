// Wealth Ledger — 模型连接。provider 列表完全来自服务端，前端不内置厂商清单，
// 也不做任何自动切换：某个模型不可用时只提示重新连接。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// 轮询间隔：设备码授权要等用户在浏览器里点确认，2 秒足够跟手。
const Duration kAgentOAuthPollInterval = Duration(seconds: 2);

String agentProviderStatusText(AgentProviderConnectionStatus status) =>
    switch (status) {
      AgentProviderConnectionStatus.connected => '已连接',
      AgentProviderConnectionStatus.connecting => '连接中',
      AgentProviderConnectionStatus.disconnected => '未连接',
    };

/// 授权失败的用户可见说明。上游错误原文一律不显示。
String agentOAuthFailureText(AgentProviderOAuthStatus status) =>
    switch (status) {
      AgentProviderOAuthStatus.cancelled => '授权已取消',
      _ => '授权未完成，请重试',
    };

/// 倒计时文案；已过期返回 null，由调用方切成过期态。
String? agentOAuthCountdown(String? expiresAt, DateTime now) {
  if (expiresAt == null) return null;
  final deadline = DateTime.tryParse(expiresAt);
  if (deadline == null) return null;
  final left = deadline.difference(now);
  if (left.isNegative) return null;
  final minutes = left.inMinutes;
  final seconds = left.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')} 后失效';
}

class AgentProvidersPage extends ConsumerWidget {
  const AgentProvidersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(agentProvidersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('模型连接')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败，请重试。', style: AppType.body),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => ref.invalidate(agentProvidersProvider),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (providers) => providers.isEmpty
            ? Center(child: Text('还没有可连接的模型', style: AppType.caption))
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.base),
                children: [
                  for (final p in providers) AgentProviderRow(provider: p),
                ],
              ),
      ),
    );
  }
}

/// 单个 provider 一行：名称 + 连接状态 + 一个动作。失败停在这一行并可重试。
class AgentProviderRow extends ConsumerStatefulWidget {
  const AgentProviderRow({super.key, required this.provider});
  final AgentProviderVm provider;

  @override
  ConsumerState<AgentProviderRow> createState() => _AgentProviderRowState();
}

class _AgentProviderRowState extends ConsumerState<AgentProviderRow> {
  bool _busy = false;
  String? _error;

  Future<void> _refresh() async {
    ref.invalidate(agentProvidersProvider);
    ref.invalidate(agentModelsProvider);
    ref.invalidate(agentStatusProvider);
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    AgentProviderOAuthAttemptVm attempt;
    try {
      attempt = await ref
          .read(agentRepositoryProvider)
          .startProviderOAuth(widget.provider.id);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '连接未成功，请重试';
          _busy = false;
        });
      }
      return;
    }
    if (!mounted) return;
    // 授权面板自己显示进度，行上的转圈到此为止。
    setState(() => _busy = false);
    final result = await showAgentOAuthSheet(context, attempt: attempt);
    if (!mounted) return;
    if (result != null && result != AgentProviderOAuthStatus.connected) {
      setState(() => _error = agentOAuthFailureText(result));
    }
    await _refresh();
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text('断开后需要重新授权才能继续使用 ${widget.provider.displayName}。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('断开连接'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(agentRepositoryProvider)
          .disconnectProvider(widget.provider.id);
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = '断开未成功，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connecting =
        widget.provider.connectionStatus ==
        AgentProviderConnectionStatus.connecting;
    final supportsOAuth = widget.provider.authMethods.contains(
      AgentProviderAuthMethod.oauth,
    );
    final connected =
        widget.provider.connectionStatus ==
        AgentProviderConnectionStatus.connected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.provider.displayName,
                      style: AppType.bodyStrong,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      agentProviderStatusText(widget.provider.connectionStatus),
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (_busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (connected)
                TextButton(onPressed: _disconnect, child: const Text('断开连接'))
              else if (connecting)
                TextButton(onPressed: _refresh, child: const Text('刷新'))
              else if (supportsOAuth)
                FilledButton(
                  onPressed: _connect,
                  child: Text(_error == null ? '连接' : '重试'),
                )
              else
                Text('暂不支持', style: AppType.caption),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                _error!,
                style: AppType.caption.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<AgentProviderOAuthStatus?> showAgentOAuthSheet(
  BuildContext context, {
  required AgentProviderOAuthAttemptVm attempt,
}) => showModalBottomSheet<AgentProviderOAuthStatus>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => AgentProviderOAuthSheet(attempt: attempt),
);

/// 设备码授权面板：打开/复制授权页、复制用户码、倒计时、取消。
/// 只在可见时轮询；连接成功自行关闭并把结果回传给行。
class AgentProviderOAuthSheet extends ConsumerStatefulWidget {
  const AgentProviderOAuthSheet({super.key, required this.attempt});
  final AgentProviderOAuthAttemptVm attempt;

  @override
  ConsumerState<AgentProviderOAuthSheet> createState() =>
      _AgentProviderOAuthSheetState();
}

class _AgentProviderOAuthSheetState
    extends ConsumerState<AgentProviderOAuthSheet> {
  late AgentProviderOAuthAttemptVm _attempt;
  Timer? _timer;
  bool _expired = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _attempt = widget.attempt;
    _timer = Timer.periodic(kAgentOAuthPollInterval, (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (!mounted) return;
    // 先看本地过期：过期后不再打扰服务端。
    if (agentOAuthCountdown(_attempt.expiresAt, DateTime.now()) == null &&
        _attempt.expiresAt != null) {
      _timer?.cancel();
      if (mounted) setState(() => _expired = true);
      return;
    }
    try {
      final next = await ref
          .read(agentRepositoryProvider)
          .getProviderOAuthAttempt(_attempt.attemptId);
      if (!mounted) return;
      setState(() => _attempt = next);
      switch (next.status) {
        case AgentProviderOAuthStatus.pending:
          return;
        case AgentProviderOAuthStatus.connected:
        case AgentProviderOAuthStatus.failed:
        case AgentProviderOAuthStatus.cancelled:
          _timer?.cancel();
          Navigator.of(context).pop(next.status);
      }
    } catch (_) {
      // 轮询失败不打断授权：用户可能马上就在浏览器里点完了。
    }
  }

  Future<void> _copy(String value, String done) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) setState(() => _notice = done);
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) setState(() => _notice = '打不开浏览器，请复制链接');
    }
  }

  @override
  Widget build(BuildContext context) {
    final countdown = agentOAuthCountdown(_attempt.expiresAt, DateTime.now());
    final code = _attempt.userCode;
    final uri = _attempt.verificationUri;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.base,
          0,
          AppSpacing.base,
          AppSpacing.base,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('在浏览器里完成授权', style: AppType.bodyStrong),
            const SizedBox(height: AppSpacing.sm),
            if (code != null) ...[
              Text('授权码', style: AppType.caption),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(code, style: AppType.h2, maxLines: 1),
                  ),
                  TextButton(
                    onPressed: () => _copy(code, '授权码已复制'),
                    child: const Text('复制'),
                  ),
                ],
              ),
            ],
            if (uri != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(uri, style: AppType.caption, maxLines: 2),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  FilledButton(
                    onPressed: _expired ? null : () => _open(uri),
                    child: const Text('打开授权页'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: () => _copy(uri, '链接已复制'),
                    child: const Text('复制链接'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text(
              _expired ? '授权已过期，请重新发起' : (countdown ?? '等待授权'),
              style: AppType.caption,
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(_notice!, style: AppType.caption),
              ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).pop(_expired ? AgentProviderOAuthStatus.failed : null),
                child: Text(_expired ? '关闭' : '取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话选中的模型是否已经不在可用列表里。空选择不算异常（服务端有默认模型）。
bool agentSelectedModelMissing(
  String? selectedModelId,
  List<AgentModelVm> models,
) {
  if (selectedModelId == null || selectedModelId.isEmpty) return false;
  return !models.any((m) => m.id == selectedModelId);
}

/// 只有模型列表成功返回后才判定不可用；加载和请求失败不冒充模型缺失。
bool agentSelectedModelUnavailable(
  String? selectedModelId,
  AsyncValue<List<AgentModelVm>> models,
) {
  final data = models.asData;
  return data != null && agentSelectedModelMissing(selectedModelId, data.value);
}

/// 选中的模型不可用时的提示条。绝不自动切换到别的模型。
class AgentModelUnavailableNotice extends StatelessWidget {
  const AgentModelUnavailableNotice({super.key, required this.onReconnect});
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.base,
      vertical: AppSpacing.xs,
    ),
    child: Row(
      children: [
        Expanded(child: Text('模型当前不可用', style: AppType.caption)),
        TextButton(onPressed: onReconnect, child: const Text('重新连接')),
      ],
    ),
  );
}
