// Wealth Ledger — AgentMessageVm → 聊天渲染包消息模型的窄适配层。
// 纯函数、可独立测试：不做 SSE 合并、不持有第二份会话状态，
// Finwealth 的消息 ID 原样作为包内消息 ID，重放与快照对账因此不会重复行。
import 'package:flutter_chat_core/flutter_chat_core.dart';

import '../data/view_models.dart';

/// 聊天视图里的两个作者。
const String kAgentChatUserId = 'finwealth_user';
const String kAgentChatAssistantId = 'finwealth_assistant';

/// metadata 键：附件与渲染意图都放在这里，正文不承载业务数据。
const String kAgentChatAttachmentIds = 'attachmentIds';
const String kAgentChatMarkdown = 'markdown';
const String kAgentChatFailed = 'failed';

/// 把一条 Agent 消息映射成渲染包的消息模型。
/// system 消息不进入可见对话流，返回 null。
Message? agentMessageToChatMessage(AgentMessageVm message) {
  final createdAt = DateTime.tryParse(message.createdAt);
  final metadata = <String, dynamic>{
    if (message.attachmentIds.isNotEmpty)
      kAgentChatAttachmentIds: message.attachmentIds,
  };

  switch (message.role) {
    case AgentMessageRole.system:
      return null;
    case AgentMessageRole.user:
      return Message.text(
        id: message.id,
        authorId: kAgentChatUserId,
        createdAt: createdAt,
        text: message.text,
        metadata: metadata,
      );
    case AgentMessageRole.assistant:
      // 仍在进行的回复用流式消息，避免反复重建一个巨大的 Text。
      if (message.status == AgentMessageStatus.queued ||
          message.status == AgentMessageStatus.streaming) {
        return Message.textStream(
          id: message.id,
          authorId: kAgentChatAssistantId,
          createdAt: createdAt,
          streamId: message.id,
          metadata: metadata,
        );
      }
      return Message.text(
        id: message.id,
        authorId: kAgentChatAssistantId,
        createdAt: createdAt,
        text: message.text,
        metadata: {
          ...metadata,
          kAgentChatMarkdown: true,
          if (message.status == AgentMessageStatus.failed)
            kAgentChatFailed: true,
        },
      );
  }
}

/// 整段会话的映射。顺序与来源一致；system 消息被过滤掉。
List<Message> agentMessagesToChatMessages(List<AgentMessageVm> messages) => [
  for (final m in messages) ?agentMessageToChatMessage(m),
];

/// 该条消息上的附件 ID（渲染附件时用，正文里不出现）。
List<String> agentChatAttachmentIds(Message message) {
  final raw = message.metadata?[kAgentChatAttachmentIds];
  if (raw is! List) return const [];
  return [for (final id in raw) '$id'];
}

bool agentChatIsAssistant(Message message) =>
    message.authorId == kAgentChatAssistantId;

bool agentChatIsMarkdown(Message message) =>
    message.metadata?[kAgentChatMarkdown] == true;
