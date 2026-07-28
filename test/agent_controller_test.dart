// Agent 会话控制器（2026-07-28 任务单 §P0-4/5/6）：
// queued → 流式合并 → 完成；快照 + 重连不重复拼接 delta；断线按 cursor 续接；
// tool 事件只显示中文活动行；同一次点击只发一个请求；停止当前运行。
import 'dart:async';
import 'dart:typed_data';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_controller.dart';
import 'package:finwealth/features/agent_tool_labels.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

AgentMessageVm _msg(
  String id,
  AgentMessageRole role,
  String text,
  AgentMessageStatus status, {
  String? runId,
}) => AgentMessageVm(
  id: id,
  conversationId: 'conv_1',
  role: role,
  text: text,
  status: status,
  createdAt: '2026-07-28T00:00:00Z',
  runId: runId,
);

AgentEventVm _event(
  int cursor,
  AgentEventType type, {
  String? runId,
  String? userMessageId,
  String? assistantMessageId,
  String? delta,
  String? toolName,
  String? code,
}) => AgentEventVm(
  cursor: cursor,
  type: type,
  runId: runId,
  userMessageId: userMessageId,
  assistantMessageId: assistantMessageId,
  delta: delta,
  toolName: toolName,
  code: code,
);

class _FakeAgentRepo implements AgentRepository {
  _FakeAgentRepo({this.snapshot = const [], this.streams = const []});

  List<AgentMessageVm> snapshot;

  /// 每次订阅按顺序取一条事件流；用于模拟断线后的续接。
  final List<List<AgentEventVm>> streams;

  final List<int?> subscribeAfter = [];
  final List<({String text, List<String> attachmentIds})> sent = [];
  final List<String> cancelled = [];
  int sendCalls = 0;
  Object? sendFailure;
  Completer<void>? sendGate;
  bool failSnapshot = false;

  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async {
    if (failSnapshot) throw Exception('offline');
    return snapshot;
  }

  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) {
    subscribeAfter.add(after);
    final index = subscribeAfter.length - 1;
    final frames = index < streams.length
        ? streams[index]
        : const <AgentEventVm>[];
    return Stream.fromIterable(frames);
  }

  @override
  Future<AgentRunAcceptedVm> sendMessage(
    Id conversationId, {
    required String text,
    List<Id> attachmentIds = const [],
  }) async {
    sendCalls += 1;
    sent.add((text: text, attachmentIds: attachmentIds));
    if (sendGate != null) await sendGate!.future;
    if (sendFailure != null) throw sendFailure!;
    return const AgentRunAcceptedVm(
      runId: 'run_1',
      userMessageId: 'msg_u',
      assistantMessageId: 'msg_a',
    );
  }

  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async => const [];
  @override
  Future<AgentQuoteCandidateVm> reviewQuoteCandidate(
    Id candidateId, {
    required AgentQuoteCandidateStatus decision,
  }) => throw UnsupportedError('unused');
  @override
  Future<List<AgentAutomationVm>> listAutomations() async => const [];
  @override
  Future<List<AgentNotificationVm>> listNotifications() async => const [];
  @override
  Future<AgentAutomationVm> createAutomation({
    required AgentAutomationKind kind,
    required int intervalHours,
    bool enabled = true,
    IsoDateTime? startAt,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentAutomationVm> updateAutomation(
    Id automationId, {
    int? intervalHours,
    bool? enabled,
    IsoDateTime? nextRunAt,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentAutomationVm> runAutomation(Id automationId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentNotificationVm> markNotificationRead(Id notificationId) =>
      throw UnsupportedError('unused');
  @override
  Future<void> cancelRun(Id runId) async => cancelled.add(runId);

  @override
  Future<AgentStatusVm> getStatus() async =>
      const AgentStatusVm(configured: true, modelCount: 1);
  @override
  Future<List<AgentModelVm>> listModels() async => const [];
  @override
  Future<List<AgentMemoryVm>> listMemories() async => const [];
  @override
  Future<List<AgentConversationVm>> listConversations() async => const [];
  @override
  Future<AgentAttachmentVm> uploadAttachment({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) =>
      throw UnsupportedError('unused');
  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentMemoryVm> reviewMemory(
    Id memoryId, {
    required AgentMemoryStatus decision,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentConversationVm> createConversation({String? title}) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentConversationVm> updateConversation(
    Id conversationId, {
    String? title,
    AgentConversationStatus? status,
    String? modelId,
  }) => throw UnsupportedError('unused');
}

ProviderContainer _container(_FakeAgentRepo repo) {
  final container = ProviderContainer(
    overrides: [
      agentRepositoryProvider.overrideWithValue(repo),
      aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
      overviewProvider.overrideWith(
        (ref) async => const PortfolioOverviewVm(
          pendingSummary: PendingSummaryVm(),
          quoteStatusSummary: QuoteStatusSummaryVm(),
          primaryHoldings: [],
          recentMovements: [],
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('工具事件只显示中文活动行，未知工具统一回落', () {
    expect(agentToolLabel('finwealth_query'), '正在读取数据…');
    expect(agentToolLabel('finwealth_propose_movement'), '正在整理记录…');
    expect(agentToolLabel('finwealth_refresh_quotes'), '正在刷新估值…');
    expect(agentToolLabel('finwealth_suggest_memory'), '正在整理偏好…');
    for (final unknown in ['bash', 'read', 'write', null]) {
      expect(agentToolLabel(unknown), '正在处理…');
    }
  });

  test('run.failed 的 code 映射成一句中文，不外露内部标识', () {
    expect(agentRunErrorMessage('agent_model_not_configured'), '服务器尚未配置模型');
    expect(agentRunErrorMessage('agent_run_cancelled'), '已停止本次运行');
    final fallback = agentRunErrorMessage('some_internal_code');
    expect(fallback, '这次没能完成，请重试');
    expect(RegExp(r'[a-z_]{6,}').hasMatch(fallback), isFalse);
  });

  test('queued → started → delta → completed 合并成一条助手消息', () async {
    final repo = _FakeAgentRepo(
      streams: [
        [
          _event(
            1,
            AgentEventType.runQueued,
            runId: 'run_1',
            userMessageId: 'msg_u',
            assistantMessageId: 'msg_a',
          ),
          _event(2, AgentEventType.runStarted, assistantMessageId: 'msg_a'),
          _event(3, AgentEventType.toolStarted, toolName: 'finwealth_query'),
          _event(4, AgentEventType.toolCompleted, toolName: 'finwealth_query'),
          _event(
            5,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: '你',
          ),
          _event(
            6,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: '好',
          ),
          _event(7, AgentEventType.runCompleted, assistantMessageId: 'msg_a'),
        ],
      ],
    );
    final container = _container(repo);
    await container.read(agentChatProvider.notifier).open('conv_1');
    await Future<void>.delayed(Duration.zero);

    final state = container.read(agentChatProvider);
    final assistant = state.messages.firstWhere((m) => m.id == 'msg_a');
    expect(assistant.text, '你好');
    expect(assistant.status, AgentMessageStatus.completed);
    expect(state.activity, isNull, reason: 'tool.completed 后活动行收起');
    expect(state.activeRunId, isNull);
    expect(state.cursor, 7);
  });

  test('页面重开：已完成消息用快照文本，重放的 delta 被丢弃', () async {
    final repo = _FakeAgentRepo(
      snapshot: [
        _msg(
          'msg_u',
          AgentMessageRole.user,
          '你好',
          AgentMessageStatus.completed,
        ),
        _msg(
          'msg_a',
          AgentMessageRole.assistant,
          '你好，我在',
          AgentMessageStatus.completed,
        ),
      ],
      streams: [
        [
          // 无 cursor 时服务端会重放全部保留事件。
          _event(
            1,
            AgentEventType.runQueued,
            runId: 'run_1',
            userMessageId: 'msg_u',
            assistantMessageId: 'msg_a',
          ),
          _event(
            2,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: '你好，',
          ),
          _event(
            3,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: '我在',
          ),
          _event(4, AgentEventType.runCompleted, assistantMessageId: 'msg_a'),
        ],
      ],
    );
    final container = _container(repo);
    await container.read(agentChatProvider.notifier).open('conv_1');
    await Future<void>.delayed(Duration.zero);

    final assistant = container
        .read(agentChatProvider)
        .messages
        .firstWhere((m) => m.id == 'msg_a');
    expect(assistant.text, '你好，我在', reason: '不得重复拼接成「你好，我在你好，我在」');
    expect(repo.subscribeAfter.single, isNull);
  });

  test('页面重开：仍在进行的消息由 delta 重建', () async {
    final repo = _FakeAgentRepo(
      snapshot: [
        _msg(
          'msg_a',
          AgentMessageRole.assistant,
          '',
          AgentMessageStatus.streaming,
          runId: 'run_1',
        ),
      ],
      streams: [
        [
          _event(
            9,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: '继续',
          ),
        ],
      ],
    );
    final container = _container(repo);
    await container.read(agentChatProvider.notifier).open('conv_1');
    await Future<void>.delayed(Duration.zero);

    final state = container.read(agentChatProvider);
    expect(state.messages.single.text, '继续');
    expect(state.activeRunId, 'run_1', reason: '未结束的运行应保留停止入口');
  });

  test('断线：从已应用的 cursor 续接，补发不重复拼接', () async {
    final repo = _FakeAgentRepo(
      streams: [
        [
          _event(
            1,
            AgentEventType.runQueued,
            runId: 'run_1',
            userMessageId: 'msg_u',
            assistantMessageId: 'msg_a',
          ),
          _event(
            2,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: 'AB',
          ),
        ],
        [
          _event(
            3,
            AgentEventType.messageDelta,
            assistantMessageId: 'msg_a',
            delta: 'CD',
          ),
          _event(4, AgentEventType.runCompleted, assistantMessageId: 'msg_a'),
        ],
      ],
    );
    final container = _container(repo);
    final controller = container.read(agentChatProvider.notifier);
    await controller.open('conv_1');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(agentChatProvider).streamOnline, isFalse);
    expect(container.read(agentChatProvider).cursor, 2);

    controller.reconnect();
    await Future<void>.delayed(Duration.zero);

    expect(repo.subscribeAfter, [null, 2], reason: '续接必须带已应用的 cursor');
    expect(
      container
          .read(agentChatProvider)
          .messages
          .firstWhere((m) => m.id == 'msg_a')
          .text,
      'ABCD',
    );
    expect(container.read(agentChatProvider).cursor, 4);
  });

  test('发送：同一次点击只产生一个请求，busy 时仍可排队', () async {
    final repo = _FakeAgentRepo()..sendGate = Completer<void>();
    final container = _container(repo);
    final controller = container.read(agentChatProvider.notifier);
    await controller.open('conv_1');
    await Future<void>.delayed(Duration.zero);

    final first = controller.send(text: '一');
    final duplicate = controller.send(text: '一');
    expect(repo.sendCalls, 1, reason: '飞行中的请求不得被重复触发');
    repo.sendGate!.complete();
    await first;
    await duplicate;
    expect(repo.sendCalls, 1);

    // busy（有活动运行）时依然允许再发一条。
    expect(container.read(agentChatProvider).busy, isTrue);
    await controller.send(text: '二');
    expect(repo.sendCalls, 2);
    expect(repo.sent.last.text, '二');
  });

  test('发送失败：返回一句中文，草稿由调用方保留', () async {
    final repo = _FakeAgentRepo()..sendFailure = Exception('boom');
    final container = _container(repo);
    final controller = container.read(agentChatProvider.notifier);
    await controller.open('conv_1');
    await Future<void>.delayed(Duration.zero);
    expect(await controller.send(text: '你好'), '发送失败，请重试');
    expect(container.read(agentChatProvider).sending, isFalse);
  });

  test('停止当前运行：调用 cancel 并带上活动 runId', () async {
    final repo = _FakeAgentRepo(
      streams: [
        [
          _event(
            1,
            AgentEventType.runQueued,
            runId: 'run_7',
            userMessageId: 'msg_u',
            assistantMessageId: 'msg_a',
          ),
        ],
      ],
    );
    final container = _container(repo);
    final controller = container.read(agentChatProvider.notifier);
    await controller.open('conv_1');
    await Future<void>.delayed(Duration.zero);
    await controller.cancel();
    expect(repo.cancelled, ['run_7']);
  });

  test('快照加载失败：标记失败且不订阅 SSE', () async {
    final repo = _FakeAgentRepo()..failSnapshot = true;
    final container = _container(repo);
    await container.read(agentChatProvider.notifier).open('conv_1');
    expect(container.read(agentChatProvider).loadFailed, isTrue);
    expect(repo.subscribeAfter, isEmpty);
  });

  test('run.completed 后刷新待审核入口计数', () async {
    var pendingBuilds = 0;
    final repo = _FakeAgentRepo(
      streams: [
        [
          _event(
            1,
            AgentEventType.runQueued,
            runId: 'run_1',
            userMessageId: 'msg_u',
            assistantMessageId: 'msg_a',
          ),
          _event(2, AgentEventType.runCompleted, assistantMessageId: 'msg_a'),
        ],
      ],
    );
    final container = ProviderContainer(
      overrides: [
        agentRepositoryProvider.overrideWithValue(repo),
        aiPendingProvider.overrideWith((ref) async {
          pendingBuilds += 1;
          return const <AiProposalVm>[];
        }),
        overviewProvider.overrideWith(
          (ref) async => const PortfolioOverviewVm(
            pendingSummary: PendingSummaryVm(),
            quoteStatusSummary: QuoteStatusSummaryVm(),
            primaryHoldings: [],
            recentMovements: [],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(aiPendingProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(aiPendingProvider.future);
    final before = pendingBuilds;

    await container.read(agentChatProvider.notifier).open('conv_1');
    await Future<void>.delayed(Duration.zero);
    await container.read(aiPendingProvider.future);
    expect(pendingBuilds, greaterThan(before));
  });
}
