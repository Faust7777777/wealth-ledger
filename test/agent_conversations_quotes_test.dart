// Agent 会话管理与报价候选刷新（2026-07-29 任务单 §必测 1-8）：
// 首次打开最新活跃会话、列表刷新不打断用户选择、归档可见可恢复、
// 永久删除二次确认且只发一次 DELETE、主会话无删除入口、409 保留列表、
// 10 条归档在窄屏与桌面都可滚动无 overflow、
// run.completed 后候选入口立刻出现、回前台刷新但不产生请求风暴。
import 'dart:async';
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/fixture_repositories.dart';
import 'package:finwealth/data/real_local_repositories.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_controller.dart';
import 'package:finwealth/features/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response _ok(Object data, {int status = 200}) =>
    _json({'ok': true, 'data': data}, status);

AgentConversationVm _conv(
  String id,
  String title, {
  bool isPrimary = false,
  AgentConversationStatus status = AgentConversationStatus.active,
  String updatedAt = '2026-07-29T00:00:00Z',
}) => AgentConversationVm(
  id: id,
  title: title,
  isPrimary: isPrimary,
  status: status,
  createdAt: '2026-07-01T00:00:00Z',
  updatedAt: updatedAt,
);

AgentQuoteCandidateVm _candidate(String id) => AgentQuoteCandidateVm(
  id: id,
  kind: AgentQuoteCandidateKind.fx,
  asOf: '2026-07-29',
  source: 'example.com',
  sourceUrl: 'https://example.com/fx',
  status: AgentQuoteCandidateStatus.suggested,
  createdAt: '2026-07-29T00:00:00Z',
  updatedAt: '2026-07-29T00:00:00Z',
  baseCurrency: 'USD',
  quoteCurrency: 'CNY',
  rate: '7.1234',
);

class _ConvRepo implements AgentRepository {
  _ConvRepo({
    required this.conversations,
    this.deleteFailure,
    StreamController<AgentEventVm>? eventStream,
  }) : _events = eventStream;

  List<AgentConversationVm> conversations;
  List<AgentQuoteCandidateVm> candidates = const [];
  final Object? deleteFailure;
  final StreamController<AgentEventVm>? _events;

  final List<String> opened = [];
  final List<String> deleted = [];
  final List<({String id, AgentConversationStatus? status})> updates = [];
  int candidateReads = 0;
  int conversationReads = 0;

  @override
  Future<List<AgentConversationVm>> listConversations() async {
    conversationReads += 1;
    return conversations;
  }

  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async {
    opened.add(conversationId);
    return const [];
  }

  @override
  Future<AgentConversationVm> updateConversation(
    Id conversationId, {
    String? title,
    AgentConversationStatus? status,
    String? modelId,
  }) async {
    updates.add((id: conversationId, status: status));
    conversations = [
      for (final c in conversations)
        if (c.id == conversationId)
          _conv(
            c.id,
            title ?? c.title,
            isPrimary: c.isPrimary,
            status: status ?? c.status,
            updatedAt: c.updatedAt,
          )
        else
          c,
    ];
    return conversations.firstWhere((c) => c.id == conversationId);
  }

  @override
  Future<void> deleteConversation(Id conversationId) async {
    deleted.add(conversationId);
    if (deleteFailure != null) throw deleteFailure!;
    conversations = [
      for (final c in conversations)
        if (c.id != conversationId) c,
    ];
  }

  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async {
    candidateReads += 1;
    return candidates;
  }

  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) =>
      _events?.stream ?? const Stream.empty();

  @override
  Future<AgentStatusVm> getStatus() async =>
      const AgentStatusVm(configured: true, modelCount: 1);
  @override
  Future<List<AgentModelVm>> listModels() async => const [];
  @override
  Future<List<AgentMemoryVm>> listMemories() async => const [];
  @override
  Future<List<AgentProviderVm>> listProviders() async => const [];
  @override
  Future<List<AgentAutomationVm>> listAutomations() async => const [];
  @override
  Future<List<AgentNotificationVm>> listNotifications() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_ConvRepo repo) => ProviderScope(
  overrides: [
    agentRepositoryProvider.overrideWithValue(repo),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
  ],
  child: const MaterialApp(home: Scaffold(body: AgentPanel())),
);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AgentPanel)));

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(kAgentConversationMenuKey));
  await tester.pumpAndSettle();
}

void main() {
  group('默认会话', () {
    testWidgets('返回顺序为「新非主会话、旧主会话」时打开新会话', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_new', '最近对话', updatedAt: '2026-07-29T10:00:00Z'),
          _conv(
            'conv_primary',
            '主会话',
            isPrimary: true,
            updatedAt: '2026-07-01T10:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      expect(
        _container(tester).read(agentChatProvider).conversationId,
        'conv_new',
      );
      expect(find.text('最近对话'), findsOneWidget);
      expect(repo.opened, ['conv_new']);
    });

    testWidgets('归档的最新会话不参与默认打开', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv(
            'conv_archived',
            '已归档的',
            status: AgentConversationStatus.archived,
            updatedAt: '2026-07-29T12:00:00Z',
          ),
          _conv('conv_active', '在用的', updatedAt: '2026-07-29T09:00:00Z'),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      expect(repo.opened, ['conv_active']);
    });

    testWidgets('列表刷新不打断用户当前主动选择', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_a', 'A', updatedAt: '2026-07-29T10:00:00Z'),
          _conv('conv_b', 'B', updatedAt: '2026-07-29T09:00:00Z'),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      expect(repo.opened, ['conv_a']);

      // 用户主动切到 B。
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('agent_conversation_conv_b')));
      await tester.pumpAndSettle();
      expect(
        _container(tester).read(agentChatProvider).conversationId,
        'conv_b',
      );

      // 列表刷新（例如别处触发的 invalidate）不得把用户拽回 A。
      _container(tester).invalidate(agentConversationsProvider);
      await tester.pumpAndSettle();
      expect(
        _container(tester).read(agentChatProvider).conversationId,
        'conv_b',
      );
      expect(repo.opened, ['conv_a', 'conv_b']);
    });
  });

  group('归档管理', () {
    testWidgets('归档后出现「已归档 1」，恢复后回到活跃列表并自动打开', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_a', 'A', updatedAt: '2026-07-29T10:00:00Z'),
          _conv('conv_b', 'B', updatedAt: '2026-07-29T09:00:00Z'),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      // 归档当前会话 A。
      await _openMenu(tester);
      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();
      expect(repo.updates.single.status, AgentConversationStatus.archived);
      expect(
        _container(tester).read(agentChatProvider).conversationId,
        'conv_b',
      );

      await _openMenu(tester);
      expect(find.byKey(kAgentArchivedEntryKey), findsOneWidget);
      expect(find.text('已归档 1'), findsOneWidget);
      // 归档项不常驻在会话列表里。
      expect(
        find.byKey(const ValueKey('agent_conversation_conv_a')),
        findsNothing,
      );

      await tester.tap(find.byKey(kAgentArchivedEntryKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_restore_conv_a')));
      await tester.pumpAndSettle();

      expect(repo.updates.last.status, AgentConversationStatus.active);
      expect(
        _container(tester).read(agentChatProvider).conversationId,
        'conv_a',
      );
      await _openMenu(tester);
      expect(find.byKey(kAgentArchivedEntryKey), findsNothing);
    });

    testWidgets('永久删除：二次确认、只发一次 DELETE、条目消失', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_a', 'A'),
          _conv('conv_old', '去年的账单', status: AgentConversationStatus.archived),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      await _openMenu(tester);
      await tester.tap(find.byKey(kAgentArchivedEntryKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_delete_conv_old')));
      await tester.pumpAndSettle();

      // 确认框只有标题与「永久删除」，没有内部 id / 路径 / 长解释。
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('去年的账单'), findsOneWidget);
      expect(find.text('永久删除'), findsOneWidget);
      expect(find.textContaining('conv_old'), findsNothing);
      expect(find.textContaining('session'), findsNothing);
      expect(repo.deleted, isEmpty, reason: '确认前不得发出删除');

      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(repo.deleted, ['conv_old']);

      await _openMenu(tester);
      expect(find.byKey(kAgentArchivedEntryKey), findsNothing);
    });

    testWidgets('确认框取消：不发删除', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_a', 'A'),
          _conv('conv_old', '旧的', status: AgentConversationStatus.archived),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await tester.tap(find.byKey(kAgentArchivedEntryKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_delete_conv_old')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.deleted, isEmpty);
    });

    testWidgets('主会话没有归档与删除入口', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_primary', '主会话', isPrimary: true),
          _conv(
            'conv_p_arch',
            '主会话的旧档',
            isPrimary: true,
            status: AgentConversationStatus.archived,
          ),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await _openMenu(tester);
      expect(find.text('归档'), findsNothing);
      // 归档态的主会话也不进入归档入口。
      expect(find.byKey(kAgentArchivedEntryKey), findsNothing);
    });

    testWidgets('409：保留列表并重新加载', (tester) async {
      final repo = _ConvRepo(
        conversations: [
          _conv('conv_a', 'A'),
          _conv('conv_old', '旧的', status: AgentConversationStatus.archived),
        ],
        deleteFailure: ApiConflictException('/v1/agent/conversations/conv_old'),
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      final readsBefore = repo.conversationReads;

      await _openMenu(tester);
      await tester.tap(find.byKey(kAgentArchivedEntryKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_delete_conv_old')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();

      expect(repo.deleted, ['conv_old']);
      expect(find.text('会话状态已变化'), findsOneWidget);
      expect(
        repo.conversationReads,
        greaterThan(readsBefore),
        reason: '要重新拉列表',
      );
      await _openMenu(tester);
      expect(find.text('已归档 1'), findsOneWidget);
    });

    testWidgets('10 条归档在 360x640 与 720x1280 都可滚动且无 overflow', (tester) async {
      for (final size in const [Size(360, 640), Size(720, 1280)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final repo = _ConvRepo(
          conversations: [
            _conv('conv_a', 'A'),
            for (var i = 0; i < 10; i += 1)
              _conv(
                'conv_arch_$i',
                '归档会话 $i',
                status: AgentConversationStatus.archived,
              ),
          ],
        );
        await tester.pumpWidget(_host(repo));
        await tester.pumpAndSettle();
        await _openMenu(tester);
        expect(find.text('已归档 10'), findsOneWidget);

        await tester.tap(find.byKey(kAgentArchivedEntryKey));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '归档列表 ${size.width}');
        await tester.drag(
          find.byKey(kAgentArchivedListKey),
          const Offset(0, -200),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '滚动 ${size.width}');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    });
  });

  group('报价候选刷新', () {
    testWidgets('run.completed 后无需重启即出现「报价建议 1」', (tester) async {
      final events = StreamController<AgentEventVm>.broadcast();
      addTearDown(events.close);
      final repo = _ConvRepo(
        conversations: [_conv('conv_a', 'A')],
        eventStream: events,
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      expect(find.textContaining('报价建议'), findsNothing);

      // 工具在服务端写下候选：客户端此时还不知道。
      repo.candidates = [_candidate('qc_1')];
      events.add(
        const AgentEventVm(
          cursor: 1,
          type: AgentEventType.runCompleted,
          runId: 'run_1',
          assistantMessageId: 'a1',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('报价建议 1'), findsOneWidget);
    });

    testWidgets('报价类工具完成后提前刷新一次', (tester) async {
      final events = StreamController<AgentEventVm>.broadcast();
      addTearDown(events.close);
      final repo = _ConvRepo(
        conversations: [_conv('conv_a', 'A')],
        eventStream: events,
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      repo.candidates = [_candidate('qc_1')];

      events.add(
        const AgentEventVm(
          cursor: 1,
          type: AgentEventType.toolCompleted,
          toolName: 'finwealth_lookup_fx_candidate',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('报价建议 1'), findsOneWidget);
    });

    testWidgets('无关工具完成不额外请求候选', (tester) async {
      final events = StreamController<AgentEventVm>.broadcast();
      addTearDown(events.close);
      final repo = _ConvRepo(
        conversations: [_conv('conv_a', 'A')],
        eventStream: events,
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      final before = repo.candidateReads;

      events.add(
        const AgentEventVm(
          cursor: 1,
          type: AgentEventType.toolCompleted,
          toolName: 'finwealth_query',
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.candidateReads, before);
    });

    testWidgets('回前台刷新一次；rebuild 与非 resumed 状态不产生请求风暴', (tester) async {
      final repo = _ConvRepo(conversations: [_conv('conv_a', 'A')]);
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      final before = repo.candidateReads;

      // 生命周期状态机只接受相邻转换：resumed↔inactive↔hidden↔paused。
      final binding = tester.binding;
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(repo.candidateReads, before, reason: '进后台不请求');

      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(repo.candidateReads, before + 1);

      // 连续 rebuild 不再产生请求。
      for (var i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(repo.candidateReads, before + 1);
    });
  });

  group('删除的请求形状', () {
    test('DELETE 路径带非空 Idempotency-Key，401 重放复用同一个', () async {
      final store = MemoryAuthTokenStore();
      await store.write(
        const StoredAuthSession(
          accessToken: 'old',
          refreshToken: 'r1',
          expiresAt: '2026-07-29T12:00:00+08:00',
          deviceId: 'd1',
        ),
      );
      final keys = <String>[];
      final calls = <String>[];
      var writes = 0;
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          tokenStore: store,
          client: MockClient((request) async {
            if (request.url.path == '/v1/auth/refresh') {
              return _ok({
                'accessToken': 'new',
                'refreshToken': 'r2',
                'expiresAt': '2026-07-29T13:00:00+08:00',
                'deviceId': 'd1',
              });
            }
            calls.add('${request.method} ${request.url.path}');
            keys.add(request.headers['idempotency-key'] ?? '');
            writes += 1;
            if (writes == 1) {
              return _json({
                'ok': false,
                'error': {'code': 'auth_required'},
              }, 401);
            }
            return _ok({'deleted': true});
          }),
        ),
      );
      await repo.deleteConversation('conv_old');
      expect(calls, [
        'DELETE /v1/agent/conversations/conv_old',
        'DELETE /v1/agent/conversations/conv_old',
      ]);
      expect(keys.first, isNotEmpty);
      expect(keys[0], keys[1]);
    });

    test('DEMO 与 real_local 不伪装删除成功', () {
      expect(
        () => const FixtureAgentRepository().deleteConversation('c'),
        throwsUnsupportedError,
      );
      expect(
        () => const RealLocalAgentRepository().deleteConversation('c'),
        throwsUnsupportedError,
      );
    });
  });
}
