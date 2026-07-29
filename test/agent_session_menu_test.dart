// Agent 会话菜单真实触摸（2026-07-28 P0）：
// 菜单在真实路由 overlay 上，tap 会话标题必须真正切换会话；
// 事件不得穿透到 composer、不得弹键盘；返回键先关菜单再退页；
// 窄屏文件 chip 的大小必须完整可见。
import 'dart:typed_data';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_controller.dart';
import 'package:finwealth/features/agent_page.dart';
import 'package:finwealth/features/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

AgentConversationVm _conversation(
  String id,
  String title, {
  bool isPrimary = false,
  String? selectedModelId,
}) => AgentConversationVm(
  id: id,
  title: title,
  isPrimary: isPrimary,
  status: AgentConversationStatus.active,
  createdAt: '2026-07-28T00:00:00Z',
  updatedAt: '2026-07-28T00:00:00Z',
  selectedModelId: selectedModelId,
);

const _models = [
  AgentModelVm(
    id: 'preview/fast',
    provider: 'preview',
    displayName: '快速模型',
    supportsImages: true,
  ),
  AgentModelVm(
    id: 'preview/deep',
    provider: 'preview',
    displayName: '深度模型',
    supportsImages: true,
  ),
];

class _MenuRepo implements AgentRepository {
  _MenuRepo({required this.conversations, this.messagesById = const {}});

  List<AgentConversationVm> conversations;
  final Map<String, List<AgentMessageVm>> messagesById;
  final List<String> opened = [];
  final List<({String id, String? title, String? modelId})> updates = [];
  int created = 0;

  @override
  Future<List<AgentConversationVm>> listConversations() async => conversations;

  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async {
    opened.add(conversationId);
    return messagesById[conversationId] ?? const [];
  }

  @override
  Future<AgentConversationVm> createConversation({String? title}) async {
    created += 1;
    final made = _conversation('conv_new', title ?? '新会话');
    conversations = [...conversations, made];
    return made;
  }

  @override
  Future<AgentConversationVm> updateConversation(
    Id conversationId, {
    String? title,
    AgentConversationStatus? status,
    String? modelId,
  }) async {
    updates.add((id: conversationId, title: title, modelId: modelId));
    conversations = [
      for (final c in conversations)
        if (c.id == conversationId)
          AgentConversationVm(
            id: c.id,
            title: title ?? c.title,
            isPrimary: c.isPrimary,
            status: status ?? c.status,
            createdAt: c.createdAt,
            updatedAt: c.updatedAt,
            selectedModelId: modelId ?? c.selectedModelId,
          )
        else
          c,
    ];
    return conversations.firstWhere((c) => c.id == conversationId);
  }

  @override
  Future<List<AgentModelVm>> listModels() async => _models;
  @override
  Future<AgentStatusVm> getStatus() async =>
      const AgentStatusVm(configured: true, modelCount: 2);
  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) =>
      const Stream.empty();
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
      const AgentAttachmentVm(
        id: 'att_1',
        fileName: 'finwealth-acceptance.csv',
        mimeType: 'text/csv',
        sizeBytes: 41,
        sha256: 'a',
        createdAt: '2026-07-28T00:00:00Z',
      );
  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentAttachmentVm> uploadAttachment({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentQuoteCandidateVm> reviewQuoteCandidate(
    Id candidateId, {
    required AgentQuoteCandidateStatus decision,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentMemoryVm> reviewMemory(
    Id memoryId, {
    required AgentMemoryStatus decision,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentRunAcceptedVm> sendMessage(
    Id conversationId, {
    required String text,
    List<Id> attachmentIds = const [],
  }) => throw UnsupportedError('unused');
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
  Future<void> cancelRun(Id runId) => throw UnsupportedError('unused');

  @override
  Future<List<AgentProviderVm>> listProviders() async => const [];
  @override
  Future<AgentProviderOAuthAttemptVm> startProviderOAuth(String providerId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentProviderOAuthAttemptVm> getProviderOAuthAttempt(Id attemptId) =>
      throw UnsupportedError('unused');
  @override
  Future<void> disconnectProvider(String providerId) =>
      throw UnsupportedError('unused');

  @override
  Future<void> deleteConversation(Id conversationId) =>
      throw UnsupportedError('unused');
}

/// 全屏页宿主：与 Android 上的实际结构一致（Scaffold + AgentPage）。
Widget _pageHost(_MenuRepo repo, {String initialLocation = '/agent'}) =>
    ProviderScope(
      overrides: [agentRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Placeholder()),
            GoRoute(path: '/agent', builder: (_, _) => const AgentPage()),
          ],
          initialLocation: initialLocation,
        ),
      ),
    );

void main() {
  group('会话菜单（真实 overlay 触摸）', () {
    testWidgets('tap 另一个会话标题：真正切换活动会话与标题', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repo = _MenuRepo(
        conversations: [
          _conversation('conv_1', '主会话', isPrimary: true),
          _conversation('conv_2', '账单整理'),
        ],
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('主会话'), findsOneWidget);

      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();

      // 在真实 overlay 上点会话标题（不是直接调 onSelected）。
      final item = find.byKey(const ValueKey('agent_conversation_conv_2'));
      expect(item, findsOneWidget);
      await tester.tap(item);
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AgentPanel)),
      );
      expect(
        container.read(agentChatProvider).conversationId,
        'conv_2',
        reason: '真实触摸必须切换活动会话',
      );
      expect(repo.opened, contains('conv_2'));
      expect(find.text('账单整理'), findsOneWidget);
      expect(find.text('主会话'), findsNothing);
    });

    testWidgets('切换会话后加载该会话的消息快照', (tester) async {
      final repo = _MenuRepo(
        conversations: [
          _conversation('conv_1', '主会话', isPrimary: true),
          _conversation('conv_2', '账单整理'),
        ],
        messagesById: {
          'conv_1': [
            AgentMessageVm(
              id: 'm1',
              conversationId: 'conv_1',
              role: AgentMessageRole.assistant,
              text: '主会话里的消息',
              status: AgentMessageStatus.completed,
              createdAt: '2026-07-28T00:00:00Z',
            ),
          ],
          'conv_2': [
            AgentMessageVm(
              id: 'm2',
              conversationId: 'conv_2',
              role: AgentMessageRole.assistant,
              text: '账单会话里的消息',
              status: AgentMessageStatus.completed,
              createdAt: '2026-07-28T00:00:00Z',
            ),
          ],
        },
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('主会话里的消息'), findsOneWidget);

      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_conversation_conv_2')));
      await tester.pumpAndSettle();

      expect(find.text('账单会话里的消息'), findsOneWidget);
      expect(find.text('主会话里的消息'), findsNothing);
    });

    testWidgets('点菜单项不把焦点交给 composer、不弹键盘', (tester) async {
      final repo = _MenuRepo(
        conversations: [
          _conversation('conv_1', '主会话', isPrimary: true),
          _conversation('conv_2', '账单整理'),
        ],
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_conversation_conv_2')));
      await tester.pumpAndSettle();

      final composer = tester.widget<TextField>(find.byType(TextField));
      expect(composer.autofocus, isFalse);
      // 输入框没有拿到焦点，软键盘也没有被唤起。
      expect(
        tester
            .widgetList<EditableText>(find.byType(EditableText))
            .any((e) => e.focusNode.hasFocus),
        isFalse,
        reason: '切换会话不应把焦点交给输入框',
      );
      expect(tester.testTextInput.isVisible, isFalse, reason: '不应弹出键盘');
    });

    testWidgets('点菜单外区域只关闭菜单，不切换会话', (tester) async {
      final repo = _MenuRepo(
        conversations: [
          _conversation('conv_1', '主会话', isPrimary: true),
          _conversation('conv_2', '账单整理'),
        ],
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();
      // 点顶部空白（barrier）区域。
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('新建会话'), findsNothing);
      expect(find.text('主会话'), findsOneWidget);
    });

    testWidgets('返回键先关菜单，再按一次才退出 Agent 页', (tester) async {
      final repo = _MenuRepo(
        conversations: [
          _conversation('conv_1', '主会话', isPrimary: true),
          _conversation('conv_2', '账单整理'),
        ],
      );
      await tester.pumpWidget(_pageHost(repo, initialLocation: '/'));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(Placeholder)));
      router.push('/agent');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();
      expect(find.text('新建会话'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('新建会话'), findsNothing, reason: '第一次返回只关菜单');
      expect(find.byType(AgentPanel), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AgentPanel), findsNothing, reason: '第二次返回才退出');
    });

    testWidgets('新建会话：由菜单项自身触发并切到新会话', (tester) async {
      final repo = _MenuRepo(
        conversations: [_conversation('conv_1', '主会话', isPrimary: true)],
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建会话'));
      await tester.pumpAndSettle();
      expect(repo.created, 1);
      expect(repo.opened, contains('conv_new'));
    });

    testWidgets('模型菜单：真实 tap 切换该会话的模型', (tester) async {
      final repo = _MenuRepo(
        conversations: [
          _conversation(
            'conv_1',
            '主会话',
            isPrimary: true,
            selectedModelId: 'preview/fast',
          ),
        ],
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAgentModelMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深度模型'));
      await tester.pumpAndSettle();
      expect(repo.updates.single.id, 'conv_1');
      expect(repo.updates.single.modelId, 'preview/deep');
    });

    testWidgets('长会话名省略且菜单可滚动', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _MenuRepo(
        conversations: [
          _conversation('conv_1', '主会话', isPrimary: true),
          for (var i = 0; i < 12; i += 1)
            _conversation('conv_$i', '会话 $i ' * 12),
        ],
      );
      await tester.pumpWidget(_pageHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAgentConversationMenuKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView).last, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('窄屏文件 chip', () {
    testWidgets('短文件大小完整可见，不被截成 4…', (tester) async {
      for (final width in [360.0, 720.0]) {
        tester.view.physicalSize = Size(width, 1280);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final repo = _MenuRepo(
          conversations: [_conversation('conv_1', '主会话', isPrimary: true)],
          messagesById: {
            'conv_1': [
              const AgentMessageVm(
                id: 'm1',
                conversationId: 'conv_1',
                role: AgentMessageRole.user,
                text: '这是附件',
                status: AgentMessageStatus.completed,
                createdAt: '2026-07-28T00:00:00Z',
                attachmentIds: ['att_1'],
              ),
            ],
          },
        );
        await tester.pumpWidget(_pageHost(repo));
        await tester.pumpAndSettle();
        expect(find.text(' · 41 B'), findsOneWidget, reason: 'width=$width');
        expect(tester.takeException(), isNull, reason: 'width=$width');
      }
    });
  });
}
