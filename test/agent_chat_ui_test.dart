// Agent 对话渲染（2026-07-29 任务单 §P0 回归 1-7）：
// 真实换行成段、长中文回答不溢出、用户消息保持紧凑右气泡、
// 增量只更新同一条、快照 + 重放不重复、Markdown 明暗两套主题都能渲染、
// 工具活动只有一行低强调说明且不出现内部标识。
// 回归 8/9/10（历史附件、10 条候选、键盘/返回/会话与模型 sheet/NavigationRail）
// 由 agent_panel_test.dart 与 agent_session_menu_test.dart 覆盖。
import 'dart:async';
import 'dart:typed_data';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_chat_adapter.dart';
import 'package:finwealth/features/agent_chat_view.dart';
import 'package:finwealth/features/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _conversation = AgentConversationVm(
  id: 'conv_1',
  title: '主会话',
  isPrimary: true,
  status: AgentConversationStatus.active,
  createdAt: '2026-07-29T00:00:00Z',
  updatedAt: '2026-07-29T00:00:00Z',
);

AgentMessageVm _msg({
  required String id,
  required AgentMessageRole role,
  required String text,
  AgentMessageStatus status = AgentMessageStatus.completed,
  List<String> attachmentIds = const [],
}) => AgentMessageVm(
  id: id,
  conversationId: 'conv_1',
  role: role,
  text: text,
  status: status,
  createdAt: '2026-07-29T00:00:00Z',
  attachmentIds: attachmentIds,
);

/// 只实现对话渲染用得到的接口；其余成员保持未实现，被调用即失败。
class _ChatRepo implements AgentRepository {
  _ChatRepo({this.messages = const [], this.eventStream});

  final List<AgentMessageVm> messages;
  final StreamController<AgentEventVm>? eventStream;
  int attachmentReads = 0;

  @override
  Future<AgentStatusVm> getStatus() async =>
      const AgentStatusVm(configured: true, modelCount: 1);
  @override
  Future<List<AgentModelVm>> listModels() async => const [
    AgentModelVm(
      id: 'openai/gpt-x',
      provider: 'openai',
      displayName: 'GPT-X',
      supportsImages: true,
    ),
  ];
  @override
  Future<List<AgentConversationVm>> listConversations() async => const [
    _conversation,
  ];
  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async =>
      messages;
  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) =>
      eventStream?.stream ?? const Stream.empty();
  @override
  Future<List<AgentMemoryVm>> listMemories() async => const [];
  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async => const [];
  @override
  Future<List<AgentAutomationVm>> listAutomations() async => const [];
  @override
  Future<List<AgentNotificationVm>> listNotifications() async => const [];
  @override
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) async =>
      AgentAttachmentVm(
        id: attachmentId,
        fileName: 'note.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 2048,
        sha256: 'b' * 64,
        createdAt: '2026-07-29T00:00:00Z',
      );
  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) async {
    attachmentReads += 1;
    return Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_ChatRepo repo, {ThemeData? theme}) => ProviderScope(
  overrides: [
    agentRepositoryProvider.overrideWithValue(repo),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
  ],
  child: MaterialApp(
    theme: theme ?? ThemeData.light(),
    home: const Scaffold(body: AgentPanel()),
  ),
);

/// 取一条消息正文容器的矩形（key 由渲染层稳定给出）。
Rect _rectOf(WidgetTester tester, String messageId) =>
    tester.getRect(find.byKey(ValueKey('agent_message_$messageId')));

void main() {
  group('对话渲染', () {
    testWidgets('真实换行渲染成多段，且看不到字面 \\n', (tester) async {
      const body = '第一段。\n\n第二段。\n- 列表一\n- 列表二';
      await tester.pumpWidget(
        _host(
          _ChatRepo(
            messages: [
              _msg(id: 'm1', role: AgentMessageRole.assistant, text: body),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining(r'\n'), findsNothing);
      expect(find.textContaining('第二段。'), findsWidgets);
      // 多段内容必然高于单行；单行在默认字号下不到 30。
      expect(_rectOf(tester, 'm1').height, greaterThan(60));
    });

    testWidgets('1500 字中文回答在 360x640 与 720x1280 都不溢出且不着色', (tester) async {
      final long = '这是一段用于验证阅读体验的资产说明文字。' * 75;
      expect(long.length, greaterThanOrEqualTo(1500));
      for (final size in const [Size(360, 640), Size(720, 1280)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _host(
            _ChatRepo(
              messages: [
                _msg(id: 'm1', role: AgentMessageRole.assistant, text: long),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');

        final container = tester.widget<Container>(
          find.byKey(const ValueKey('agent_message_m1')),
        );
        // 助手是无填充的整宽阅读区：没有气泡底色。
        expect(container.decoration, isNull, reason: '宽度 ${size.width}');
        final rect = _rectOf(tester, 'm1');
        expect(rect.width, lessThanOrEqualTo(size.width));
        expect(
          rect.width,
          greaterThan(size.width * 0.7),
          reason: '助手应占整宽 @ ${size.width}',
        );
      }
    });

    testWidgets('短用户消息是右侧紧凑气泡，不铺满整行', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          _ChatRepo(
            messages: [_msg(id: 'u1', role: AgentMessageRole.user, text: '好')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bubble = _rectOf(tester, 'u1');
      final transcript = tester.getRect(find.byType(AgentTranscript));
      expect(bubble.width, lessThan(transcript.width * 0.5));
      expect(bubble.left, greaterThan(transcript.center.dx));
      final container = tester.widget<Container>(
        find.byKey(const ValueKey('agent_message_u1')),
      );
      expect(container.decoration, isNotNull);
    });

    testWidgets('增量 A/B/C 只更新同一条；完成后正好是 ABC', (tester) async {
      final events = StreamController<AgentEventVm>.broadcast();
      addTearDown(events.close);
      await tester.pumpWidget(_host(_ChatRepo(eventStream: events)));
      await tester.pumpAndSettle();

      events.add(
        const AgentEventVm(
          cursor: 1,
          type: AgentEventType.runQueued,
          runId: 'run_1',
          userMessageId: 'u1',
          assistantMessageId: 'a1',
        ),
      );
      events.add(
        const AgentEventVm(
          cursor: 2,
          type: AgentEventType.runStarted,
          runId: 'run_1',
          assistantMessageId: 'a1',
        ),
      );
      for (final (i, delta) in ['A', 'B', 'C'].indexed) {
        events.add(
          AgentEventVm(
            cursor: 3 + i,
            type: AgentEventType.messageDelta,
            assistantMessageId: 'a1',
            delta: delta,
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('AB'), findsNothing);
      expect(find.textContaining('ABC'), findsOneWidget);

      events.add(
        const AgentEventVm(
          cursor: 6,
          type: AgentEventType.runCompleted,
          runId: 'run_1',
          assistantMessageId: 'a1',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('ABC'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent_message_a1')), findsOneWidget);
    });

    testWidgets('快照 + 重放：仍是一条助手消息，正文不翻倍', (tester) async {
      final events = StreamController<AgentEventVm>.broadcast();
      addTearDown(events.close);
      await tester.pumpWidget(
        _host(
          _ChatRepo(
            eventStream: events,
            messages: [
              _msg(id: 'a1', role: AgentMessageRole.assistant, text: '已完成对账'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent_message_a1')), findsOneWidget);

      // 断线续接时服务端重放同一条的 delta。
      events.add(
        const AgentEventVm(
          cursor: 9,
          type: AgentEventType.messageDelta,
          assistantMessageId: 'a1',
          delta: '已完成对账',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent_message_a1')), findsOneWidget);
      expect(find.textContaining('已完成对账已完成对账'), findsNothing);
      expect(find.textContaining('已完成对账'), findsOneWidget);
    });

    testWidgets('Markdown 列表、行内代码、围栏代码与链接在明暗主题下都能渲染', (tester) async {
      const body =
          '要点：\n'
          '- 第一项\n'
          '- 第二项\n\n'
          '行内 `assets` 字段。\n\n'
          '```dart\nfinal a = 1;\n```\n\n'
          '[说明](https://example.com)';
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        await tester.pumpWidget(
          _host(
            _ChatRepo(
              messages: [
                _msg(id: 'm1', role: AgentMessageRole.assistant, text: body),
              ],
            ),
            theme: theme,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // 语法标记不出现在渲染结果里。
        expect(find.textContaining('```'), findsNothing);
        expect(find.textContaining('](https://'), findsNothing);
        expect(find.textContaining('- 第一项'), findsNothing);
        expect(find.textContaining('第一项'), findsWidgets);
        expect(find.textContaining('final a = 1;'), findsWidgets);
        expect(find.textContaining('说明'), findsWidgets);
      }
    });

    testWidgets('工具活动只有一行中文说明，不出现内部标识', (tester) async {
      final events = StreamController<AgentEventVm>.broadcast();
      addTearDown(events.close);
      await tester.pumpWidget(_host(_ChatRepo(eventStream: events)));
      await tester.pumpAndSettle();

      events.add(
        const AgentEventVm(
          cursor: 1,
          type: AgentEventType.toolStarted,
          toolName: 'finwealth_lookup_fx_candidate',
        ),
      );
      // 活动行带持续动画，用固定 pump 代替 pumpAndSettle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AgentActivityRow), findsOneWidget);
      expect(find.text('正在查询汇率…'), findsOneWidget);
      expect(find.textContaining('finwealth_'), findsNothing);

      // 完成后不留常驻卡片。
      events.add(
        const AgentEventVm(cursor: 2, type: AgentEventType.toolCompleted),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgentActivityRow), findsNothing);
    });
  });

  group('消息映射', () {
    test('system 不进入可见对话流；ID 原样保留', () {
      final mapped = agentMessagesToChatMessages([
        _msg(id: 's1', role: AgentMessageRole.system, text: '内部提示'),
        _msg(id: 'u1', role: AgentMessageRole.user, text: '你好'),
        _msg(id: 'a1', role: AgentMessageRole.assistant, text: '在'),
      ]);
      expect(mapped.map((m) => m.id), ['u1', 'a1']);
      expect(mapped.first.authorId, kAgentChatUserId);
      expect(mapped.last.authorId, kAgentChatAssistantId);
    });

    test('进行中的助手消息映射成流式消息，结束后是 Markdown 文本', () {
      final streaming = agentMessageToChatMessage(
        _msg(
          id: 'a1',
          role: AgentMessageRole.assistant,
          text: 'AB',
          status: AgentMessageStatus.streaming,
        ),
      );
      expect(streaming, isA<TextStreamMessage>());
      final done = agentMessageToChatMessage(
        _msg(id: 'a1', role: AgentMessageRole.assistant, text: 'ABC'),
      );
      expect(done, isA<TextMessage>());
      expect(agentChatIsMarkdown(done!), isTrue);
      // 同一条消息在两个阶段的 ID 保持一致，重放不会新增行。
      expect(streaming!.id, done.id);
    });

    test('附件 ID 走 metadata，不进正文', () {
      final mapped = agentMessageToChatMessage(
        _msg(
          id: 'u1',
          role: AgentMessageRole.user,
          text: '看这个',
          attachmentIds: ['att_1', 'att_2'],
        ),
      )!;
      expect(agentChatAttachmentIds(mapped), ['att_1', 'att_2']);
      expect((mapped as TextMessage).text, '看这个');
    });
  });
}
