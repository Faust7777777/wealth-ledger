// 桌面导航密度 + 常驻说明文案清理回归
// （docs/handoffs/2026-07-13-claude-desktop-usability-blocker.md §4）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/app/app.dart';
import 'package:finwealth/app/home_shell.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/manual_record_page.dart';
import 'package:finwealth/features/movement_detail_page.dart';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

const _account = AccountVm(
  id: 'a1',
  displayName: '钱包',
  accountType: AccountType.bank,
  isLiability: false,
  defaultCurrency: 'CNY',
);

MovementVm _movement({required int legs}) => MovementVm(
  id: 'mov_1',
  atomicGroupId: 'ag_1',
  type: legs == 1 ? MovementType.expense : MovementType.transfer,
  status: MovementStatus.confirmed,
  title: legs == 1 ? '瑞幸咖啡' : '钱包 → 储蓄',
  occurredAt: '2026-06-28T09:00:00+08:00',
  displayAmount: const Money(amount: '18.00', currency: 'CNY'),
  entries: [
    const MovementEntryVm(
      accountId: 'a1',
      amount: '18.00',
      currency: 'CNY',
      direction: 'out',
      role: 'source',
    ),
    if (legs > 1)
      const MovementEntryVm(
        accountId: 'a2',
        amount: '18.00',
        currency: 'CNY',
        direction: 'in',
        role: 'destination',
      ),
  ],
);

Future<void> _pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const ProviderScope(child: WealthLedgerApp()));
  await tester.pumpAndSettle();
}

void main() {
  group('桌面记录入口分型', () {
    testWidgets('1200px 折叠 Rail：≤48px 图标钮、无常驻文字、可开记录 sheet', (tester) async {
      await _pumpApp(tester, const Size(1200, 800));
      final action = find.byKey(kDesktopRecordActionKey);
      expect(action, findsOneWidget);
      final size = tester.getSize(action);
      expect(size.width, lessThanOrEqualTo(48));
      expect(size.height, lessThanOrEqualTo(48));
      // 无常驻「记录」文字；tooltip/semantics 存在。
      expect(find.text('记录'), findsNothing);
      expect(find.byTooltip('记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('手动记账'), findsOneWidget); // 记录 sheet 已打开
      expect(tester.takeException(), isNull);
    });

    testWidgets('1440px 扩展 Rail：≤48 高、≤128 宽、显示「记录」', (tester) async {
      await _pumpApp(tester, const Size(1440, 900));
      final action = find.byKey(kDesktopRecordActionKey);
      expect(action, findsOneWidget);
      final size = tester.getSize(action);
      expect(size.height, lessThanOrEqualTo(48));
      expect(size.width, lessThanOrEqualTo(128));
      expect(
        find.descendant(of: action, matching: find.text('记录')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机宽度：原「记录」FAB 仍在且可开记录 sheet', (tester) async {
      await _pumpApp(tester, const Size(400, 800));
      // 手机上「记录」与低强调 Agent 入口同屏；这里只断言记录 FAB。
      final fab = find.widgetWithText(FloatingActionButton, '记录');
      expect(fab, findsOneWidget);
      await tester.tap(fab);
      await tester.pumpAndSettle();
      expect(find.text('手动记账'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('常驻说明文案清理', () {
    testWidgets('ManualRecordPage 不再有产品边界脚注', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            capabilitiesProvider.overrideWith((ref) async => _caps),
            accountsProvider.overrideWith((ref) async => const [_account]),
            categoriesProvider.overrideWith((ref) async => const []),
            counterpartiesProvider.overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(home: ManualRecordPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('不下单'), findsNothing);
      expect(find.textContaining('不连券商'), findsNothing);
      expect(find.textContaining('记账会生成候选并即时确认入账'), findsNothing);
    });

    Widget detailHost(MovementVm m) => ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => _caps),
        accountsProvider.overrideWith((ref) async => const [_account]),
        movementByIdProvider('mov_1').overrideWith((ref) async => m),
      ],
      child: const MaterialApp(home: MovementDetailPage(movementId: 'mov_1')),
    );

    testWidgets('多腿记录：无 MVP 文案、不显示「发起更正」', (tester) async {
      await tester.pumpWidget(detailHost(_movement(legs: 2)));
      await tester.pumpAndSettle();
      expect(find.textContaining('MVP'), findsNothing);
      expect(find.textContaining('后续做'), findsNothing);
      expect(find.text('发起更正'), findsNothing);
    });

    testWidgets('单腿记录：「发起更正」仍存在且可用', (tester) async {
      await tester.pumpWidget(detailHost(_movement(legs: 1)));
      await tester.pumpAndSettle();
      final btn = find.text('发起更正');
      expect(btn, findsOneWidget);
      final outlined = tester.widget<OutlinedButton>(
        find.ancestor(
          of: btn,
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(outlined.onPressed, isNotNull);
    });
  });
}
