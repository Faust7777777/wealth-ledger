// Capability gating 与确认结果消费的回归测试（2026-07-06 前端交接清单）。
// 1) 写入口只凭服务端 capabilities 显示/禁用（fail-closed）；
// 2) AI approve / 录入确认文案只凭 ConfirmResultVm.ledgerWrite，不得前端猜测。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/accounts_page.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:finwealth/features/record_sheet.dart';
import 'package:finwealth/features/taxonomy_page.dart';

const _writable = LedgerCapabilitiesVm(
  dataSourceMode: 'real_local',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

// flutter_riverpod 3.3.2 未公开导出 Override 类型，这里用命名参数 + 列表字面量推断。
Widget _app(
  Widget page, {
  required LedgerCapabilitiesVm caps,
  List<AccountVm>? accounts,
  List<AiProposalVm>? pending,
  AiProposalRepository? aiRepo,
}) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => caps),
    if (accounts != null)
      accountsProvider.overrideWith((ref) async => accounts),
    if (pending != null) aiPendingProvider.overrideWith((ref) async => pending),
    if (aiRepo != null) aiProposalRepositoryProvider.overrideWithValue(aiRepo),
  ],
  child: MaterialApp(home: page),
);

class _FakeAiRepo implements AiProposalRepository {
  _FakeAiRepo(this.result);
  final ConfirmResultVm result;

  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) async => result;
  @override
  Future<List<AiProposalVm>> listPending() async => const [];
  @override
  Future<AiProposalVm?> getProposal(Id id) async => null;
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {}
  @override
  Future<void> createFromText(String text) async {}
  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) async {}
  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) async {}
  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) async {}
}

AiProposalVm _pendingProposal() => const AiProposalVm(
  id: 'proposal_1',
  status: AiProposalStatus.pending,
  sourceLabel: '文本输入',
  summary: '测试提案',
  groups: [
    AiAtomicGroupVm(
      id: 'ag_1',
      title: '测试组',
      operation: AiOperation.create,
      status: AiGroupStatus.pending,
      // 结构化候选才有「接受整组」；无 movement 的组走待补全门控。
      proposedMovement: MovementVm(
        id: 'mov_g1',
        atomicGroupId: 'ag_1',
        type: MovementType.expense,
        status: MovementStatus.pendingReview,
        title: '测试支出',
        occurredAt: '2026-07-19T12:00:00Z',
        displayAmount: Money(amount: '18.00', currency: 'CNY'),
      ),
    ),
  ],
);

void main() {
  group('parseLedgerCapabilitiesData', () {
    test('解析完整 capabilities', () {
      final caps = parseLedgerCapabilitiesData(const {
        'dataSourceMode': 'real_local',
        'canWriteConfirmedLedger': true,
        'canCreateAccount': true,
        'canRecordMovement': true,
        'canConfirmProposal': true,
        'canPersistPendingProposal': true,
        'proposalPersistence': 'file',
      });
      expect(caps.dataSourceMode, 'real_local');
      expect(caps.canWriteConfirmedLedger, isTrue);
      expect(caps.canCreateAccount, isTrue);
      expect(caps.canRecordMovement, isTrue);
      expect(caps.canConfirmProposal, isTrue);
      expect(caps.canPersistPendingProposal, isTrue);
      expect(caps.proposalPersistence, 'file');
    });

    test('字段缺失时 fail-closed 全 false', () {
      final caps = parseLedgerCapabilitiesData(const {});
      expect(caps.canWriteConfirmedLedger, isFalse);
      expect(caps.canCreateAccount, isFalse);
      expect(caps.canRecordMovement, isFalse);
      expect(caps.canConfirmProposal, isFalse);
      expect(caps.canPersistPendingProposal, isFalse);
      expect(caps.proposalPersistence, 'none');
    });
  });

  group('AccountsPage 写入口 gating', () {
    testWidgets('无 canCreateAccount 时空态「添加账户」禁用并给出原因', (tester) async {
      await tester.pumpWidget(
        _app(
          const AccountsPage(),
          caps: LedgerCapabilitiesVm.locked,
          accounts: const [],
        ),
      );
      await tester.pumpAndSettle();

      // WriteGate 用 AbsorbPointer 吸收点击并显示原因文案。
      expect(find.textContaining('当前为只读模式'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(FilledButton),
          matching: find.byType(AbsorbPointer),
        ),
        findsWidgets,
      );
      // 点击被吸收：无路由环境下不抛错即证明 onPressed 未执行。
      await tester.tap(find.text('添加账户'), warnIfMissed: false);
      await tester.pump();
    });

    testWidgets('有 canCreateAccount 时「添加账户」可用', (tester) async {
      await tester.pumpWidget(
        _app(const AccountsPage(), caps: _writable, accounts: const []),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNotNull);
      expect(find.textContaining('当前为只读模式'), findsNothing);
    });
  });

  group('记录 sheet 条目 gating', () {
    Widget sheetHost(LedgerCapabilitiesVm caps) => _app(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showRecordSheet(context, caps),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
      caps: caps,
    );

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
    }

    ListTile tileOf(WidgetTester tester, String label) => tester.widget(
      find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
    );

    testWidgets('locked 时全部条目禁用', (tester) async {
      await tester.pumpWidget(sheetHost(LedgerCapabilitiesVm.locked));
      await openSheet(tester);

      for (final label in ['手动记账', '转账', '余额观察', 'AI 文本导入']) {
        expect(tileOf(tester, label).enabled, isFalse, reason: label);
      }
      expect(find.textContaining('当前为只读模式'), findsOneWidget);
    });

    testWidgets('只可持久化候选时记账禁用、AI 导入可用（dev server 形态）', (tester) async {
      const devCaps = LedgerCapabilitiesVm(
        dataSourceMode: 'dev_empty',
        canWriteConfirmedLedger: false,
        canCreateAccount: false,
        canRecordMovement: false,
        canConfirmProposal: true,
        canPersistPendingProposal: true,
        proposalPersistence: 'memory',
      );
      await tester.pumpWidget(sheetHost(devCaps));
      await openSheet(tester);

      expect(tileOf(tester, '手动记账').enabled, isFalse);
      expect(tileOf(tester, '转账').enabled, isFalse);
      expect(tileOf(tester, 'AI 文本导入').enabled, isTrue);
      expect(tileOf(tester, 'CSV 导入').enabled, isTrue);
    });

    testWidgets('全可写时全部条目可用', (tester) async {
      await tester.pumpWidget(sheetHost(_writable));
      await openSheet(tester);

      for (final label in ['手动记账', '转账', '余额观察', 'AI 文本导入', 'CSV 导入', '图片导入']) {
        expect(tileOf(tester, label).enabled, isTrue, reason: label);
      }
    });
  });

  group('TaxonomyPage 写入口 gating', () {
    testWidgets('locked 时创建/合并卡禁用并给出原因、词表条目不可编辑', (tester) async {
      // 拉高视口，让 ListView 渲染出全部三张卡。
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(const TaxonomyPage(), caps: LedgerCapabilitiesVm.locked),
      );
      await tester.pumpAndSettle();

      // 分类创建卡 + 对手方创建卡 + 合并卡，共 3 处 WriteGate 原因文案。
      expect(find.textContaining('当前为只读模式'), findsNWidgets(3));
    });
  });

  group('AI approve 文案只凭 ledgerWrite', () {
    Future<void> pumpAndApprove(
      WidgetTester tester,
      ConfirmResultVm result,
    ) async {
      await tester.pumpWidget(
        _app(
          const AiReviewPage(),
          caps: _writable,
          pending: [_pendingProposal()],
          aiRepo: _FakeAiRepo(result),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('接受整组'));
      await tester.pumpAndSettle();
    }

    testWidgets('ledgerWrite=true 显示「已入账」', (tester) async {
      await pumpAndApprove(
        tester,
        const ConfirmResultVm(
          atomicGroupId: 'ag_1',
          confirmedMovementIds: ['mov_1'],
          snapshotInvalidated: true,
          ledgerWrite: true,
        ),
      );
      expect(find.textContaining('已入账'), findsOneWidget);
    });

    testWidgets('ledgerWrite=false 不得显示「已入账」', (tester) async {
      await pumpAndApprove(
        tester,
        const ConfirmResultVm(
          atomicGroupId: 'ag_1',
          confirmedMovementIds: [],
          snapshotInvalidated: false,
          ledgerWrite: false,
        ),
      );
      expect(find.textContaining('已入账'), findsNothing);
      expect(find.textContaining('尚未入账'), findsOneWidget);
    });

    testWidgets('无 canConfirmProposal 时「接受整组」禁用', (tester) async {
      await tester.pumpWidget(
        _app(
          const AiReviewPage(),
          caps: LedgerCapabilitiesVm.locked,
          pending: [_pendingProposal()],
          aiRepo: _FakeAiRepo(
            const ConfirmResultVm(
              atomicGroupId: 'ag_1',
              confirmedMovementIds: [],
              snapshotInvalidated: false,
              ledgerWrite: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('接受整组'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}
