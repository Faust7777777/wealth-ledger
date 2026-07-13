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
  _FakeSubRepo({this.onCharge, this.onCancel});
  final Future<AiAtomicGroupVm> Function()? onCharge;
  final Future<SubscriptionVm> Function()? onCancel;

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
  }) => throw UnsupportedError('no scan');
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
