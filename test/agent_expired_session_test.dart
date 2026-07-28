// Agent 登录失效（2026-07-28 P0）：
// 401 不得被折叠成"服务器尚未配置模型"或空会话；refresh 也 401 才清 token；
// 网络失败/5xx 保留登录态；并发 401 只 refresh 一次、只失效一次；
// 错误态在 Android 常见尺寸下无 overflow。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_panel.dart';
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

Future<MemoryAuthTokenStore> _store() async {
  final store = MemoryAuthTokenStore();
  await store.write(
    const StoredAuthSession(
      accessToken: 'old',
      refreshToken: 'r1',
      expiresAt: '2026-07-28T12:00:00+08:00',
      deviceId: 'd1',
    ),
  );
  return store;
}

const _status = AgentStatusVm(configured: true, modelCount: 1);
const _conversation = AgentConversationVm(
  id: 'conv_1',
  title: '主会话',
  isPrimary: true,
  status: AgentConversationStatus.active,
  createdAt: '2026-07-28T00:00:00Z',
  updatedAt: '2026-07-28T00:00:00Z',
);

/// 面板宿主：直接给定 status / conversations 的 AsyncValue 来源。
class _PanelRepo implements AgentRepository {
  _PanelRepo({this.statusFailure, this.configured = true, this.gate});
  final Object? statusFailure;
  final bool configured;
  final Completer<void>? gate;

  @override
  Future<AgentStatusVm> getStatus() async {
    if (gate != null) await gate!.future;
    if (statusFailure != null) throw statusFailure!;
    return AgentStatusVm(
      configured: configured,
      modelCount: configured ? 1 : 0,
    );
  }

  @override
  Future<List<AgentConversationVm>> listConversations() async {
    if (gate != null) await gate!.future;
    if (statusFailure != null) throw statusFailure!;
    return const [_conversation];
  }

  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async =>
      const [];
  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) =>
      const Stream.empty();
  @override
  Future<List<AgentModelVm>> listModels() async => const [];
  @override
  Future<List<AgentMemoryVm>> listMemories() async => const [];
  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async => const [];
  @override
  Future<List<AgentAutomationVm>> listAutomations() async => const [];
  @override
  Future<List<AgentNotificationVm>> listNotifications() async => const [];
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
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) =>
      throw UnsupportedError('unused');
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
}

Widget _panelHost(_PanelRepo repo) => ProviderScope(
  overrides: [agentRepositoryProvider.overrideWithValue(repo)],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: AgentPanel()),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings-page')),
        ),
      ],
    ),
  ),
);

void main() {
  group('门控纯函数', () {
    const loading = AsyncLoading<AgentStatusVm>();
    const conversationsLoading = AsyncLoading<List<AgentConversationVm>>();
    const conversationsData = AsyncData<List<AgentConversationVm>>([
      _conversation,
    ]);

    test('加载中不算未配置', () {
      expect(
        agentPanelGate(loading, conversationsLoading),
        AgentPanelGate.loading,
      );
    });

    test('401 优先于其他一切', () {
      final unauthorized = AsyncError<AgentStatusVm>(
        ApiUnauthorizedException('/v1/agent/status'),
        StackTrace.empty,
      );
      expect(
        agentPanelGate(unauthorized, conversationsData),
        AgentPanelGate.needsLogin,
      );
      // 会话列表 401 同样进登录态。
      expect(
        agentPanelGate(
          const AsyncData(_status),
          AsyncError<List<AgentConversationVm>>(
            ApiUnauthorizedException('/v1/agent/conversations'),
            StackTrace.empty,
          ),
        ),
        AgentPanelGate.needsLogin,
      );
    });

    test('其他错误是可重试失败，不是未配置', () {
      expect(
        agentPanelGate(
          AsyncError<AgentStatusVm>(Exception('offline'), StackTrace.empty),
          conversationsData,
        ),
        AgentPanelGate.failed,
      );
      expect(
        agentPanelGate(
          const AsyncData(_status),
          AsyncError<List<AgentConversationVm>>(
            ApiServiceUnavailableException('/v1/agent/conversations'),
            StackTrace.empty,
          ),
        ),
        AgentPanelGate.failed,
      );
    });

    test('只有 200 且 configured=false 才是未配置', () {
      expect(
        agentPanelGate(
          const AsyncData(AgentStatusVm(configured: false, modelCount: 0)),
          conversationsData,
        ),
        AgentPanelGate.notConfigured,
      );
      expect(
        agentPanelGate(const AsyncData(_status), conversationsData),
        AgentPanelGate.ready,
      );
    });
  });

  group('面板呈现', () {
    testWidgets('401：显示需要登录并可进设置，不显示未配置或空会话', (tester) async {
      await tester.pumpWidget(
        _panelHost(
          _PanelRepo(
            statusFailure: ApiUnauthorizedException('/v1/agent/status'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('需要登录'), findsOneWidget);
      expect(find.text('服务器尚未配置模型'), findsNothing);
      expect(find.text('还没有对话'), findsNothing);
      expect(find.text('连接已断开'), findsNothing);
      await tester.tap(find.text('去登录'));
      await tester.pumpAndSettle();
      expect(find.text('settings-page'), findsOneWidget);
    });

    testWidgets('网络失败：可重试，不显示未配置', (tester) async {
      await tester.pumpWidget(
        _panelHost(_PanelRepo(statusFailure: Exception('offline'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载失败，请重试。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('服务器尚未配置模型'), findsNothing);
      expect(find.text('需要登录'), findsNothing);
      expect(find.text('还没有对话'), findsNothing);
    });

    testWidgets('503：同样是可重试失败', (tester) async {
      await tester.pumpWidget(
        _panelHost(
          _PanelRepo(
            statusFailure: ApiServiceUnavailableException('/v1/agent/status'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载失败，请重试。'), findsOneWidget);
      expect(find.text('服务器尚未配置模型'), findsNothing);
    });

    testWidgets('加载中：不提前下"未配置"结论', (tester) async {
      final gate = Completer<void>();
      await tester.pumpWidget(_panelHost(_PanelRepo(gate: gate)));
      await tester.pump();
      expect(find.text('服务器尚未配置模型'), findsNothing);
      expect(find.text('需要登录'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('200 且 configured=false：这时才显示未配置', (tester) async {
      await tester.pumpWidget(_panelHost(_PanelRepo(configured: false)));
      await tester.pumpAndSettle();
      expect(find.text('服务器尚未配置模型'), findsWidgets);
      expect(find.text('需要登录'), findsNothing);
      expect(find.text('加载失败，请重试。'), findsNothing);
    });

    testWidgets('Android 360×640 / 720×1280 错误态无 overflow', (tester) async {
      for (final size in const [Size(360, 640), Size(720, 1280)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        for (final failure in [
          ApiUnauthorizedException('/v1/agent/status'),
          Exception('offline'),
        ]) {
          await tester.pumpWidget(
            _panelHost(_PanelRepo(statusFailure: failure)),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '${size.width}');
        }
      }
    });
  });

  group('会话失效处理', () {
    test('access 401 + refresh 401：清 token 并回调一次', () async {
      final store = await _store();
      var expiredCalls = 0;
      var refreshCalls = 0;
      final client = DevApiClient(
        'http://127.0.0.1:8790',
        tokenStore: store,
        onSessionExpired: () async => expiredCalls += 1,
        client: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshCalls += 1;
            return _err(401, 'auth_required');
          }
          return _err(401, 'auth_required');
        }),
      );
      await expectLater(
        client.getData('/v1/agent/status'),
        throwsA(isA<ApiUnauthorizedException>()),
      );
      expect(refreshCalls, 1);
      expect(expiredCalls, 1);
      expect(await store.read(), isNull, reason: '失效 token 必须清除');
    });

    test('refresh 成功：保留登录态并重放原请求', () async {
      final store = await _store();
      var expiredCalls = 0;
      var statusCalls = 0;
      final client = DevApiClient(
        'http://127.0.0.1:8790',
        tokenStore: store,
        onSessionExpired: () async => expiredCalls += 1,
        client: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            return _ok({
              'accessToken': 'new',
              'refreshToken': 'r2',
              'expiresAt': '2026-07-28T13:00:00+08:00',
              'deviceId': 'd1',
            });
          }
          statusCalls += 1;
          if (statusCalls == 1) return _err(401, 'auth_required');
          expect(request.headers['authorization'], 'Bearer new');
          return _ok({
            'service': 'finwealth-agent',
            'configured': true,
            'userId': 'u',
            'ledgerId': 'l',
            'modelCount': 1,
          });
        }),
      );
      final data = await client.getData('/v1/agent/status');
      expect((data as Map)['configured'], isTrue);
      expect(statusCalls, 2);
      expect(expiredCalls, 0);
      expect((await store.read())!.accessToken, 'new');
    });

    test('refresh 网络失败或 5xx：保留 token，不判定失效', () async {
      for (final failure in ['network', 'server']) {
        final store = await _store();
        var expiredCalls = 0;
        final client = DevApiClient(
          'http://127.0.0.1:8790',
          tokenStore: store,
          onSessionExpired: () async => expiredCalls += 1,
          client: MockClient((request) async {
            if (request.url.path == '/v1/auth/refresh') {
              if (failure == 'network') throw http.ClientException('offline');
              return _err(503, 'unavailable');
            }
            return _err(401, 'auth_required');
          }),
        );
        await expectLater(
          client.getData('/v1/agent/status'),
          throwsA(isA<ApiUnauthorizedException>()),
          reason: failure,
        );
        expect(expiredCalls, 0, reason: failure);
        expect(await store.read(), isNotNull, reason: '$failure 不得清除登录态');
      }
    });

    test('并发 401：只 refresh 一次、只失效一次', () async {
      final store = await _store();
      var expiredCalls = 0;
      var refreshCalls = 0;
      final client = DevApiClient(
        'http://127.0.0.1:8790',
        tokenStore: store,
        onSessionExpired: () async => expiredCalls += 1,
        client: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshCalls += 1;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return _err(401, 'auth_required');
          }
          return _err(401, 'auth_required');
        }),
      );
      Future<Object?> capture(String path) async {
        try {
          await client.getData(path);
          return null;
        } catch (error) {
          return error;
        }
      }

      final results = await Future.wait([
        capture('/v1/agent/status'),
        capture('/v1/agent/conversations'),
      ]);
      for (final r in results) {
        expect(r, isA<ApiUnauthorizedException>());
      }
      expect(refreshCalls, 1, reason: '单飞：并发 401 只刷新一次');
      expect(expiredCalls, 1, reason: '本地失效处理只执行一次');
    });
  });
}
