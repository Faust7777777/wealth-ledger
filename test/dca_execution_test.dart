// DCA 真实成交记录：映射五字段/幂等/401 重放、表单先行、账户过滤、
// 数量与成本校验、无账户不发请求、busy 防重复、成功刷新四 provider、
// 409 不伪造成功、桌面尺寸受限（2026-07-16 任务单 §5）。
import 'dart:async';
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/dca_execution_dialog.dart';
import 'package:finwealth/features/investment_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

const _reminder = DcaReminderVm(
  id: 'rem_1',
  planId: 'plan_1',
  displayName: '沪深300ETF',
  plannedAmount: Money(amount: '200.00', currency: 'CNY'),
  dueDate: '2026-07-16',
  status: DcaReminderStatus.due,
);

AccountVm _acct(
  String id,
  String name,
  String mode, {
  bool archived = false,
  String currency = 'CNY',
}) => AccountVm(
  id: id,
  displayName: name,
  accountType: AccountType.brokerage,
  isLiability: mode == 'liability',
  balanceMode: mode,
  isArchived: archived,
  defaultCurrency: currency,
);

final _accounts = [
  _acct('a_hold', '美股券商', 'holdings', currency: 'USD'),
  _acct('a_mixed', '混合老账户', 'mixed'),
  _acct('a_cash', '招行储蓄卡', 'cash_balance'),
  _acct('a_liab', '房贷', 'liability'),
  _acct('a_gone', '已归档券商', 'holdings', archived: true),
];

const _overview = PortfolioOverviewVm(
  pendingSummary: PendingSummaryVm(),
  quoteStatusSummary: QuoteStatusSummaryVm(),
  primaryHoldings: [],
  recentMovements: [],
);

/// 捕获真实 HTTP 映射的 DCA 仓库。
({DcaRepository repo, List<http.Request> requests}) _capturingRepo({
  int failStatus = 0,
}) {
  final requests = <http.Request>[];
  final client = DevApiClient(
    'http://127.0.0.1:1',
    client: MockClient((req) async {
      requests.add(req);
      if (failStatus == 409) {
        return http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'pending_exists', 'message': '本期已有待确认记录'},
          }),
          409,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {
            'id': 'ag_dca_1',
            'title': '定投成交',
            'operation': 'create',
            'status': 'pending',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return (repo: LocalServerDcaRepository(client), requests: requests);
}

const _execInput = DcaExecutionInput(
  holdingAccountId: 'a_hold',
  quantity: '10',
  totalCost: Money(amount: '200.00', currency: 'CNY'),
  quoteCurrency: 'USD',
  executedAt: '2026-07-16T10:30:00+08:00',
);

/// 投资页宿主：附带两个隐藏 watcher 让 overview/aiPending 的失效可观测。
Widget _host({
  required DcaRepository dcaRepo,
  List<DcaReminderVm> Function()? reminders,
  List<AccountVm> accounts = const [],
  void Function()? onOverview,
  void Function()? onAiPending,
}) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    holdingsProvider.overrideWith((ref) async => const <HoldingVm>[]),
    dcaPlansProvider.overrideWith((ref) async => const <DcaPlanVm>[]),
    dueRemindersProvider.overrideWith(
      (ref) async => reminders?.call() ?? const [_reminder],
    ),
    accountsProvider.overrideWith((ref) async => accounts),
    dcaRepositoryProvider.overrideWithValue(dcaRepo),
    overviewProvider.overrideWith((ref) async {
      onOverview?.call();
      return _overview;
    }),
    aiPendingProvider.overrideWith((ref) async {
      onAiPending?.call();
      return const <AiProposalVm>[];
    }),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          // 隐藏 watcher：让 overview / aiPending 的 invalidate 触发重算。
          Consumer(
            builder: (_, ref, _) {
              ref.watch(overviewProvider);
              ref.watch(aiPendingProvider);
              return const SizedBox.shrink();
            },
          ),
          const Expanded(child: InvestmentPage()),
        ],
      ),
    ),
  ),
);

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('记录已执行'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextField, label), value);
  await tester.pump();
}

FilledButton _confirmButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.ancestor(
    of: find.text('确认记录'),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  ),
);

void main() {
  group('repository 映射', () {
    test('1. 五字段完全正确 + 幂等键；数量与总成本不同', () async {
      final h = _capturingRepo();
      await h.repo.markExecutedAsProposal('rem_1', _execInput);
      final req = h.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/dca/reminders/rem_1/mark-executed-as-proposal');
      expect(jsonDecode(req.body), {
        'holdingAccountId': 'a_hold',
        'quantity': '10',
        'totalCost': {'amount': '200.00', 'currency': 'CNY'},
        'quoteCurrency': 'USD',
        'executedAt': '2026-07-16T10:30:00+08:00',
      });
      expect(
        req.headers['idempotency-key'],
        matches(RegExp(r'^[0-9a-f]{32}$')),
      );
    });

    test('2. quantity=10 时 body 不会把 200 写进 quantity；executedAt 可省略', () async {
      final h = _capturingRepo();
      await h.repo.markExecutedAsProposal(
        'rem_1',
        const DcaExecutionInput(
          holdingAccountId: 'a_hold',
          quantity: '10',
          totalCost: Money(amount: '200.00', currency: 'CNY'),
          quoteCurrency: 'CNY',
        ),
      );
      final body = jsonDecode(h.requests.single.body) as Map<String, dynamic>;
      expect(body['quantity'], '10');
      expect(body['quantity'], isNot('200.00'));
      expect(body['totalCost']['amount'], '200.00');
      expect(body.containsKey('executedAt'), isFalse);
    });

    test('3. 401 refresh 重放复用同一幂等键', () async {
      final store = MemoryAuthTokenStore();
      await store.write(
        const StoredAuthSession(
          accessToken: 'access_expired',
          refreshToken: 'refresh_old',
          expiresAt: '2026-07-16T12:00:00+08:00',
          deviceId: 'device_1',
        ),
      );
      final businessKeys = <String>[];
      final client = DevApiClient(
        'http://127.0.0.1:1',
        tokenStore: store,
        client: MockClient((req) async {
          if (req.url.path == '/v1/auth/refresh') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {
                  'accessToken': 'access_new',
                  'refreshToken': 'refresh_new',
                  'expiresAt': '2026-07-16T13:00:00+08:00',
                  'deviceId': 'device_1',
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          final k = req.headers['idempotency-key'];
          if (k != null) businessKeys.add(k);
          if (req.headers['authorization'] == 'Bearer access_expired') {
            return http.Response(jsonEncode({'ok': false}), 401);
          }
          return http.Response(
            jsonEncode({'ok': true, 'data': {}}),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await LocalServerDcaRepository(
        client,
      ).markExecutedAsProposal('rem_1', _execInput);
      expect(businessKeys, hasLength(2));
      expect(businessKeys[0], businessKeys[1]);
    });
  });

  group('表单交互', () {
    testWidgets('4. 点击「记录已执行」只打开表单，确认前不发 POST', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      expect(find.text('记录本期成交'), findsOneWidget);
      expect(h.requests, isEmpty);
    });

    testWidgets('5. 持仓账户只列 holdings/mixed 未归档', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await tester.tap(find.text('持仓账户'));
      await tester.pumpAndSettle();
      expect(find.text('美股券商'), findsWidgets);
      expect(find.text('混合老账户'), findsWidgets);
      expect(find.text('招行储蓄卡'), findsNothing);
      expect(find.text('房贷'), findsNothing);
      expect(find.text('已归档券商'), findsNothing);
    });

    testWidgets('6. 数量空/0/负数/超 8 位小数不可提交', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      // 空（初始）：不可提交（总成本已有默认值）。
      expect(_confirmButton(tester).onPressed, isNull);
      for (final bad in ['0', '-5', '1.234567890']) {
        await _enter(tester, '实际数量', bad);
        expect(_confirmButton(tester).onPressed, isNull, reason: '数量=$bad');
      }
      await _enter(tester, '实际数量', '10');
      expect(_confirmButton(tester).onPressed, isNotNull);
    });

    testWidgets('7. 总成本空/0/负数/超 8 位小数不可提交', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await _enter(tester, '实际数量', '10');
      for (final bad in ['', '0', '-1', '0.123456789']) {
        await _enter(tester, '实际总成本', bad);
        expect(_confirmButton(tester).onPressed, isNull, reason: '成本=$bad');
      }
      await _enter(tester, '实际总成本', '200.00');
      expect(_confirmButton(tester).onPressed, isNotNull);
    });

    testWidgets('7b. 成本币种可修改并进入真实 HTTP body', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await _enter(tester, '实际数量', '10');
      await tester.tap(find.byKey(kDcaCostCurrencyFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USD').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认记录'));
      await tester.pumpAndSettle();

      final body = jsonDecode(h.requests.single.body) as Map<String, dynamic>;
      expect(body['totalCost'], {'amount': '200.00', 'currency': 'USD'});
      expect(body['quantity'], '10');
    });

    testWidgets('8. 无可用持仓账户：引导创建、不发请求', (tester) async {
      final h = _capturingRepo();
      await tester.pumpWidget(
        _host(
          dcaRepo: h.repo,
          accounts: [
            _acct('a_cash', '招行储蓄卡', 'cash_balance'),
            _acct('a_gone', '已归档券商', 'holdings', archived: true),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _openDialog(tester);
      expect(find.textContaining('请先创建证券账户或其他投资账户'), findsOneWidget);
      expect(find.text('确认记录'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(h.requests, isEmpty);
    });

    testWidgets('9. busy 期间不能重复提交', (tester) async {
      var calls = 0;
      final gate = Completer<void>();
      final repo = _GatedDcaRepo(() {
        calls += 1;
        return gate.future;
      });
      await tester.pumpWidget(_host(dcaRepo: repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await _enter(tester, '实际数量', '10');
      await tester.tap(find.text('确认记录'));
      await tester.pump();
      await tester.pump();
      // 请求进行中：提醒卡片上的「记录已执行」按钮禁用。
      final recordBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('记录已执行'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(recordBtn.onPressed, isNull);
      await tester.tap(find.text('记录已执行'), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('10. 成功后刷新四类 provider；SnackBar 为待确认语义', (tester) async {
      var overviewRuns = 0;
      var aiRuns = 0;
      var reminderRuns = 0;
      final h = _capturingRepo();
      await tester.pumpWidget(
        _host(
          dcaRepo: h.repo,
          accounts: _accounts,
          reminders: () {
            reminderRuns += 1;
            // 首次有提醒；失效重算后本期消失（已生成候选）。
            return reminderRuns == 1 ? const [_reminder] : const [];
          },
          onOverview: () => overviewRuns += 1,
          onAiPending: () => aiRuns += 1,
        ),
      );
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await _enter(tester, '实际数量', '10');
      await tester.tap(find.text('确认记录'));
      await tester.pumpAndSettle();
      expect(h.requests, hasLength(1));
      expect(find.textContaining('已生成待确认记录'), findsOneWidget);
      expect(find.textContaining('已扣款'), findsNothing);
      // 四类 provider 全部重算：dueReminders/dcaPlans（页面直接观察，
      // 提醒随重算消失）+ overview / aiPending（隐藏 watcher 观察）。
      expect(reminderRuns, 2);
      expect(overviewRuns, 2);
      expect(aiRuns, 2);
      expect(find.text('记录已执行'), findsNothing);
    });

    testWidgets('10b. 409 显示已有待确认，不伪造成功', (tester) async {
      final h = _capturingRepo(failStatus: 409);
      await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await _enter(tester, '实际数量', '10');
      await tester.tap(find.text('确认记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本期已有待确认记录'), findsOneWidget);
      expect(find.textContaining('已生成待确认记录'), findsNothing);
    });

    testWidgets('11. 1200×800 与 1440×900 下弹层受限、无溢出', (tester) async {
      final h = _capturingRepo();
      for (final size in const [Size(1200, 800), Size(1440, 900)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_host(dcaRepo: h.repo, accounts: _accounts));
        await tester.pumpAndSettle();
        await _openDialog(tester);
        final surface = find
            .descendant(
              of: find.byType(DcaExecutionDialog),
              matching: find.byType(Material),
            )
            .first;
        final dialogSize = tester.getSize(surface);
        expect(dialogSize.width, lessThanOrEqualTo(480));
        expect(dialogSize.height, lessThanOrEqualTo(size.height * 0.75));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    });
  });
}

/// 仅 markExecutedAsProposal 可控的 fake（busy 测试用）。
class _GatedDcaRepo implements DcaRepository {
  _GatedDcaRepo(this._onMark);
  final Future<void> Function() _onMark;

  @override
  Future<void> markExecutedAsProposal(Id reminderId, DcaExecutionInput input) =>
      _onMark();
  @override
  Future<List<DcaReminderVm>> listDueReminders() async => const [_reminder];
  @override
  Future<List<DcaPlanVm>> listPlans() async => const [];
  @override
  Future<DcaPlanVm> createPlan(CreateDcaPlanInput input) =>
      throw UnsupportedError('no create');
  @override
  Future<DcaPlanVm> updatePlan(Id planId, UpdateDcaPlanPatch patch) =>
      throw UnsupportedError('no update');
  @override
  Future<void> skipReminder(Id reminderId) => throw UnsupportedError('no skip');
  @override
  Future<void> snoozeReminder(Id reminderId, {required IsoDate until}) =>
      throw UnsupportedError('no snooze');
}
