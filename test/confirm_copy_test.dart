// 录入确认文案只凭服务端 ConfirmResultVm.ledgerWrite：
// ledgerWrite=false 时不得显示「已入账」，避免在未真正入账时误导用户。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/manual_record_page.dart';

class _FakeMovementRepo implements MovementRepository {
  _FakeMovementRepo(this.result);
  final ConfirmResultVm result;

  @override
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input) async =>
      result;
  @override
  Future<ConfirmResultVm> createTransfer(TransferInput input) async => result;
  @override
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input) async =>
      result;
  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) async {}
  @override
  Future<ConfirmResultVm> createInvestmentTrade(
    InvestmentTradeInput input,
  ) async => result;
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      const [];
  @override
  Future<MovementVm?> getMovement(Id id) async => null;
}

Widget _host(ConfirmResultVm result) => ProviderScope(
  overrides: [
    accountsProvider.overrideWith(
      (ref) async => const [
        AccountVm(
          id: 'a1',
          displayName: '钱包',
          accountType: AccountType.bank,
          isLiability: false,
          defaultCurrency: 'CNY',
          cashBalances: {},
        ),
      ],
    ),
    categoriesProvider.overrideWith((ref) async => const <CategoryVm>[]),
    counterpartiesProvider.overrideWith(
      (ref) async => const <CounterpartyVm>[],
    ),
    movementRepositoryProvider.overrideWithValue(_FakeMovementRepo(result)),
  ],
  // ManualRecordPage._save 依赖 GoRouter；提供最小路由环境。
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const ManualRecordPage())],
    ),
  ),
);

Future<void> _submit(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, '金额'), '18');
  await tester.enterText(find.widgetWithText(TextField, '摘要'), '午餐');
  await tester.pump();
  // 「记一笔」在表单底部，先滚动到可见。
  await tester.dragUntilVisible(
    find.widgetWithText(FilledButton, '记一笔'),
    find.byType(ListView),
    const Offset(0, -300),
  );
  await tester.tap(find.widgetWithText(FilledButton, '记一笔'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认入账'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ledgerWrite=true 显示「已入账」', (tester) async {
    await tester.pumpWidget(
      _host(
        const ConfirmResultVm(
          atomicGroupId: 'ag_1',
          confirmedMovementIds: ['mov_1'],
          snapshotInvalidated: true,
          ledgerWrite: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(find.text('已入账'), findsOneWidget);
  });

  testWidgets('ledgerWrite=false 显示候选提示而非「已入账」', (tester) async {
    await tester.pumpWidget(
      _host(
        const ConfirmResultVm(
          atomicGroupId: 'ag_1',
          confirmedMovementIds: [],
          snapshotInvalidated: false,
          ledgerWrite: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(find.text('已入账'), findsNothing);
    expect(find.text('已提交候选，尚未入账'), findsOneWidget);
  });
}
