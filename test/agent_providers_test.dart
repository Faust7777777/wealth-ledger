// 模型连接（2026-07-29 任务单 §Tests）：
// 未连接 → 发起 → 设备码 → 已连接；401 重放复用同一 Idempotency-Key；
// failed / cancelled / 过期彼此可分；断开后 Grok 不再可选；
// 选中的模型不可用时绝不换到别的 provider；360 与桌面宽度无 overflow；
// 可见文案不含令牌字段、原始 provider 标识或"自动切换"说法。
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
import 'package:finwealth/features/agent_panel.dart';
import 'package:finwealth/features/agent_providers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response _ok(Object data, {int status = 200}) =>
    _json({'ok': true, 'data': data}, status);
http.Response _err(int status, String code) => _json({
  'ok': false,
  'error': {'code': code},
}, status);

const _grokModel = AgentModelVm(
  id: 'xai/grok-4.5',
  provider: 'xai',
  displayName: 'Grok 4.5',
  supportsImages: true,
);

const _conversation = AgentConversationVm(
  id: 'conv_1',
  title: '主会话',
  isPrimary: true,
  status: AgentConversationStatus.active,
  createdAt: '2026-07-29T00:00:00Z',
  updatedAt: '2026-07-29T00:00:00Z',
  selectedModelId: 'xai/grok-4.5',
);

/// 只实现模型连接与面板会用到的接口。
class _ProviderRepo implements AgentRepository {
  _ProviderRepo({
    this.connected = false,
    this.attemptStatuses = const [AgentProviderOAuthStatus.connected],
    this.startFailure,
    this.expiresAt = '2100-01-01T00:00:00Z',
    this.models,
  });

  bool connected;
  final List<AgentProviderOAuthStatus> attemptStatuses;
  final Object? startFailure;
  final String expiresAt;
  final List<AgentModelVm>? models;

  int starts = 0;
  int polls = 0;
  int disconnects = 0;

  @override
  Future<List<AgentProviderVm>> listProviders() async => [
    AgentProviderVm(
      id: 'xai',
      displayName: 'Grok',
      authMethods: const [AgentProviderAuthMethod.oauth],
      connectionStatus: connected
          ? AgentProviderConnectionStatus.connected
          : AgentProviderConnectionStatus.disconnected,
    ),
  ];

  @override
  Future<AgentProviderOAuthAttemptVm> startProviderOAuth(
    String providerId,
  ) async {
    starts += 1;
    if (startFailure != null) throw startFailure!;
    return AgentProviderOAuthAttemptVm(
      attemptId: 'attempt_1',
      providerId: providerId,
      status: AgentProviderOAuthStatus.pending,
      verificationUri: 'https://x.ai/device',
      userCode: 'WXYZ-1234',
      expiresAt: expiresAt,
    );
  }

  @override
  Future<AgentProviderOAuthAttemptVm> getProviderOAuthAttempt(
    Id attemptId,
  ) async {
    final status = attemptStatuses[polls.clamp(0, attemptStatuses.length - 1)];
    polls += 1;
    if (status == AgentProviderOAuthStatus.connected) connected = true;
    return AgentProviderOAuthAttemptVm(
      attemptId: attemptId,
      providerId: 'xai',
      status: status,
      verificationUri: 'https://x.ai/device',
      userCode: 'WXYZ-1234',
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> disconnectProvider(String providerId) async {
    disconnects += 1;
    connected = false;
  }

  @override
  Future<AgentStatusVm> getStatus() async =>
      AgentStatusVm(configured: connected, modelCount: connected ? 1 : 0);
  @override
  Future<List<AgentModelVm>> listModels() async =>
      models ?? (connected ? const [_grokModel] : const []);
  @override
  Future<List<AgentConversationVm>> listConversations() async => const [
    _conversation,
  ];
  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async =>
      const [];
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_ProviderRepo repo, {String initial = '/agent/providers'}) =>
    ProviderScope(
      overrides: [
        agentRepositoryProvider.overrideWithValue(repo),
        aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: initial,
          routes: [
            GoRoute(
              path: '/agent/providers',
              builder: (_, _) => const AgentProvidersPage(),
            ),
            GoRoute(
              path: '/agent',
              builder: (_, _) => const Scaffold(body: AgentPanel()),
            ),
          ],
        ),
      ),
    );

/// 推进一次轮询（面板里的定时器是真实 Timer，用 pump 推进假时钟）。
Future<void> _poll(WidgetTester tester) async {
  await tester.pump(kAgentOAuthPollInterval);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('连接流程', () {
    testWidgets('未连接 → 发起 → 设备码 → 已连接', (tester) async {
      final repo = _ProviderRepo();
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();

      expect(find.text('Grok'), findsOneWidget);
      expect(find.text('未连接'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.starts, 1);
      // 设备码与授权页都要能看见并可复制。
      expect(find.text('WXYZ-1234'), findsOneWidget);
      expect(find.text('https://x.ai/device'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);
      expect(find.text('打开授权页'), findsOneWidget);
      expect(find.textContaining('后失效'), findsOneWidget);

      await _poll(tester);
      await tester.pumpAndSettle();
      // sheet 自行关闭，行变成已连接。
      expect(find.text('WXYZ-1234'), findsNothing);
      expect(find.text('已连接'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '断开连接'), findsOneWidget);
    });

    testWidgets('失败与取消彼此可分，且停在这一行可重试', (tester) async {
      for (final (status, text) in [
        (AgentProviderOAuthStatus.failed, '授权未完成，请重试'),
        (AgentProviderOAuthStatus.cancelled, '授权已取消'),
      ]) {
        final repo = _ProviderRepo(attemptStatuses: [status]);
        await tester.pumpWidget(_host(repo));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '连接'));
        await tester.pumpAndSettle();
        await _poll(tester);
        await tester.pumpAndSettle();

        expect(find.text(text), findsOneWidget, reason: '$status');
        expect(find.text('未连接'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
      }
    });

    testWidgets('过期：停止轮询并提示重新发起', (tester) async {
      final repo = _ProviderRepo(
        expiresAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
        attemptStatuses: const [AgentProviderOAuthStatus.pending],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await _poll(tester);
      expect(find.text('授权已过期，请重新发起'), findsOneWidget);
      expect(repo.polls, 0, reason: '过期后不再打扰服务端');
      // 再推进一次也不会重新开始轮询。
      await _poll(tester);
      expect(repo.polls, 0);

      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    });

    testWidgets('发起失败：不开面板，只在行上给可重试的短提示', (tester) async {
      final repo = _ProviderRepo(startFailure: Exception('offline'));
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();
      expect(find.text('WXYZ-1234'), findsNothing);
      expect(find.text('连接未成功，请重试'), findsOneWidget);
    });
  });

  group('断开连接', () {
    testWidgets('确认后断开，Grok 不再是可选模型', (tester) async {
      final repo = _ProviderRepo(connected: true);
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      expect(find.text('已连接'), findsOneWidget);
      expect(await repo.listModels(), hasLength(1));

      await tester.tap(find.widgetWithText(TextButton, '断开连接'));
      await tester.pumpAndSettle();
      // 一次简短确认。
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '断开连接'));
      await tester.pumpAndSettle();

      expect(repo.disconnects, 1);
      expect(find.text('未连接'), findsOneWidget);
      expect(await repo.listModels(), isEmpty);
    });

    testWidgets('确认框里取消：不发请求', (tester) async {
      final repo = _ProviderRepo(connected: true);
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '断开连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(repo.disconnects, 0);
      expect(find.text('已连接'), findsOneWidget);
    });
  });

  group('模型不可用', () {
    test('纯函数：只有选中的模型不在列表里才算不可用', () {
      expect(agentSelectedModelMissing(null, const []), isFalse);
      expect(agentSelectedModelMissing('', const [_grokModel]), isFalse);
      expect(agentSelectedModelMissing('xai/grok-4.5', const []), isTrue);
      expect(
        agentSelectedModelMissing('xai/grok-4.5', const [_grokModel]),
        isFalse,
      );
    });

    testWidgets('选中的 Grok 不可用：提示重新连接，不改选别的模型', (tester) async {
      const other = AgentModelVm(
        id: 'openai/gpt-x',
        provider: 'openai',
        displayName: 'GPT-X',
        supportsImages: true,
      );
      final repo = _ProviderRepo(connected: true, models: const [other]);
      await tester.pumpWidget(_host(repo, initial: '/agent'));
      await tester.pumpAndSettle();

      expect(find.text('模型当前不可用'), findsOneWidget);
      expect(find.text('重新连接'), findsOneWidget);
      // 没有任何"已自动切换"的说法，也没有替用户改会话模型。
      expect(find.textContaining('自动'), findsNothing);
      expect(find.text('GPT-X'), findsNothing);
    });
  });

  group('布局与文案', () {
    testWidgets('360 与 1200 宽都无 overflow', (tester) async {
      for (final size in const [Size(360, 640), Size(1200, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final repo = _ProviderRepo();
        await tester.pumpWidget(_host(repo));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '列表 ${size.width}');

        await tester.tap(find.widgetWithText(FilledButton, '连接'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '授权面板 ${size.width}');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('可见文案不含令牌字段、原始 provider 标识或自动切换说法', (tester) async {
      final repo = _ProviderRepo();
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();

      final texts = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          t.data ?? '',
        for (final t in tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        ))
          t.data ?? '',
      ].join('\n');
      for (final banned in [
        'accessToken',
        'refreshToken',
        'token',
        'scope',
        'client_id',
        'auth.json',
        'xai/grok',
        '自动切换',
        '自动回退',
      ]) {
        expect(texts.contains(banned), isFalse, reason: banned);
      }
      // provider 只用显示名，不用服务端 id。
      expect(texts.contains('Grok'), isTrue);
      expect(RegExp(r'(^|\n)xai($|\n)').hasMatch(texts), isFalse);
    });
  });

  group('仓库映射', () {
    test('provider 列表与授权尝试的 wire → VM', () {
      final provider = parseAgentProviderData(const {
        'id': 'xai',
        'displayName': 'Grok',
        'authMethods': ['oauth'],
        'connectionStatus': 'connected',
      });
      expect(provider.id, 'xai');
      expect(provider.authMethods, [AgentProviderAuthMethod.oauth]);
      expect(
        provider.connectionStatus,
        AgentProviderConnectionStatus.connected,
      );

      final attempt = parseAgentOAuthAttemptData(const {
        'attemptId': 'a1',
        'providerId': 'xai',
        'status': 'pending',
        'verificationUri': 'https://x.ai/device',
        'userCode': 'WXYZ-1234',
        'expiresAt': '2026-07-29T01:00:00Z',
      });
      expect(attempt.status, AgentProviderOAuthStatus.pending);
      expect(attempt.userCode, 'WXYZ-1234');
      expect(attempt.errorCode, isNull);
    });

    test('请求路径与方法', () async {
      final calls = <String>[];
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            calls.add('${request.method} ${request.url.path}');
            if (request.url.path == '/v1/agent/providers') {
              return _ok([
                {
                  'id': 'xai',
                  'displayName': 'Grok',
                  'authMethods': ['oauth'],
                  'connectionStatus': 'disconnected',
                },
              ]);
            }
            if (request.url.path.endsWith('/disconnect')) {
              return _ok({'disconnected': true});
            }
            return _ok({
              'attemptId': 'a1',
              'providerId': 'xai',
              'status': 'pending',
              'verificationUri': 'https://x.ai/device',
              'userCode': 'WXYZ-1234',
              'expiresAt': '2026-07-29T01:00:00Z',
            }, status: request.method == 'POST' ? 202 : 200);
          }),
        ),
      );
      await repo.listProviders();
      await repo.startProviderOAuth('xai');
      await repo.getProviderOAuthAttempt('a1');
      await repo.disconnectProvider('xai');
      expect(calls, [
        'GET /v1/agent/providers',
        'POST /v1/agent/providers/xai/oauth/start',
        'GET /v1/agent/provider-oauth/a1',
        'POST /v1/agent/providers/xai/disconnect',
      ]);
    });

    test('401 刷新后重放复用同一个 Idempotency-Key', () async {
      for (final path in ['/oauth/start', '/disconnect']) {
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
              keys.add(request.headers['idempotency-key']!);
              writes += 1;
              if (writes == 1) return _err(401, 'auth_required');
              return _ok(
                path == '/disconnect'
                    ? {'disconnected': true}
                    : {
                        'attemptId': 'a1',
                        'providerId': 'xai',
                        'status': 'pending',
                      },
                status: path == '/disconnect' ? 200 : 202,
              );
            }),
          ),
        );
        if (path == '/disconnect') {
          await repo.disconnectProvider('xai');
        } else {
          await repo.startProviderOAuth('xai');
        }
        expect(writes, 2, reason: path);
        expect(keys[0], keys[1], reason: '$path 重放必须复用同一个 key');
      }
    });

    test('DEMO 与 real_local 不伪造连接成功', () async {
      for (final repo in [
        const FixtureAgentRepository(),
        const RealLocalAgentRepository(),
      ]) {
        expect(await repo.listProviders(), isEmpty);
        expect(() => repo.startProviderOAuth('xai'), throwsUnsupportedError);
        expect(() => repo.disconnectProvider('xai'), throwsUnsupportedError);
      }
    });
  });
}
