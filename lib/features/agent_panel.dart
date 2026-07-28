// Wealth Ledger — Agent 面板（Windows 右栏 / Android 全屏共用同一份实现）。
// 只经 /v1/agent/**；账务产出落到既有 AI 待审核列表，这里只提供低强调入口。
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/api_mock_repositories.dart' show ApiValidationException;
import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'agent_controller.dart';

/// 附件白名单（与服务端一致）；HEIC 不在范围内。
const Map<String, String> kAgentImageMimeTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
};

String? agentImageMimeType(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0) return null;
  return kAgentImageMimeTypes[fileName.substring(dot + 1).toLowerCase()];
}

/// 用户选中的一张待上传图片。
typedef AgentPickedImage = ({String fileName, Uint8List bytes});

/// 选图入口的可注入接缝：默认弹系统选择器；测试与预览覆盖它，
/// 因此不需要在测试里驱动真实文件对话框。
typedef AgentImagePicker = Future<AgentPickedImage?> Function();

Future<AgentPickedImage?> _pickImageFromSystem() async {
  const typeGroup = XTypeGroup(
    label: 'images',
    extensions: ['png', 'jpg', 'jpeg', 'webp'],
    mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
  );
  final file = await openFile(acceptedTypeGroups: const [typeGroup]);
  if (file == null) return null;
  return (fileName: file.name, bytes: await file.readAsBytes());
}

final agentImagePickerProvider = Provider<AgentImagePicker>(
  (ref) => _pickImageFromSystem,
);

/// 附件上传失败的用户可见短提示（不外露内部标识与实现细节）。
String agentAttachmentErrorMessage(String? code) => switch (code) {
  'invalid_attachment_size' => '图片超过 15 MiB，请压缩后再试。',
  'invalid_attachment_type' => '只支持 PNG、JPEG、WEBP 图片。',
  _ => '图片未通过校验，请重新选择。',
};

class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({super.key, this.onClose});

  /// 桌面右栏的关闭动作；移动端全屏页由返回键处理，传 null。
  final VoidCallback? onClose;

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  final _draft = TextEditingController();
  final _pending = <({AgentAttachmentVm meta, Uint8List bytes})>[];
  bool _uploading = false;
  String? _composerError;
  bool _opened = false;

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  /// 首次可用时进入主会话；会话列表变化不重复打开。
  void _openPrimaryOnce(List<AgentConversationVm> conversations) {
    if (_opened || conversations.isEmpty) return;
    _opened = true;
    final primary = conversations.firstWhere(
      (c) => c.isPrimary,
      orElse: () => conversations.first,
    );
    Future.microtask(
      () => ref.read(agentChatProvider.notifier).open(primary.id),
    );
  }

  Future<void> _pickAttachment() async {
    if (_uploading) return;
    setState(() {
      _uploading = true;
      _composerError = null;
    });
    try {
      final picked = await ref.read(agentImagePickerProvider)();
      if (picked == null) return;
      final mime = agentImageMimeType(picked.fileName);
      if (mime == null) {
        setState(() => _composerError = '只支持 PNG、JPEG、WEBP 图片。');
        return;
      }
      final meta = await ref
          .read(agentRepositoryProvider)
          .uploadAttachment(
            fileName: picked.fileName,
            mimeType: mime,
            bytes: picked.bytes,
          );
      if (!mounted) return;
      setState(() => _pending.add((meta: meta, bytes: picked.bytes)));
    } on ApiValidationException catch (e) {
      // 400/413 保留已选图片列表，允许直接重试。
      if (mounted) {
        setState(() => _composerError = agentAttachmentErrorMessage(e.code));
      }
    } catch (_) {
      if (mounted) setState(() => _composerError = '图片上传失败，请重试。');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _send() async {
    final chat = ref.read(agentChatProvider);
    if (chat.sending) return; // 同一次点击只产生一个请求
    final text = _draft.text;
    if (text.trim().isEmpty) return;
    final attachmentIds = [for (final a in _pending) a.meta.id];
    final failure = await ref
        .read(agentChatProvider.notifier)
        .send(text: text, attachmentIds: attachmentIds);
    if (!mounted) return;
    if (failure != null) {
      // 草稿与附件引用保留，可直接重试。
      setState(() => _composerError = failure);
      return;
    }
    setState(() {
      _draft.clear();
      _pending.clear();
      _composerError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(agentStatusProvider);
    final conversationsAsync = ref.watch(agentConversationsProvider);
    final chat = ref.watch(agentChatProvider);
    conversationsAsync.whenData(_openPrimaryOnce);

    final configured = statusAsync.asData?.value.configured ?? false;
    final conversations = conversationsAsync.asData?.value ?? const [];
    final active = conversations
        .where((c) => c.id == chat.conversationId)
        .cast<AgentConversationVm?>()
        .firstWhere((c) => true, orElse: () => null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          active: active,
          conversations: conversations,
          onClose: widget.onClose,
        ),
        const Divider(height: 1),
        const _MemorySuggestions(),
        Expanded(
          child: chat.loading
              ? const Center(child: CircularProgressIndicator())
              : chat.loadFailed
              ? _RetryBlock(
                  message: '会话加载失败，请重试。',
                  onRetry: () => ref.read(agentChatProvider.notifier).reload(),
                )
              : _MessageList(chat: chat),
        ),
        if (!chat.streamOnline && !chat.loading && !chat.loadFailed)
          _InlineNotice(
            text: '连接已断开',
            actionLabel: '重连',
            onAction: () => ref.read(agentChatProvider.notifier).reconnect(),
          ),
        if (chat.runError != null)
          _InlineNotice(text: chat.runError!, actionLabel: null),
        const Divider(height: 1),
        _Composer(
          draft: _draft,
          pending: _pending,
          configured: configured,
          uploading: _uploading,
          busy: chat.busy,
          sending: chat.sending,
          error: _composerError,
          onPick: _pickAttachment,
          onRemove: (id) =>
              setState(() => _pending.removeWhere((a) => a.meta.id == id)),
          onSend: _send,
          onStop: () => ref.read(agentChatProvider.notifier).cancel(),
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.active,
    required this.conversations,
    required this.onClose,
  });
  final AgentConversationVm? active;
  final List<AgentConversationVm> conversations;
  final VoidCallback? onClose;

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final current = active;
    if (current == null) return;
    final controller = TextEditingController(text: current.title);
    final title = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    await _mutate(
      ref,
      () => ref
          .read(agentRepositoryProvider)
          .updateConversation(current.id, title: title),
    );
  }

  Future<void> _mutate(WidgetRef ref, Future<void> Function() action) async {
    try {
      await action();
    } finally {
      ref.invalidate(agentConversationsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(agentModelsProvider).asData?.value ?? const [];
    final visible = [
      for (final c in conversations)
        if (c.status == AgentConversationStatus.active) c,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              active?.title ?? '助手',
              style: AppType.bodyStrong,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (models.isNotEmpty && active != null)
            PopupMenuButton<String>(
              tooltip: '模型',
              icon: const Icon(Icons.memory_outlined, size: 20),
              onSelected: (modelId) => _mutate(
                ref,
                () => ref
                    .read(agentRepositoryProvider)
                    .updateConversation(active!.id, modelId: modelId),
              ),
              itemBuilder: (_) => [
                for (final m in models)
                  PopupMenuItem(
                    value: m.id,
                    child: Text(
                      m.displayName,
                      style: m.id == active!.selectedModelId
                          ? AppType.bodyStrong
                          : AppType.body,
                    ),
                  ),
              ],
            ),
          PopupMenuButton<String>(
            tooltip: '会话',
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (value) async {
              switch (value) {
                case 'new':
                  await _mutate(ref, () async {
                    final created = await ref
                        .read(agentRepositoryProvider)
                        .createConversation();
                    await ref.read(agentChatProvider.notifier).open(created.id);
                  });
                case 'rename':
                  if (context.mounted) await _rename(context, ref);
                case 'archive':
                  final current = active;
                  if (current == null || current.isPrimary) return;
                  await _mutate(ref, () async {
                    await ref
                        .read(agentRepositoryProvider)
                        .updateConversation(
                          current.id,
                          status: AgentConversationStatus.archived,
                        );
                    final primary = visible.firstWhere(
                      (c) => c.isPrimary,
                      orElse: () => visible.first,
                    );
                    await ref.read(agentChatProvider.notifier).open(primary.id);
                  });
                default:
                  await ref.read(agentChatProvider.notifier).open(value);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'new', child: Text('新建会话')),
              if (active != null)
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
              if (active != null && !active!.isPrimary)
                const PopupMenuItem(value: 'archive', child: Text('归档')),
              if (visible.length > 1) const PopupMenuDivider(),
              for (final c in visible)
                if (c.id != active?.id)
                  PopupMenuItem(value: c.id, child: Text(c.title)),
            ],
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
              tooltip: '关闭',
            ),
        ],
      ),
    );
  }
}

class _MemorySuggestions extends ConsumerWidget {
  const _MemorySuggestions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = ref.watch(agentMemoriesProvider).asData?.value ?? const [];
    final suggested = [
      for (final m in memories)
        if (m.status == AgentMemoryStatus.suggested) m,
    ];
    if (suggested.isEmpty) return const SizedBox.shrink();
    Future<void> review(AgentMemoryVm m, AgentMemoryStatus decision) async {
      try {
        await ref
            .read(agentRepositoryProvider)
            .reviewMemory(m.id, decision: decision);
      } finally {
        ref.invalidate(agentMemoriesProvider);
      }
    }

    return Column(
      children: [
        for (final m in suggested)
          Card(
            margin: const EdgeInsets.fromLTRB(
              AppSpacing.base,
              AppSpacing.sm,
              AppSpacing.base,
              0,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('记忆建议', style: AppType.caption),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(m.content, style: AppType.body),
                  if (m.reason.isNotEmpty)
                    Text(m.reason, style: AppType.caption),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => review(m, AgentMemoryStatus.rejected),
                        child: const Text('拒绝'),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      FilledButton(
                        onPressed: () => review(m, AgentMemoryStatus.active),
                        child: const Text('批准'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({required this.chat});
  final AgentChatState chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPending =
        (ref.watch(aiPendingProvider).asData?.value ?? const []).isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.base),
      children: [
        if (chat.messages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Text('还没有对话', style: AppType.caption),
          ),
        for (final m in chat.messages)
          if (m.role != AgentMessageRole.system) _MessageBubble(message: m),
        if (chat.activity != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Text(chat.activity!, style: AppType.caption),
          ),
        if (hasPending)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.push('/ai-review'),
              child: const Text('前往审核'),
            ),
          ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final AgentMessageVm message;

  @override
  Widget build(BuildContext context) {
    final mine = message.role == AgentMessageRole.user;
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.all(AppSpacing.sm),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.attachmentIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final id in message.attachmentIds)
                      AgentAttachmentThumb(attachmentId: id),
                  ],
                ),
              ),
            if (message.text.isNotEmpty)
              Text(message.text, style: AppType.body)
            else if (message.status == AgentMessageStatus.queued)
              Text('排队中…', style: AppType.caption),
          ],
        ),
      ),
    );
  }
}

/// 历史消息缩略图：从附件 content 接口恢复，不在本地持久化字节。
class AgentAttachmentThumb extends ConsumerWidget {
  const AgentAttachmentThumb({super.key, required this.attachmentId});
  final String attachmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(agentAttachmentBytesProvider(attachmentId));
    return SizedBox(
      width: 72,
      height: 72,
      child: async.when(
        loading: () => const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (_, _) => IconButton(
          tooltip: '重试',
          onPressed: () =>
              ref.invalidate(agentAttachmentBytesProvider(attachmentId)),
          icon: const Icon(Icons.refresh, size: 18),
        ),
        data: (bytes) => ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Image.memory(bytes, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.draft,
    required this.pending,
    required this.configured,
    required this.uploading,
    required this.busy,
    required this.sending,
    required this.error,
    required this.onPick,
    required this.onRemove,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController draft;
  final List<({AgentAttachmentVm meta, Uint8List bytes})> pending;
  final bool configured;
  final bool uploading;
  final bool busy;
  final bool sending;
  final String? error;
  final VoidCallback onPick;
  final ValueChanged<String> onRemove;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final a in pending)
                    Chip(
                      avatar: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.memory(
                          a.bytes,
                          width: 24,
                          height: 24,
                          fit: BoxFit.cover,
                        ),
                      ),
                      label: Text(a.meta.fileName),
                      onDeleted: () => onRemove(a.meta.id),
                    ),
                ],
              ),
            ),
          if (!configured)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text('服务器尚未配置模型', style: AppType.caption),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                error!,
                style: AppType.caption.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                onPressed: configured && !uploading ? onPick : null,
                icon: const Icon(Icons.image_outlined),
                tooltip: '选择图片',
              ),
              Expanded(
                child: TextField(
                  controller: draft,
                  enabled: configured,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '说点什么',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              if (busy)
                IconButton(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: '停止',
                ),
              FilledButton(
                onPressed: configured && !sending ? onSend : null,
                child: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.text,
    required this.actionLabel,
    this.onAction,
  });
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
    child: Row(
      children: [
        Expanded(child: Text(text, style: AppType.caption)),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ),
  );
}

class _RetryBlock extends StatelessWidget {
  const _RetryBlock({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, style: AppType.caption),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}
