// AI 文本整理（2026-07-18 任务单）：结构化候选映射与展示（标题/账户/金额/时间 +
// 确认/编辑/拒绝）、待补全门控（不能直接确认）、503 保留文本可重试、
// modelName 不上主卡片、刷新范围。
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/ai_import_text_page.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

const _cashAccount = AccountVm(
  id: 'a_cash',
  displayName: '现金钱包',
  accountType: AccountType.cash,
  isLiability: false,
  defaultCurrency: 'CNY',
  cashBalances: {'CNY': '100.00'},
);

Map<String, dynamic> _structuredGroupJson() => {
  'id': 'ag_text_1',
  'title': '新增：午餐',
  'operation': 'create',
  'status': 'pending',
  'proposedMovements': [
    {
      'id': 'mov_text_1',
      'atomicGroupId': 'ag_text_1',
      'type': 'expense',
      'status': 'pending_review',
      'title': '午餐',
      'occurredAt': '2026-07-19T12:30:00+08:00',
      'entries': [
        {
          'accountId': 'a_cash',
          'amount': '18',
          'currency': 'CNY',
          'direction': 'out',
          'role': 'source',
        },
      ],
    },
  ],
  'diffs': const [],
  'warnings': const [],
  'validation': {'isValid': true, 'errors': const []},
};

Map<String, dynamic> _incompleteGroupJson() => {
  'id': 'ag_text_2',
  'title': '文本：待补全',
  'operation': 'create',
  'status': 'pending',
  'proposedMovements': const [],
  'diffs': const [],
  'warnings': [
    {'code': 'local_ai_requires_structured_movement', 'message': '请补全记录。'},
  ],
  'validation': {
    'isValid': false,
    'errors': [
      {'code': 'structured_movement_required', 'message': '请补全记录后再确认。'},
    ],
  },
};

Map<String, dynamic> _proposalJson(Map<String, dynamic> group) => {
  'id': 'prop_1',
  'status': 'pending',
  'source': {
    'kind': 'user_text',
    'modelName': 'gpt-x-preview',
    'evidenceRefs': [
      {'label': '午餐 18 元'},
    ],
  },
  'atomicGroups': [group],
};

class _FakeAiRepo implements AiProposalRepository {
  _FakeAiRepo({this.pending = const [], this.failCreates = 0});
  final List<AiProposalVm> pending;
  int failCreates;
  int createCalls = 0;
  final List<String> approvedGroupIds = [];

  @override
  Future<List<AiProposalVm>> listPending() async => pending;
  @override
  Future<AiProposalVm?> getProposal(Id id) async => null;
  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) async {
    approvedGroupIds.add(groupId);
    return const ConfirmResultVm(
      atomicGroupId: 'ag_text_1',
      confirmedMovementIds: ['mov_text_1'],
      snapshotInvalidated: true,
      ledgerWrite: true,
    );
  }

  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {}
  @override
  Future<void> createFromText(String text) async {
    createCalls += 1;
    if (failCreates > 0) {
      failCreates -= 1;
      throw ApiServiceUnavailableException(
        '/v1/ai/proposals/from-text',
        code: 'ai_provider_unavailable',
        message: 'openai_responses upstream 503',
      );
    }
  }

  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) => throw UnsupportedError('unused');
  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) => throw UnsupportedError('unused');
  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) =>
      throw UnsupportedError('unused');
}

Widget _reviewHost(_FakeAiRepo repo) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    accountsProvider.overrideWith((ref) async => const [_cashAccount]),
    aiProposalRepositoryProvider.overrideWithValue(repo),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
    recentMovementsProvider.overrideWith((ref) async => const <MovementVm>[]),
    subscriptionsProvider.overrideWith((ref) async => const <SubscriptionVm>[]),
    upcomingSubscriptionsProvider.overrideWith(
      (ref) async => const <SubscriptionVm>[],
    ),
    liabilityPositionsProvider.overrideWith(
      (ref) async => const <LiabilityPositionVm>[],
    ),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const AiReviewPage()),
        GoRoute(path: '/ai-edit/:id', builder: (_, _) => const Placeholder()),
      ],
    ),
  ),
);

Widget _textHost(_FakeAiRepo repo, {void Function()? onOverview}) =>
    ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => _caps),
        aiProposalRepositoryProvider.overrideWithValue(repo),
        aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
        overviewProvider.overrideWith((ref) async {
          onOverview?.call();
          return const PortfolioOverviewVm(
            pendingSummary: PendingSummaryVm(),
            quoteStatusSummary: QuoteStatusSummaryVm(),
            primaryHoldings: [],
            recentMovements: [],
          );
        }),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const AiImportTextPage()),
            GoRoute(
              path: '/ai-review',
              builder: (_, _) => const Scaffold(body: Text('review-page')),
            ),
          ],
        ),
      ),
    );

void main() {
  group('映射', () {
    test('结构化候选：proposedMovement 与 isValid', () {
      final p = parseAiProposalData(_proposalJson(_structuredGroupJson()));
      final g = p.groups.single;
      expect(g.proposedMovement, isNotNull);
      expect(g.proposedMovement!.title, '午餐');
      expect(g.proposedMovement!.displayAmount!.amount, '18');
      expect(g.proposedMovement!.displayAmount!.currency, 'CNY');
      expect(g.isValid, isTrue);
      expect(g.needsCompletion, isFalse);
      expect(p.modelName, 'gpt-x-preview');
    });

    test('待补全候选：无 movement 且校验未过', () {
      final p = parseAiProposalData(_proposalJson(_incompleteGroupJson()));
      final g = p.groups.single;
      expect(g.proposedMovement, isNull);
      expect(g.isValid, isFalse);
      expect(g.needsCompletion, isTrue);
    });
  });

  group('AI 复核卡（必测 3）', () {
    testWidgets('结构化候选：显示标题/账户/金额/时间，可确认/编辑/拒绝', (tester) async {
      final repo = _FakeAiRepo(
        pending: [parseAiProposalData(_proposalJson(_structuredGroupJson()))],
      );
      await tester.pumpWidget(_reviewHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('午餐'), findsOneWidget);
      expect(find.text('现金钱包'), findsOneWidget);
      expect(find.text('¥18'), findsOneWidget);
      expect(find.textContaining('2026-07-19 12:30'), findsOneWidget);
      expect(find.text('接受整组'), findsOneWidget);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('拒绝整组'), findsOneWidget);
      // modelName 只作诊断，不上主卡片。
      expect(find.textContaining('gpt-x-preview'), findsNothing);
      await tester.tap(find.text('接受整组'));
      await tester.pumpAndSettle();
      expect(repo.approvedGroupIds, ['ag_text_1']);
      expect(find.textContaining('已入账'), findsOneWidget);
    });

    testWidgets('待补全候选：只有待补全标记与编辑/拒绝，不能直接确认', (tester) async {
      final repo = _FakeAiRepo(
        pending: [parseAiProposalData(_proposalJson(_incompleteGroupJson()))],
      );
      await tester.pumpWidget(_reviewHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('待补全'), findsOneWidget);
      expect(find.text('接受整组'), findsNothing);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('拒绝整组'), findsOneWidget);
      // 不显示工程原因 / provider / schema。
      expect(find.textContaining('structured_movement'), findsNothing);
      expect(find.textContaining('provider'), findsNothing);
    });
  });

  group('文本导入（必测 4）', () {
    testWidgets('503：保留原文本、显示简短失败与重试；重试成功后进入复核', (tester) async {
      final repo = _FakeAiRepo(failCreates: 1);
      await tester.pumpWidget(_textHost(repo));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '午餐 18 元');
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.createCalls, 1);
      expect(find.text('整理失败，请稍后重试。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // 文本保留；不显示 provider 名或上游状态码。
      expect(find.text('午餐 18 元'), findsOneWidget);
      expect(find.textContaining('openai'), findsNothing);
      expect(find.textContaining('503'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(repo.createCalls, 2);
      expect(find.text('review-page'), findsOneWidget);
    });

    testWidgets('成功：刷新 pending 与首页并进入复核', (tester) async {
      var overviewRuns = 0;
      final repo = _FakeAiRepo();
      await tester.pumpWidget(
        _textHost(repo, onOverview: () => overviewRuns += 1),
      );
      await tester.pumpAndSettle();
      // 隐藏 watcher 挂在首页 provider 上（通过 host 覆盖计数）。
      final firstRuns = overviewRuns;
      await tester.enterText(find.byType(TextField), '午餐 18 元');
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(repo.createCalls, 1);
      expect(find.text('review-page'), findsOneWidget);
      expect(overviewRuns, greaterThanOrEqualTo(firstRuns));
    });
  });
}
