// 订阅 UI：只读 gating、409 可恢复动作、候选成功只显示「待确认」、
// 列表四态、手机/宽屏无 overflow。
import 'dart:async';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart'
    show ApiConflictException;
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/subscription_detail_page.dart';
import 'package:finwealth/features/subscriptions_page.dart';
import 'package:finwealth/shared/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _canManage = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
  canManageSubscriptions: true,
);

SubscriptionVm _sub({
  String id = 'sub_1',
  SubscriptionStatus status = SubscriptionStatus.active,
  bool pending = false,
}) => SubscriptionVm(
  id: id,
  displayName: 'ChatGPT Plus',
  provider: 'OpenAI',
  planName: 'Plus',
  amount: const Money(amount: '20.00', currency: 'USD'),
  paymentAccountId: 'acct_us',
  billingCycle: const SubscriptionBillingCycleVm(
    unit: BillingUnit.month,
    interval: 1,
  ),
  billingAnchorDay: 5,
  startDate: '2026-01-05',
  nextChargeDate: '2026-08-05',
  autoRenew: true,
  reminderDaysBefore: 3,
  status: status,
  pendingChargeMovementId: pending ? 'mov_p1' : null,
  pendingChargeDate: pending ? '2026-08-05' : null,
);

const _account = AccountVm(
  id: 'acct_us',
  displayName: '美股券商',
  accountType: AccountType.brokerage,
  isLiability: false,
  defaultCurrency: 'USD',
);

class _FakeSubRepo implements SubscriptionRepository {
  _FakeSubRepo({this.onCharge, this.onCancel, this.onScan});
  final Future<AiAtomicGroupVm> Function()? onCharge;
  final Future<SubscriptionVm> Function()? onCancel;
  final Future<SubscriptionDueScanResultVm> Function()? onScan;

  @override
  Future<AiAtomicGroupVm> createChargeProposal(Id id) =>
      onCharge?.call() ?? (throw UnsupportedError('no charge'));
  @override
  Future<SubscriptionVm> cancelSubscription(Id id) =>
      onCancel?.call() ?? (throw UnsupportedError('no cancel'));
  @override
  Future<SubscriptionDueScanResultVm> scanDueChargeProposals({
    required IsoDate throughDate,
    int limit = 100,
  }) => onScan?.call() ?? (throw UnsupportedError('no scan'));
  @override
  Future<List<SubscriptionVm>> listSubscriptions() async => const [];
  @override
  Future<List<SubscriptionVm>> listUpcomingSubscriptions({
    int days = 30,
  }) async => const [];
  @override
  Future<SubscriptionVm> getSubscription(Id id) async => _sub();
  @override
  Future<SubscriptionVm> createSubscription(CreateSubscriptionInput i) async =>
      throw UnsupportedError('no create');
  @override
  Future<SubscriptionVm> updateSubscription(
    Id id,
    UpdateSubscriptionInput i,
  ) async => throw UnsupportedError('no update');
}

AiAtomicGroupVm _chargeGroup() => const AiAtomicGroupVm(
  id: 'ag_charge_1',
  title: '订阅扣费：ChatGPT Plus',
  operation: AiOperation.create,
  status: AiGroupStatus.pending,
);

SubscriptionDueScanResultVm _scanResult({
  int created = 0,
  int alreadyPending = 0,
  int blocked = 0,
  int remaining = 0,
  bool hasMore = false,
  List<SubscriptionDueScanSkipVm> skipped = const [],
}) => SubscriptionDueScanResultVm(
  throughDate: '2026-07-13',
  createdCount: created,
  alreadyPendingCount: alreadyPending,
  blockedCount: blocked,
  remainingEligibleCount: remaining,
  hasMore: hasMore,
  skipped: skipped,
);

// flutter_riverpod 3.x 未公开导出 Override 类型：用 dynamic 承接列表字面量（元素推断为 Override）。
Widget _app(Widget page, {required dynamic overrides}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(home: page),
);

// 拉高视口，让详情页 ListView 把底部动作全部渲染出来（否则在 600 高下越界不可点）。
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('cat10: 列表四态', () {
    testWidgets('data 显示订阅', (tester) async {
      await tester.pumpWidget(
        _app(
          const SubscriptionsPage(),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            subscriptionsProvider.overrideWith((ref) async => [_sub()]),
            upcomingSubscriptionsProvider.overrideWith((ref) async => const []),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ChatGPT Plus'), findsWidgets);
    });

    testWidgets('empty 显示空态', (tester) async {
      await tester.pumpWidget(
        _app(
          const SubscriptionsPage(),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            subscriptionsProvider.overrideWith((ref) async => const []),
            upcomingSubscriptionsProvider.overrideWith((ref) async => const []),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('还没有订阅'), findsOneWidget);
    });

    testWidgets('loading 显示骨架', (tester) async {
      await tester.pumpWidget(
        _app(
          const SubscriptionsPage(),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            subscriptionsProvider.overrideWith(
              (ref) => Completer<List<SubscriptionVm>>().future,
            ),
            upcomingSubscriptionsProvider.overrideWith((ref) async => const []),
          ],
        ),
      );
      await tester.pump(); // 不 settle，停在 loading
      expect(find.byType(ListSkeleton), findsOneWidget);
    });

    testWidgets('error 显示错误态', (tester) async {
      await tester.pumpWidget(
        _app(
          const SubscriptionsPage(),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            subscriptionsProvider.overrideWith(
              (ref) async => throw Exception('boom'),
            ),
            upcomingSubscriptionsProvider.overrideWith((ref) async => const []),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorStateView), findsOneWidget);
    });
  });

  group('cat7: 只读模式禁用写入口', () {
    testWidgets('locked 时列表「新建」按钮禁用', (tester) async {
      await tester.pumpWidget(
        _app(
          const SubscriptionsPage(),
          overrides: [
            capabilitiesProvider.overrideWith(
              (ref) async => LedgerCapabilitiesVm.locked,
            ),
            subscriptionsProvider.overrideWith((ref) async => [_sub()]),
            upcomingSubscriptionsProvider.overrideWith((ref) async => const []),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final btn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('locked 时详情动作被 WriteGate 吸收', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(
        _app(
          const SubscriptionDetailPage(subscriptionId: 'sub_1'),
          overrides: [
            capabilitiesProvider.overrideWith(
              (ref) async => LedgerCapabilitiesVm.locked,
            ),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前数据源只读'), findsOneWidget);
      // WriteGate 的 AbsorbPointer(absorbing:true) 吸收动作点击（另有按钮内部一个非吸收的）。
      expect(
        find.ancestor(
          of: find.text('记录本期扣费'),
          matching: find.byWidgetPredicate(
            (w) => w is AbsorbPointer && w.absorbing,
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('cat9: 候选成功只显示「待确认」', () {
    testWidgets('记录本期扣费成功文案不含已扣款/已入账', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(
        _app(
          const SubscriptionDetailPage(subscriptionId: 'sub_1'),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub()),
            subscriptionRepositoryProvider.overrideWithValue(
              _FakeSubRepo(onCharge: () async => _chargeGroup()),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录本期扣费'));
      await tester.pump(); // 显示 SnackBar
      expect(find.textContaining('已生成待确认扣费'), findsOneWidget);
      expect(find.textContaining('已扣款'), findsNothing);
      expect(find.textContaining('已入账'), findsNothing);
    });
  });

  group('cat8: 409 显示可恢复动作', () {
    testWidgets('重复候选 409 提示「本期已有待确认扣费」并给去审核入口', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(
        _app(
          const SubscriptionDetailPage(subscriptionId: 'sub_1'),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub()),
            subscriptionRepositoryProvider.overrideWithValue(
              _FakeSubRepo(
                onCharge: () async =>
                    throw ApiConflictException('/charge-proposal'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录本期扣费'));
      await tester.pump();
      expect(find.textContaining('本期已有待确认扣费'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '前往审核'), findsOneWidget);
    });

    testWidgets('取消冲突 409 提示先确认或拒绝', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(
        _app(
          const SubscriptionDetailPage(subscriptionId: 'sub_1'),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub()),
            subscriptionRepositoryProvider.overrideWithValue(
              _FakeSubRepo(
                onCancel: () async => throw ApiConflictException('/cancel'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消订阅'));
      await tester.pumpAndSettle(); // 弹确认对话框
      await tester.tap(find.text('取消未来扣费'));
      await tester.pump();
      expect(find.textContaining('请先在 AI 审核'), findsOneWidget);
    });
  });

  group('cat12: pending 时取消门控（本地禁用，非 409 兜底）', () {
    OutlinedButton cancelButton(WidgetTester tester) =>
        tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('取消订阅'),
            // OutlinedButton.icon 实际是私有子类，byType 精确匹配不到，用 is 判断。
            matching: find.byWidgetPredicate((w) => w is OutlinedButton),
          ),
        );

    testWidgets('pending 时取消按钮禁用：不弹确认框、不调用 Repository', (tester) async {
      var cancelCalls = 0;
      _tallView(tester);
      await tester.pumpWidget(
        _app(
          const SubscriptionDetailPage(subscriptionId: 'sub_1'),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub(pending: true)),
            subscriptionRepositoryProvider.overrideWithValue(
              _FakeSubRepo(
                onCancel: () async {
                  cancelCalls += 1;
                  return _sub(status: SubscriptionStatus.cancelled);
                },
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(cancelButton(tester).onPressed, isNull);
      await tester.tap(find.text('取消订阅'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('取消未来扣费'), findsNothing); // 无确认对话框
      expect(cancelCalls, 0);
      // 恢复路径仍在：顶部待确认提示条的「前往审核」。
      expect(find.text('前往审核'), findsWidgets);
    });

    testWidgets('无 pending 的可排期订阅取消仍可用', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(
        _app(
          const SubscriptionDetailPage(subscriptionId: 'sub_1'),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub()),
            subscriptionRepositoryProvider.overrideWithValue(_FakeSubRepo()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(cancelButton(tester).onPressed, isNotNull);
    });
  });

  group('cat14: 到期扫描入口', () {
    Finder scanButton() => find.widgetWithIcon(IconButton, Icons.manage_search);

    Future<void> pumpList(
      WidgetTester tester, {
      required SubscriptionRepository repo,
      LedgerCapabilitiesVm caps = _canManage,
    }) async {
      await tester.pumpWidget(
        _app(
          const SubscriptionsPage(),
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => caps),
            subscriptionsProvider.overrideWith((ref) async => [_sub()]),
            upcomingSubscriptionsProvider.overrideWith((ref) async => const []),
            subscriptionRepositoryProvider.overrideWithValue(repo),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('只读能力下扫描按钮禁用', (tester) async {
      await pumpList(
        tester,
        repo: _FakeSubRepo(),
        caps: LedgerCapabilitiesVm.locked,
      );
      expect(tester.widget<IconButton>(scanButton()).onPressed, isNull);
    });

    testWidgets('created 结果显示数量与「前往审核」', (tester) async {
      await pumpList(
        tester,
        repo: _FakeSubRepo(onScan: () async => _scanResult(created: 2)),
      );
      await tester.tap(scanButton());
      await tester.pumpAndSettle();
      expect(find.text('已生成 2 个待确认扣费'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '前往审核'), findsOneWidget);
      expect(find.textContaining('已扣款'), findsNothing);
    });

    testWidgets('already-pending/blocked 结果不出现「已扣款」，blocked 显示名称与原因', (
      tester,
    ) async {
      await pumpList(
        tester,
        repo: _FakeSubRepo(
          onScan: () async => _scanResult(
            alreadyPending: 1,
            blocked: 1,
            skipped: const [
              SubscriptionDueScanSkipVm(
                subscriptionId: 'sub_2',
                scheduledChargeDate: '2026-07-01',
                reason: SubscriptionDueScanSkipReason.alreadyPending,
              ),
              SubscriptionDueScanSkipVm(
                subscriptionId: 'sub_1',
                scheduledChargeDate: '2026-07-02',
                reason: SubscriptionDueScanSkipReason.paymentAccountUnavailable,
              ),
            ],
          ),
        ),
      );
      await tester.tap(scanButton());
      await tester.pumpAndSettle();
      expect(find.text('本次没有生成新的扣费候选。'), findsOneWidget);
      expect(find.textContaining('已在审核队列 1 个'), findsOneWidget);
      // blocked 项映射为名称 + 日期 + 中文可恢复原因。
      expect(
        find.textContaining('ChatGPT Plus · 计划 2026-07-02'),
        findsOneWidget,
      );
      expect(find.textContaining('付款账户缺失或已归档'), findsOneWidget);
      expect(find.textContaining('已扣款'), findsNothing);
      expect(find.textContaining('已入账'), findsNothing);
    });

    testWidgets('busy 状态不能重复发起扫描', (tester) async {
      var scanCalls = 0;
      final gate = Completer<SubscriptionDueScanResultVm>();
      await pumpList(
        tester,
        repo: _FakeSubRepo(
          onScan: () {
            scanCalls += 1;
            return gate.future;
          },
        ),
      );
      await tester.tap(scanButton());
      await tester.pump();
      // 请求进行中：图标被进度圈替换，按钮禁用。
      final busyButton = find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(busyButton).onPressed, isNull);
      await tester.tap(busyButton, warnIfMissed: false);
      await tester.pump();
      expect(scanCalls, 1);
      gate.complete(_scanResult());
      await tester.pumpAndSettle();
      expect(find.textContaining('没有需要生成的到期扣费'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(scanCalls, 1);
    });

    testWidgets('hasMore 显示剩余数量，「再次扫描」再跑一轮', (tester) async {
      var scanCalls = 0;
      await pumpList(
        tester,
        repo: _FakeSubRepo(
          onScan: () async {
            scanCalls += 1;
            return scanCalls == 1
                ? _scanResult(created: 1, remaining: 3, hasMore: true)
                : _scanResult(created: 1);
          },
        ),
      );
      await tester.tap(scanButton());
      await tester.pumpAndSettle();
      expect(find.textContaining('还有 3 个到期订阅本次未生成'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '再次扫描'));
      await tester.pumpAndSettle();
      expect(scanCalls, 2);
      // 第二轮结果没有 hasMore：不再提供「再次扫描」。
      expect(find.widgetWithText(OutlinedButton, '再次扫描'), findsNothing);
      expect(find.text('已生成 1 个待确认扣费'), findsOneWidget);
    });
  });

  group('cat11: 手机与宽屏无 overflow', () {
    Future<void> pumpAt(WidgetTester tester, Size size, Widget page) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          page,
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _canManage),
            accountsProvider.overrideWith((ref) async => const [_account]),
            subscriptionsProvider.overrideWith(
              (ref) async => [_sub(), _sub(id: 'sub_2', pending: true)],
            ),
            upcomingSubscriptionsProvider.overrideWith((ref) async => [_sub()]),
            subscriptionByIdProvider(
              'sub_1',
            ).overrideWith((ref) async => _sub(pending: true)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    testWidgets('列表页 手机 360 与宽屏 1200', (tester) async {
      await pumpAt(tester, const Size(360, 800), const SubscriptionsPage());
      await pumpAt(tester, const Size(1200, 800), const SubscriptionsPage());
    });

    testWidgets('详情页 手机 360 与宽屏 1200', (tester) async {
      await pumpAt(
        tester,
        const Size(360, 800),
        const SubscriptionDetailPage(subscriptionId: 'sub_1'),
      );
      await pumpAt(
        tester,
        const Size(1200, 800),
        const SubscriptionDetailPage(subscriptionId: 'sub_1'),
      );
    });
  });
}
