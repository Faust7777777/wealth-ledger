// Agent 面板与全局入口（2026-07-28 任务单 §P0/§P1/§回归 1-2）：
// 全局低强调入口在窄屏进全屏页、宽屏开右栏且不遮挡导航；
// 无模型时不可发送；断线可重连；记忆建议批准前不表现为已生效；
// 历史图片从附件接口恢复；360/1200/1440 宽无 overflow。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:finwealth/app/app.dart';
import 'package:finwealth/app/home_shell.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
  'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _conversation = AgentConversationVm(
  id: 'conv_1',
  title: '主会话',
  isPrimary: true,
  status: AgentConversationStatus.active,
  createdAt: '2026-07-28T00:00:00Z',
  updatedAt: '2026-07-28T00:00:00Z',
);

AgentMessageVm _message({
  String id = 'msg_1',
  AgentMessageRole role = AgentMessageRole.assistant,
  String text = '已经看过这张账单了',
  List<String> attachmentIds = const [],
}) => AgentMessageVm(
  id: id,
  conversationId: 'conv_1',
  role: role,
  text: text,
  status: AgentMessageStatus.completed,
  createdAt: '2026-07-28T00:00:00Z',
  attachmentIds: attachmentIds,
);

class _FakeAgentRepo implements AgentRepository {
  _FakeAgentRepo({
    this.configured = true,
    this.messages = const [],
    this.memories = const [],
    this.attachmentFails = false,
  });

  final bool configured;
  final List<AgentMessageVm> messages;
  List<AgentMemoryVm> memories;
  final bool attachmentFails;
  final List<({String id, AgentMemoryStatus decision})> reviews = [];
  int attachmentReads = 0;

  @override
  Future<AgentStatusVm> getStatus() async =>
      AgentStatusVm(configured: configured, modelCount: configured ? 1 : 0);
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
      const Stream.empty();
  @override
  Future<List<AgentMemoryVm>> listMemories() async => memories;
  @override
  Future<AgentMemoryVm> reviewMemory(
    Id memoryId, {
    required AgentMemoryStatus decision,
  }) async {
    reviews.add((id: memoryId, decision: decision));
    final updated = [
      for (final m in memories)
        if (m.id == memoryId)
          AgentMemoryVm(
            id: m.id,
            content: m.content,
            reason: m.reason,
            status: decision,
            createdAt: m.createdAt,
            updatedAt: m.updatedAt,
          )
        else
          m,
    ];
    memories = updated;
    return updated.firstWhere((m) => m.id == memoryId);
  }

  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) async {
    attachmentReads += 1;
    if (attachmentFails) throw Exception('offline');
    return _png;
  }

  @override
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentAttachmentVm> uploadAttachment({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentRunAcceptedVm> sendMessage(
    Id conversationId, {
    required String text,
    List<Id> attachmentIds = const [],
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
  @override
  Future<void> cancelRun(Id runId) => throw UnsupportedError('unused');
}

/// Riverpod 未导出 Override 类型，覆盖列表只能就地写在 ProviderScope 里。
Widget _scope(
  _FakeAgentRepo repo, {
  List<AiProposalVm> pending = const [],
  required Widget child,
}) => ProviderScope(
  overrides: [
    agentRepositoryProvider.overrideWithValue(repo),
    aiPendingProvider.overrideWith((ref) async => pending),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
    accountsProvider.overrideWith((ref) async => const <AccountVm>[]),
  ],
  child: child,
);

Widget _panelHost(
  _FakeAgentRepo repo, {
  List<AiProposalVm> pending = const [],
}) => _scope(
  repo,
  pending: pending,
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: AgentPanel()),
        ),
        GoRoute(
          path: '/ai-review',
          builder: (_, _) => const Scaffold(body: Text('review-page')),
        ),
      ],
    ),
  ),
);

void main() {
  group('附件格式与错误文案', () {
    test('只接受 PNG/JPEG/WEBP，HEIC 不可选', () {
      expect(agentImageMimeType('a.png'), 'image/png');
      expect(agentImageMimeType('a.JPG'), 'image/jpeg');
      expect(agentImageMimeType('a.webp'), 'image/webp');
      expect(agentImageMimeType('a.heic'), isNull);
      expect(kAgentImageMimeTypes.containsValue('image/heic'), isFalse);
    });

    test('附件失败只给一句中文，不外露内部标识', () {
      expect(
        agentAttachmentErrorMessage('invalid_attachment_size'),
        '图片超过 15 MiB，请压缩后再试。',
      );
      expect(
        agentAttachmentErrorMessage('invalid_attachment_type'),
        '只支持 PNG、JPEG、WEBP 图片。',
      );
      final fallback = agentAttachmentErrorMessage('some_internal_code');
      expect(fallback, '图片未通过校验，请重新选择。');
      expect(RegExp(r'[a-z_]{6,}').hasMatch(fallback), isFalse);
    });
  });

  group('面板', () {
    testWidgets('无模型：输入区不可发送并给出简短说明', (tester) async {
      await tester.pumpWidget(_panelHost(_FakeAgentRepo(configured: false)));
      await tester.pumpAndSettle();
      expect(find.text('服务器尚未配置模型'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      // 不伪造回复。
      expect(find.textContaining('助手'), findsNothing);
    });

    testWidgets('有模型：可输入并展示历史消息', (tester) async {
      await tester.pumpWidget(
        _panelHost(_FakeAgentRepo(messages: [_message()])),
      );
      await tester.pumpAndSettle();
      expect(find.text('已经看过这张账单了'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('服务器尚未配置模型'), findsNothing);
    });

    testWidgets('SSE 结束后显示断线提示并可重连', (tester) async {
      await tester.pumpWidget(_panelHost(_FakeAgentRepo()));
      await tester.pumpAndSettle();
      expect(find.text('连接已断开'), findsOneWidget);
      expect(find.text('重连'), findsOneWidget);
      await tester.tap(find.text('重连'));
      await tester.pumpAndSettle();
      expect(find.text('连接已断开'), findsOneWidget);
    });

    testWidgets('待审核存在时提供低强调「前往审核」', (tester) async {
      await tester.pumpWidget(
        _panelHost(
          _FakeAgentRepo(messages: [_message()]),
          pending: const [
            AiProposalVm(
              id: 'prop_1',
              status: AiProposalStatus.pending,
              sourceLabel: '助手',
              groups: [],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final action = find.text('前往审核');
      expect(action, findsOneWidget);
      expect(
        find.ancestor(of: action, matching: find.byType(TextButton)),
        findsOneWidget,
      );
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('review-page'), findsOneWidget);
    });

    testWidgets('历史图片从附件接口恢复，不依赖本地字节', (tester) async {
      final repo = _FakeAgentRepo(
        messages: [
          _message(attachmentIds: const ['att_1']),
        ],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(repo.attachmentReads, 1);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('图片回读失败：给重试而不是空白', (tester) async {
      final repo = _FakeAgentRepo(
        messages: [
          _message(attachmentIds: const ['att_1']),
        ],
        attachmentFails: true,
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(repo.attachmentReads, 2);
    });
  });

  group('记忆审批', () {
    testWidgets('建议卡片显示内容与原因，批准前不表现为已生效', (tester) async {
      final repo = _FakeAgentRepo(
        memories: const [
          AgentMemoryVm(
            id: 'mem_1',
            content: '按笔数拆分记账',
            reason: '用户多次纠正',
            status: AgentMemoryStatus.suggested,
            createdAt: '2026-07-28T00:00:00Z',
            updatedAt: '2026-07-28T00:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('记忆建议'), findsOneWidget);
      expect(find.text('按笔数拆分记账'), findsOneWidget);
      expect(find.text('用户多次纠正'), findsOneWidget);
      expect(find.text('批准'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.textContaining('已生效'), findsNothing);

      await tester.tap(find.text('批准'));
      await tester.pumpAndSettle();
      expect(repo.reviews.single.decision, AgentMemoryStatus.active);
      // 批准后不再出现在建议列表。
      expect(find.text('记忆建议'), findsNothing);
    });

    testWidgets('拒绝后同样从建议列表移除', (tester) async {
      final repo = _FakeAgentRepo(
        memories: const [
          AgentMemoryVm(
            id: 'mem_1',
            content: '按笔数拆分记账',
            reason: '',
            status: AgentMemoryStatus.suggested,
            createdAt: '2026-07-28T00:00:00Z',
            updatedAt: '2026-07-28T00:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(repo.reviews.single.decision, AgentMemoryStatus.rejected);
      expect(find.text('记忆建议'), findsNothing);
    });
  });

  group('全局入口', () {
    testWidgets('窄屏：入口进全屏页，返回可退回', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _scope(_FakeAgentRepo(), child: const WealthLedgerApp()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kAgentEntryKey), findsOneWidget);
      await tester.tap(find.byKey(kAgentEntryKey));
      await tester.pumpAndSettle();
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.text('助手'), findsWidgets);

      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(find.byType(AgentPanel), findsNothing);
    });

    testWidgets('宽屏：入口开右栏，导航仍完整可见', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _scope(_FakeAgentRepo(), child: const WealthLedgerApp()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      final railBefore = tester.getRect(find.byType(NavigationRail));

      await tester.tap(find.byKey(kAgentEntryKey));
      await tester.pumpAndSettle();
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(
        tester.getRect(find.byType(NavigationRail)),
        railBefore,
        reason: '右栏不得遮挡或挤压主导航',
      );

      final panel = tester.getRect(find.byType(AgentPanel));
      expect(panel.left, greaterThan(railBefore.right));
      expect(panel.width, kAgentRailWidth);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('360 / 1200 / 1440 宽面板无 overflow', (tester) async {
    for (final width in [360.0, 1200.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _panelHost(
          _FakeAgentRepo(
            messages: [
              _message(
                role: AgentMessageRole.user,
                id: 'msg_u',
                text: '帮我整理这张微信账单里的所有支出，并按商户归类。',
              ),
              _message(attachmentIds: const ['att_1']),
            ],
            memories: const [
              AgentMemoryVm(
                id: 'mem_1',
                content: '按笔数拆分记账，不要合并同一天的多笔支出',
                reason: '用户多次纠正',
                status: AgentMemoryStatus.suggested,
                createdAt: '2026-07-28T00:00:00Z',
                updatedAt: '2026-07-28T00:00:00Z',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
  });
}
