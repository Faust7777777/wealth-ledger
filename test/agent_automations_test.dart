// Agent 自动任务与通知（2026-07-28 任务单）：
// 四行任务只暴露开关/频率/下次时间/上次结果/立即运行；失败只说"上次未完成"；
// 通知入口低强调 + 未读数，打开即幂等标记已读并按 action 跳转；
// 界面不出现 cron / sidecar / timer / 内部错误码；三档宽度无 overflow。
import 'dart:async';
import 'dart:typed_data';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart'
    show
        ApiConflictException,
        parseAgentAutomationData,
        parseAgentNotificationData;
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_automations_page.dart';
import 'package:finwealth/features/agent_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

AgentAutomationVm _automation({
  String id = 'auto_1',
  AgentAutomationKind kind = AgentAutomationKind.quoteRefresh,
  int intervalHours = 24,
  bool enabled = true,
  String nextRunAt = '2026-07-29T02:00:00Z',
  String? lastRunAt,
  AgentAutomationRunStatus? lastStatus,
  String? lastErrorCode,
}) => AgentAutomationVm(
  id: id,
  kind: kind,
  intervalHours: intervalHours,
  enabled: enabled,
  nextRunAt: nextRunAt,
  createdAt: '2026-07-28T00:00:00Z',
  updatedAt: '2026-07-28T00:00:00Z',
  lastRunAt: lastRunAt,
  lastStatus: lastStatus,
  lastErrorCode: lastErrorCode,
);

AgentNotificationVm _notification({
  String id = 'note_1',
  AgentAutomationKind kind = AgentAutomationKind.subscriptionDueScan,
  String title = '订阅到期扫描完成',
  String body = '生成了 2 条待确认扣费',
  AgentNotificationAction? action = AgentNotificationAction.review,
  String? readAt,
}) => AgentNotificationVm(
  id: id,
  kind: kind,
  title: title,
  body: body,
  createdAt: '2026-07-28T09:30:00Z',
  action: action,
  readAt: readAt,
);

class _FakeAgentRepo implements AgentRepository {
  _FakeAgentRepo({
    this.automations = const [],
    this.notifications = const [],
    this.failure,
    this.runGate,
  });

  List<AgentAutomationVm> automations;
  List<AgentNotificationVm> notifications;
  final Object? failure;
  final Completer<void>? runGate;

  final List<({AgentAutomationKind kind, int intervalHours})> created = [];
  final List<
    ({String id, int? intervalHours, bool? enabled, String? nextRunAt})
  >
  updated = [];
  final List<String> runs = [];
  final List<String> reads = [];

  @override
  Future<List<AgentAutomationVm>> listAutomations() async => automations;

  @override
  Future<AgentAutomationVm> createAutomation({
    required AgentAutomationKind kind,
    required int intervalHours,
    bool enabled = true,
    IsoDateTime? startAt,
  }) async {
    created.add((kind: kind, intervalHours: intervalHours));
    if (failure != null) throw failure!;
    final made = _automation(id: 'auto_${kind.name}', kind: kind);
    automations = [...automations, made];
    return made;
  }

  @override
  Future<AgentAutomationVm> updateAutomation(
    Id automationId, {
    int? intervalHours,
    bool? enabled,
    IsoDateTime? nextRunAt,
  }) async {
    updated.add((
      id: automationId,
      intervalHours: intervalHours,
      enabled: enabled,
      nextRunAt: nextRunAt,
    ));
    if (failure != null) throw failure!;
    automations = [
      for (final a in automations)
        if (a.id == automationId)
          _automation(
            id: a.id,
            kind: a.kind,
            intervalHours: intervalHours ?? a.intervalHours,
            enabled: enabled ?? a.enabled,
            nextRunAt: nextRunAt ?? a.nextRunAt,
            lastRunAt: a.lastRunAt,
            lastStatus: a.lastStatus,
          )
        else
          a,
    ];
    return automations.firstWhere((a) => a.id == automationId);
  }

  @override
  Future<AgentAutomationVm> runAutomation(Id automationId) async {
    runs.add(automationId);
    if (runGate != null) await runGate!.future;
    if (failure != null) throw failure!;
    return automations.firstWhere((a) => a.id == automationId);
  }

  @override
  Future<List<AgentNotificationVm>> listNotifications() async => notifications;

  @override
  Future<AgentNotificationVm> markNotificationRead(Id notificationId) async {
    reads.add(notificationId);
    if (failure != null) throw failure!;
    notifications = [
      for (final n in notifications)
        if (n.id == notificationId)
          _notification(
            id: n.id,
            kind: n.kind,
            title: n.title,
            body: n.body,
            action: n.action,
            readAt: '2026-07-28T10:00:00Z',
          )
        else
          n,
    ];
    return notifications.firstWhere((n) => n.id == notificationId);
  }

  // —— 其余接口本组测试不用 ——
  @override
  Future<AgentStatusVm> getStatus() async =>
      const AgentStatusVm(configured: true, modelCount: 1);
  @override
  Future<List<AgentModelVm>> listModels() async => const [];
  @override
  Future<List<AgentConversationVm>> listConversations() async => const [];
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
}

Widget _host(_FakeAgentRepo repo, {required Widget child}) => ProviderScope(
  overrides: [agentRepositoryProvider.overrideWithValue(repo)],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => child),
        GoRoute(
          path: '/ai-review',
          builder: (_, _) => const Scaffold(body: Text('review-page')),
        ),
        GoRoute(
          path: '/investment',
          builder: (_, _) => const Scaffold(body: Text('investment-page')),
        ),
      ],
    ),
  ),
);

Widget _automationsHost(_FakeAgentRepo repo) =>
    _host(repo, child: const AgentAutomationsPage());

Widget _notificationsHost(_FakeAgentRepo repo) => _host(
  repo,
  child: const Scaffold(body: Center(child: AgentNotificationsEntry())),
);

void main() {
  group('映射与纯函数', () {
    test('automation wire → VM，含失败状态', () {
      final vm = parseAgentAutomationData({
        'id': 'auto_1',
        'userId': 'u',
        'ledgerId': 'l',
        'deviceId': 'd',
        'kind': 'subscription_due_scan',
        'intervalHours': 6,
        'enabled': false,
        'nextRunAt': '2026-07-29T02:00:00Z',
        'lastRunAt': '2026-07-28T02:00:00Z',
        'lastStatus': 'failed',
        'lastErrorCode': 'agent_run_failed',
        'createdAt': '2026-07-28T00:00:00Z',
        'updatedAt': '2026-07-28T02:00:00Z',
      });
      expect(vm.kind, AgentAutomationKind.subscriptionDueScan);
      expect(vm.intervalHours, 6);
      expect(vm.enabled, isFalse);
      expect(vm.lastRunFailed, isTrue);
      expect(vm.lastErrorCode, 'agent_run_failed');
    });

    test('notification wire → VM，含 action 与已读', () {
      final unread = parseAgentNotificationData({
        'id': 'note_1',
        'userId': 'u',
        'ledgerId': 'l',
        'kind': 'financial_summary',
        'title': '本周财务总结',
        'body': '净资产较上周 +1.2%',
        'action': 'agent',
        'createdAt': '2026-07-28T09:30:00Z',
      });
      expect(unread.kind, AgentAutomationKind.financialSummary);
      expect(unread.action, AgentNotificationAction.agent);
      expect(unread.isUnread, isTrue);

      final read = parseAgentNotificationData({
        'id': 'note_2',
        'userId': 'u',
        'ledgerId': 'l',
        'kind': 'quote_refresh',
        'title': '报价已刷新',
        'body': '',
        'action': 'quotes',
        'createdAt': '2026-07-28T09:30:00Z',
        'readAt': '2026-07-28T10:00:00Z',
      });
      expect(read.isUnread, isFalse);
      expect(read.action, AgentNotificationAction.quotes);
    });

    test('频率标签与 1–720 校验', () {
      expect(agentIntervalLabel(1), '每小时');
      expect(agentIntervalLabel(6), '每 6 小时');
      expect(agentIntervalLabel(24), '每天');
      expect(agentIntervalLabel(168), '每周');
      expect(agentIntervalLabel(72), '每 72 小时');
      expect(agentIntervalError('1'), isNull);
      expect(agentIntervalError('720'), isNull);
      expect(agentIntervalError('0'), '请填写 1–720 之间的小时数');
      expect(agentIntervalError('721'), '请填写 1–720 之间的小时数');
      expect(agentIntervalError('abc'), '请填写 1–720 之间的小时数');
    });

    test('四类任务各有中文名，无内部标识', () {
      for (final kind in AgentAutomationKind.values) {
        final label = agentAutomationKindLabel(kind);
        expect(label, isNotEmpty);
        expect(RegExp(r'[a-z_]{4,}').hasMatch(label), isFalse, reason: label);
      }
    });
  });

  group('自动任务设置页', () {
    testWidgets('无任务：四行都在，开关关闭且没有运行入口', (tester) async {
      await tester.pumpWidget(_automationsHost(_FakeAgentRepo()));
      await tester.pumpAndSettle();
      expect(find.text('结构化报价刷新'), findsOneWidget);
      expect(find.text('订阅到期扫描'), findsOneWidget);
      expect(find.text('定投到期检查'), findsOneWidget);
      expect(find.text('周期财务总结'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(4));
      for (final s in tester.widgetList<Switch>(find.byType(Switch))) {
        expect(s.value, isFalse);
      }
      expect(find.text('立即运行'), findsNothing);
      // 不出现实现说明。
      expect(find.textContaining('cron'), findsNothing);
      expect(find.textContaining('sidecar'), findsNothing);
      expect(find.textContaining('timer'), findsNothing);
      // 不提供自动写入类开关。
      expect(find.textContaining('自动采用'), findsNothing);
      expect(find.textContaining('自动确认'), findsNothing);
      expect(find.textContaining('自动执行'), findsNothing);
    });

    testWidgets('打开开关：为该类型创建计划', (tester) async {
      final repo = _FakeAgentRepo();
      await tester.pumpWidget(_automationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(repo.created.single.kind, AgentAutomationKind.quoteRefresh);
      expect(repo.created.single.intervalHours, 24);
    });

    testWidgets('四个任务：显示频率、下次时间、上次结果与立即运行', (tester) async {
      // 四张卡需要足够高的视口才会全部构建。
      tester.view.physicalSize = const Size(500, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _FakeAgentRepo(
        automations: [
          for (final (i, kind) in AgentAutomationKind.values.indexed)
            _automation(
              id: 'auto_$i',
              kind: kind,
              intervalHours: kAgentIntervalPresets[i],
              lastRunAt: '2026-07-28T02:00:00Z',
              lastStatus: AgentAutomationRunStatus.success,
            ),
        ],
      );
      await tester.pumpWidget(_automationsHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('每小时'), findsOneWidget);
      expect(find.text('每 6 小时'), findsOneWidget);
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('每周'), findsOneWidget);
      expect(find.textContaining('下次 '), findsNWidgets(4));
      expect(find.textContaining('上次完成'), findsNWidgets(4));
      expect(find.text('立即运行'), findsNWidgets(4));
    });

    testWidgets('失败只显示"上次未完成"与重试时间，不外露错误码', (tester) async {
      await tester.pumpWidget(
        _automationsHost(
          _FakeAgentRepo(
            automations: [
              _automation(
                lastRunAt: '2026-07-28T02:00:00Z',
                lastStatus: AgentAutomationRunStatus.failed,
                lastErrorCode: 'agent_quote_provider_unreachable',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('上次未完成'), findsOneWidget);
      expect(find.textContaining('重试'), findsOneWidget);
      expect(find.textContaining('agent_quote'), findsNothing);
      expect(find.textContaining('上次完成'), findsNothing);
    });

    testWidgets('立即运行：busy 时禁用，同一次点击只发一个请求', (tester) async {
      final gate = Completer<void>();
      final repo = _FakeAgentRepo(automations: [_automation()], runGate: gate);
      await tester.pumpWidget(_automationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即运行'));
      await tester.pump();
      expect(repo.runs, hasLength(1));
      expect(
        tester
            .widget<OutlinedButton>(find.byType(OutlinedButton).first)
            .onPressed,
        isNull,
        reason: 'busy 时按钮禁用',
      );
      await tester.tap(find.byType(OutlinedButton).first, warnIfMissed: false);
      await tester.pump();
      expect(repo.runs, hasLength(1));
      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('立即运行 409：提示正在运行，不外露内部细节', (tester) async {
      final repo = _FakeAgentRepo(
        automations: [_automation()],
        failure: ApiConflictException(
          '/v1/agent/automations/auto_1/run',
          code: 'agent_automation_already_running',
        ),
      );
      await tester.pumpWidget(_automationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即运行'));
      await tester.pumpAndSettle();
      expect(find.text('这项任务正在运行，请稍后再试'), findsOneWidget);
      expect(find.textContaining('agent_automation'), findsNothing);
    });

    testWidgets('改频率：预设与自定义都发 intervalHours', (tester) async {
      final repo = _FakeAgentRepo(automations: [_automation()]);
      await tester.pumpWidget(_automationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每周'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(repo.updated.single.intervalHours, 168);

      await tester.tap(find.text('每周'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '720');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(repo.updated.last.intervalHours, 720);
    });

    testWidgets('自定义超出 1–720：保存禁用并给出范围提示', (tester) async {
      final repo = _FakeAgentRepo(automations: [_automation()]);
      await tester.pumpWidget(_automationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每天'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '999');
      await tester.pumpAndSettle();
      expect(find.text('请填写 1–720 之间的小时数'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('360 / 1200 / 1440 宽无 overflow', (tester) async {
      final repo = _FakeAgentRepo(
        automations: [
          for (final (i, kind) in AgentAutomationKind.values.indexed)
            _automation(
              id: 'auto_$i',
              kind: kind,
              lastRunAt: '2026-07-28T02:00:00Z',
              lastStatus: i.isEven
                  ? AgentAutomationRunStatus.success
                  : AgentAutomationRunStatus.failed,
            ),
        ],
      );
      for (final width in [360.0, 1200.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_automationsHost(repo));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width=$width');
      }
    });
  });

  group('通知', () {
    testWidgets('无通知：入口完全不显示', (tester) async {
      await tester.pumpWidget(_notificationsHost(_FakeAgentRepo()));
      await tester.pumpAndSettle();
      expect(find.textContaining('通知'), findsNothing);
    });

    testWidgets('未读数只在入口上显示；列表 newest-first 展示标题/正文/时间', (tester) async {
      await tester.pumpWidget(
        _notificationsHost(
          _FakeAgentRepo(
            notifications: [
              _notification(id: 'note_1'),
              _notification(
                id: 'note_2',
                title: '报价已刷新',
                body: '',
                action: AgentNotificationAction.quotes,
                readAt: '2026-07-28T10:00:00Z',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('通知 1'), findsOneWidget);
      await tester.tap(find.text('通知 1'));
      await tester.pumpAndSettle();
      final tiles = find.byType(ListTile);
      expect(tiles, findsNWidgets(2));
      expect(find.text('订阅到期扫描完成'), findsOneWidget);
      expect(find.text('生成了 2 条待确认扣费'), findsOneWidget);
      expect(find.textContaining('2026-07-28'), findsWidgets);
      // newest-first 由服务端保证：第一条就是列表里的第一条。
      expect(
        tester.getTopLeft(tiles.first).dy,
        lessThan(tester.getTopLeft(tiles.last).dy),
      );
    });

    testWidgets('打开一条：标记已读并按 action 去审核', (tester) async {
      final repo = _FakeAgentRepo(notifications: [_notification()]);
      await tester.pumpWidget(_notificationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('订阅到期扫描完成'));
      await tester.pumpAndSettle();
      expect(repo.reads, ['note_1']);
      expect(find.text('review-page'), findsOneWidget);
    });

    testWidgets('已读的不再重复标记（幂等）', (tester) async {
      final repo = _FakeAgentRepo(
        notifications: [
          _notification(
            action: AgentNotificationAction.agent,
            readAt: '2026-07-28T10:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(_notificationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('订阅到期扫描完成'));
      await tester.pumpAndSettle();
      expect(repo.reads, isEmpty);
    });

    testWidgets('action=dca 去投资页', (tester) async {
      final repo = _FakeAgentRepo(
        notifications: [
          _notification(
            kind: AgentAutomationKind.dcaDueCheck,
            title: '定投到期',
            action: AgentNotificationAction.dca,
          ),
        ],
      );
      await tester.pumpWidget(_notificationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定投到期'));
      await tester.pumpAndSettle();
      expect(find.text('investment-page'), findsOneWidget);
    });

    testWidgets('财务总结 action=agent：不写成"报告已完成"，只回到会话', (tester) async {
      final repo = _FakeAgentRepo(
        notifications: [
          _notification(
            kind: AgentAutomationKind.financialSummary,
            title: '本周财务总结',
            body: '净资产较上周 +1.2%',
            action: AgentNotificationAction.agent,
          ),
        ],
      );
      await tester.pumpWidget(_notificationsHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('报告已完成'), findsNothing);
      expect(find.textContaining('排队'), findsNothing);
      await tester.tap(find.text('本周财务总结'));
      await tester.pumpAndSettle();
      expect(repo.reads, ['note_1']);
      expect(find.byType(AgentNotificationSheet), findsNothing);
    });

    testWidgets('360 / 1200 / 1440 宽通知列表无 overflow', (tester) async {
      final repo = _FakeAgentRepo(
        notifications: [
          for (var i = 0; i < 8; i += 1)
            _notification(
              id: 'note_$i',
              title: '订阅到期扫描完成（第 $i 次）',
              body: '生成了 2 条待确认扣费，可以去审核里逐条确认',
            ),
        ],
      );
      for (final width in [360.0, 1200.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_notificationsHost(repo));
        await tester.pumpAndSettle();
        await tester.tap(find.text('通知 8'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width=$width');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    });
  });
}
