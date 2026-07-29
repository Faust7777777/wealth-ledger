// Wealth Ledger — Agent 通知：面板上只有一个低强调入口 + 未读数，
// 列表放进有高度上限的 sheet；打开一条即幂等标记已读并按 action 跳转。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

String agentAutomationKindLabel(AgentAutomationKind kind) => switch (kind) {
  AgentAutomationKind.quoteRefresh => '结构化报价刷新',
  AgentAutomationKind.subscriptionDueScan => '订阅到期扫描',
  AgentAutomationKind.dcaDueCheck => '定投到期检查',
  AgentAutomationKind.financialSummary => '周期财务总结',
};

/// 面板上的低强调通知入口；无未读时不显示数字。
class AgentNotificationsEntry extends ConsumerWidget {
  const AgentNotificationsEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications =
        ref.watch(agentNotificationsProvider).asData?.value ?? const [];
    if (notifications.isEmpty) return const SizedBox.shrink();
    final unread = ref.watch(agentUnreadNotificationCountProvider);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => showAgentNotificationSheet(context),
        icon: const Icon(Icons.notifications_none, size: 18),
        label: Text(unread > 0 ? '通知 $unread' : '通知'),
      ),
    );
  }
}

Future<void> showAgentNotificationSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const AgentNotificationSheet(),
    );

class AgentNotificationSheet extends ConsumerStatefulWidget {
  const AgentNotificationSheet({super.key});

  @override
  ConsumerState<AgentNotificationSheet> createState() =>
      _AgentNotificationSheetState();
}

class _AgentNotificationSheetState
    extends ConsumerState<AgentNotificationSheet> {
  final _busy = <Id>{};

  /// 打开一条：先幂等标记已读，再按 action 跳到对应位置。
  Future<void> _open(AgentNotificationVm notification) async {
    if (!_busy.add(notification.id)) return;
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    try {
      if (notification.isUnread) {
        await ref
            .read(agentRepositoryProvider)
            .markNotificationRead(notification.id);
        ref.invalidate(agentNotificationsProvider);
      }
    } catch (_) {
      // 标记失败不阻断跳转；下次打开会再试一次。
    } finally {
      _busy.remove(notification.id);
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    switch (notification.action) {
      case AgentNotificationAction.review:
        navigator.pop();
        router.push('/ai-review');
      case AgentNotificationAction.dca:
        navigator.pop();
        router.push('/investment');
      case AgentNotificationAction.quotes:
        navigator.pop();
        ref.read(agentOpenQuoteSuggestionsProvider.notifier).request();
      case AgentNotificationAction.agent:
        // 已经在主会话里，收起面板上的这层 sheet 即可。
        navigator.pop();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifications =
        ref.watch(agentNotificationsProvider).asData?.value ?? const [];
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.7).clamp(
      200.0,
      560.0,
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.base,
                vertical: AppSpacing.xs,
              ),
              child: Text('通知', style: AppType.bodyStrong),
            ),
            if (notifications.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.base),
                child: Text('暂无通知'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: AppSpacing.base),
                  itemCount: notifications.length,
                  itemBuilder: (context, index) {
                    final n = notifications[index];
                    return ListTile(
                      leading: Icon(
                        n.isUnread ? Icons.circle : Icons.check_circle_outline,
                        size: n.isUnread ? 10 : 18,
                        color: n.isUnread
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).textTheme.bodySmall?.color,
                      ),
                      title: Text(
                        n.title,
                        style: n.isUnread ? AppType.bodyStrong : AppType.body,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (n.body.isNotEmpty)
                            Text(n.body, style: AppType.caption),
                          Text(
                            formatLocalDateTime(n.createdAt),
                            style: AppType.caption,
                          ),
                        ],
                      ),
                      onTap: _busy.contains(n.id) ? null : () => _open(n),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 通知里的「去看报价」请求：面板监听它并打开报价建议 sheet。
class AgentOpenQuoteSuggestions extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state = state + 1;
}

final agentOpenQuoteSuggestionsProvider =
    NotifierProvider<AgentOpenQuoteSuggestions, int>(
      AgentOpenQuoteSuggestions.new,
    );

/// 本地时区到分钟（与报价卡片同一份实现来源）。
String formatLocalDateTime(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
