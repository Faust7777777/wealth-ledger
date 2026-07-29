// Wealth Ledger — Agent 对话渲染层，基于 flutter_chat_ui（Apache-2.0）。
// 这里只做渲染与控制器桥接：SSE 合并、游标重放、会话切换仍在 agentChatProvider，
// 包内不持有第二份会话状态。
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../data/providers.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'agent_chat_adapter.dart';
import 'agent_controller.dart';

/// 用户气泡的最大宽度：窄屏跟随内容，宽屏不至于拉成整行。
const double kAgentUserBubbleMaxWidth = 420;

/// 对话流。附件预览由外部注入，避免本文件反向依赖面板实现。
class AgentTranscript extends ConsumerStatefulWidget {
  const AgentTranscript({
    super.key,
    required this.chat,
    required this.attachmentBuilder,
  });

  final AgentChatState chat;
  final Widget Function(BuildContext context, String attachmentId)
  attachmentBuilder;

  @override
  ConsumerState<AgentTranscript> createState() => _AgentTranscriptState();
}

class _AgentTranscriptState extends ConsumerState<AgentTranscript> {
  late final InMemoryChatController _controller;

  @override
  void initState() {
    super.initState();
    _controller = InMemoryChatController(
      messages: agentMessagesToChatMessages(widget.chat.messages),
    );
  }

  @override
  void didUpdateWidget(covariant AgentTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(agentMessagesToChatMessages(widget.chat.messages));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 与领域状态对账：ID 序列不变时逐条更新，避免整表重建打断滚动与动画；
  /// 序列变化（新消息、切会话、重放补齐）才整体设置。ID 由适配层保持稳定，
  /// 因此快照 + 重放不会产生重复行。
  void _sync(List<Message> next) {
    final current = _controller.messages;
    if (current.length == next.length) {
      var sameIds = true;
      for (var i = 0; i < next.length; i++) {
        if (current[i].id != next[i].id) {
          sameIds = false;
          break;
        }
      }
      if (sameIds) {
        for (var i = 0; i < next.length; i++) {
          if (current[i] != next[i]) {
            _controller.updateMessage(current[i], next[i]);
          }
        }
        return;
      }
    }
    _controller.setMessages(next);
  }

  @override
  Widget build(BuildContext context) {
    final hasPending =
        (ref.watch(aiPendingProvider).asData?.value ?? const []).isNotEmpty;
    final activity = widget.chat.activity;
    return Chat(
      currentUserId: kAgentChatUserId,
      resolveUser: (id) async => User(id: id),
      chatController: _controller,
      theme: ChatTheme.fromThemeData(Theme.of(context)),
      builders: Builders(
        // composer 由面板自己提供（附件草稿、发送/取消、安全区与键盘避让）。
        composerBuilder: (_) => const SizedBox.shrink(),
        emptyChatListBuilder: (_) =>
            Center(child: Text('还没有对话', style: AppType.caption)),
        textMessageBuilder:
            (context, message, index, {required isSentByMe, groupStatus}) =>
                _AgentMessageContent(
                  messageId: message.id,
                  text: message.text,
                  attachmentIds: agentChatAttachmentIds(message),
                  isAssistant: !isSentByMe,
                  markdown: agentChatIsMarkdown(message),
                  attachmentBuilder: widget.attachmentBuilder,
                ),
        textStreamMessageBuilder:
            (context, message, index, {required isSentByMe, groupStatus}) =>
                _StreamingMessage(
                  messageId: message.id,
                  attachmentIds: agentChatAttachmentIds(message),
                  attachmentBuilder: widget.attachmentBuilder,
                ),
        chatAnimatedListBuilder: (context, itemBuilder) => ChatAnimatedList(
          itemBuilder: itemBuilder,
          // 底部安全区与键盘避让由外层 composer 负责，这里不重复留白。
          handleSafeArea: false,
          bottomPadding: 0,
          bottomSliver: SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.base,
                0,
                AppSpacing.base,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (activity != null) AgentActivityRow(label: activity),
                  if (hasPending)
                    TextButton(
                      onPressed: () => context.push('/ai-review'),
                      child: const Text('前往审核'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 低强调的工具活动行：一行文字 + 转圈，完成后由控制器清空，不留常驻卡片。
/// 只显示已映射的中文说明，不出现工具标识或参数。
class AgentActivityRow extends StatelessWidget {
  const AgentActivityRow({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: scheme.outline,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              label,
              style: AppType.caption.copyWith(color: scheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式回复：正文直接取自领域状态，增量到达时只重建这一条，
/// 不整表重建，也不会把整段回答塞进一个不断重建的巨型 Text。
class _StreamingMessage extends ConsumerWidget {
  const _StreamingMessage({
    required this.messageId,
    required this.attachmentIds,
    required this.attachmentBuilder,
  });

  final String messageId;
  final List<String> attachmentIds;
  final Widget Function(BuildContext context, String attachmentId)
  attachmentBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(
      agentChatProvider.select(
        (s) => s.messages
            .where((m) => m.id == messageId)
            .map((m) => m.text)
            .firstOrNull,
      ),
    );
    return _AgentMessageContent(
      messageId: messageId,
      text: text ?? '',
      attachmentIds: attachmentIds,
      isAssistant: true,
      markdown: true,
      placeholder: '排队中…',
      attachmentBuilder: attachmentBuilder,
    );
  }
}

/// 单条消息的正文。助手是无填充的整宽阅读区，用户是右侧紧凑气泡。
class _AgentMessageContent extends StatelessWidget {
  const _AgentMessageContent({
    required this.messageId,
    required this.text,
    required this.attachmentIds,
    required this.isAssistant,
    required this.markdown,
    required this.attachmentBuilder,
    this.placeholder,
  });

  final String messageId;
  final String text;
  final List<String> attachmentIds;
  final bool isAssistant;
  final bool markdown;
  final String? placeholder;
  final Widget Function(BuildContext context, String attachmentId)
  attachmentBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (attachmentIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final id in attachmentIds) attachmentBuilder(context, id),
              ],
            ),
          ),
        if (text.isNotEmpty)
          markdown
              ? GptMarkdown(text, style: AppType.body)
              : Text(text, style: AppType.body)
        else if (placeholder != null)
          Text(placeholder!, style: AppType.caption),
      ],
    );

    if (isAssistant) {
      // 整宽、无底色：长回答按段落阅读，而不是一整块着色气泡。
      return Container(
        key: ValueKey('agent_message_$messageId'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: body,
      );
    }
    return Container(
      key: ValueKey('agent_message_$messageId'),
      constraints: const BoxConstraints(maxWidth: kAgentUserBubbleMaxWidth),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: body,
    );
  }
}
