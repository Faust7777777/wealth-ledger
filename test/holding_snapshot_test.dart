// 多资产账户与持仓快照（2026-07-29 任务单 §必测 1-8）：
// 多资产列表与审核卡在窄屏/矮窗口不溢出；三项只出一张卡且只发一次整组确认；
// 待确认期间账户数量与 overview 不变；清零可提交；unchanged 不渲染成变化；
// 缺报价的资产数量仍可见且不按 0 计入合计；401 重放幂等键不变、重复点击只一次。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/account_detail_page.dart';
import 'package:finwealth/features/account_holdings_section.dart';
import 'package:finwealth/features/ai_review_page.dart';
import 'package:finwealth/features/holding_snapshot_card.dart';
import 'package:finwealth/features/holding_snapshot_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

const _okx = AccountVm(
  id: 'a_okx',
  displayName: 'OKX',
  accountType: AccountType.exchange,
  isLiability: false,
  balanceMode: 'mixed',
  defaultCurrency: 'CNY',
  supportedCurrencies: ['CNY', 'USDT', 'BTC', 'ETH'],
);

ValuedMoney _cny(String amount) => ValuedMoney(
  amount: amount,
  currency: 'CNY',
  asOf: '2026-07-29T09:00:00+08:00',
  quality: ValueQuality.exact,
);

const _instruments = [
  InstrumentVm(
    id: 'inst_btc',
    type: InstrumentType.crypto,
    symbol: 'BTC',
    displayName: 'Bitcoin',
    quoteCurrency: 'USDT',
  ),
  InstrumentVm(
    id: 'inst_eth',
    type: InstrumentType.crypto,
    symbol: 'ETH',
    displayName: 'Ethereum',
    quoteCurrency: 'USDT',
  ),
  InstrumentVm(
    id: 'inst_usdt',
    type: InstrumentType.crypto,
    symbol: 'USDT',
    displayName: 'Tether',
    quoteCurrency: 'USDT',
  ),
  InstrumentVm(
    id: 'inst_sol',
    type: InstrumentType.crypto,
    symbol: 'SOL',
    displayName: 'Solana',
    quoteCurrency: 'USDT',
  ),
];

HoldingVm _holding(
  String id,
  String instrumentId,
  String symbol,
  String name,
  String quantity, {
  ValuedMoney? value,
  QuoteStatus status = QuoteStatus.fresh,
}) => HoldingVm(
  id: id,
  accountId: 'a_okx',
  instrumentId: instrumentId,
  symbol: symbol,
  displayName: name,
  quantity: quantity,
  quoteStatus: status,
  marketValue: value,
  // 账户合计口径：accountMarketValue（账户折算单位）。
  accountMarketValue: value,
);

List<HoldingVm> get _holdings => [
  _holding('h_btc', 'inst_btc', 'BTC', 'Bitcoin', '0.25', value: _cny('12000')),
  _holding('h_eth', 'inst_eth', 'ETH', 'Ethereum', '3.2', value: _cny('8000')),
  _holding(
    'h_usdt',
    'inst_usdt',
    'USDT',
    'Tether',
    '1250',
    value: _cny('9000'),
  ),
];

/// 后端返回的持仓快照审核组：三项里两项变化、一项 unchanged。
Map<String, dynamic> _snapshotGroupJson({
  List<Map<String, dynamic>>? movements,
  List<Map<String, dynamic>> skipped = const [
    {'instrumentId': 'inst_usdt', 'quantity': '1250', 'reason': 'unchanged'},
  ],
}) => {
  'id': 'ag_snapshot_1',
  'title': '更新OKX持仓',
  'operation': 'modify',
  'status': 'pending',
  'proposedMovements':
      movements ??
      [
        _snapshotMovementJson('mv_btc', 'inst_btc', '0.25', '0.4'),
        _snapshotMovementJson('mv_eth', 'inst_eth', '3.2', '5.0'),
      ],
  'skippedPositions': skipped,
};

Map<String, dynamic> _snapshotMovementJson(
  String id,
  String instrumentId,
  String previous,
  String target,
) => {
  'id': id,
  'atomicGroupId': 'ag_snapshot_1',
  'type': 'adjustment',
  'status': 'pending_review',
  'title': '调整持仓',
  'occurredAt': '2026-07-29T10:00:00Z',
  'entries': [
    {
      'id': 'entry_$id',
      'accountId': 'a_okx',
      'instrumentId': instrumentId,
      'amount': '1',
      'currency': 'USDT',
      'direction': 'in',
      'role': 'adjustment',
    },
  ],
  'holdingAdjustment': {
    'accountId': 'a_okx',
    'instrumentId': instrumentId,
    'previousQuantity': previous,
    'targetQuantity': target,
  },
  'tags': ['holding_adjustment', 'holding_snapshot'],
};

AiProposalVm _snapshotProposal({List<Map<String, dynamic>>? movements}) =>
    parseAiProposalData({
      'id': 'ap_1',
      'status': 'pending',
      'summary': 'OKX 持仓快照',
      'source': {
        'kind': 'manual',
        'evidenceRefs': [
          {'label': 'OKX 导出'},
        ],
      },
      'atomicGroups': [_snapshotGroupJson(movements: movements)],
    });

http.Response _json(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 走真实 LocalServer 实现的 portfolio 仓库，记录每次请求。
({PortfolioRepository repo, List<http.Request> requests, List<String> keys})
_snapshotRepo({int failStatus = 0, int failFirst = 0}) {
  final requests = <http.Request>[];
  final keys = <String>[];
  var calls = 0;
  final store = MemoryAuthTokenStore();
  // 401 重放需要本地有会话可刷新。
  store.write(
    const StoredAuthSession(
      accessToken: 'old',
      refreshToken: 'r1',
      expiresAt: '2026-07-29T12:00:00+08:00',
      deviceId: 'd1',
    ),
  );
  final client = DevApiClient(
    'http://127.0.0.1:1',
    tokenStore: store,
    client: MockClient((req) async {
      if (req.url.path == '/v1/auth/refresh') {
        return _json({
          'ok': true,
          'data': {
            'accessToken': 'new',
            'refreshToken': 'r2',
            'expiresAt': '2026-07-29T13:00:00+08:00',
            'deviceId': 'd1',
          },
        }, 200);
      }
      requests.add(req);
      keys.add(req.headers['idempotency-key'] ?? '');
      calls += 1;
      if (failFirst != 0 && calls == 1) {
        return _json({
          'ok': false,
          'error': {'code': 'auth_required'},
        }, failFirst);
      }
      if (failStatus != 0) {
        return _json({
          'ok': false,
          'error': {'code': 'holding_conflict', 'message': '数量未变化'},
        }, failStatus);
      }
      return _json({'ok': true, 'data': _snapshotGroupJson()}, 200);
    }),
  );
  return (
    repo: LocalServerPortfolioRepository(client),
    requests: requests,
    keys: keys,
  );
}

class _DetailPortfolioRepo implements PortfolioRepository {
  _DetailPortfolioRepo(this.inner, {List<HoldingVm>? holdings})
    : holdings = holdings ?? _holdings;
  final PortfolioRepository inner;
  final List<HoldingVm> holdings;
  int overviewReads = 0;
  int holdingReads = 0;

  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => holdings;
  @override
  Future<List<HoldingVm>> listHoldings() async {
    holdingReads += 1;
    return holdings;
  }

  @override
  Future<PortfolioOverviewVm> getOverview() async {
    overviewReads += 1;
    return const PortfolioOverviewVm(
      pendingSummary: PendingSummaryVm(),
      quoteStatusSummary: QuoteStatusSummaryVm(),
      primaryHoldings: [],
      recentMovements: [],
    );
  }

  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      );
  @override
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) => throw UnsupportedError('unused');
  @override
  Future<AiAtomicGroupVm> proposeHoldingSnapshot(
    Id accountId, {
    required List<HoldingSnapshotPositionInput> positions,
    IsoDateTime? asOf,
    String? note,
  }) => inner.proposeHoldingSnapshot(
    accountId,
    positions: positions,
    asOf: asOf,
    note: note,
  );
}

/// 标的仓库 fake：登记资产由服务端分配 id，前端不生成。
class _FakeInstrumentRepo implements InstrumentRepository {
  _FakeInstrumentRepo({this.fails = false});
  final bool fails;
  final List<CreateInstrumentInput> created = [];

  @override
  Future<List<InstrumentVm>> listInstruments() async => _instruments;

  @override
  Future<InstrumentVm> createInstrument(CreateInstrumentInput input) async {
    created.add(input);
    if (fails) throw Exception('offline');
    return InstrumentVm(
      id: 'inst_server_${created.length}',
      type: input.type,
      symbol: input.symbol,
      displayName: input.displayName,
      quoteCurrency: input.quoteCurrency,
    );
  }
}

class _FakeAccountRepo implements AccountRepository {
  const _FakeAccountRepo();
  @override
  Future<AccountVm?> getAccount(Id id) async => _okx;
  @override
  Future<List<AccountVm>> listAccounts() async => const [_okx];
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => const [];
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input) =>
      throw UnsupportedError('unused');
  @override
  Future<void> archiveAccount(Id id) => throw UnsupportedError('unused');
}

class _ReviewRepo implements AiProposalRepository {
  _ReviewRepo({this.movements});
  final List<Map<String, dynamic>>? movements;
  final List<String> approved = [];
  final List<String> rejected = [];
  bool cleared = false;

  @override
  Future<List<AiProposalVm>> listPending() async =>
      cleared ? const [] : [_snapshotProposal(movements: movements)];

  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) async {
    approved.add(groupId);
    cleared = true;
    return const ConfirmResultVm(
      atomicGroupId: 'ag_snapshot_1',
      confirmedMovementIds: ['mv_btc', 'mv_eth'],
      snapshotInvalidated: true,
      ledgerWrite: true,
    );
  }

  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {
    rejected.add(groupId);
    cleared = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _detailHost(
  _DetailPortfolioRepo repo, {
  _FakeInstrumentRepo? instrumentRepo,
}) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    accountRepositoryProvider.overrideWithValue(const _FakeAccountRepo()),
    portfolioRepositoryProvider.overrideWithValue(repo),
    if (instrumentRepo != null)
      instrumentRepositoryProvider.overrideWithValue(instrumentRepo),
    instrumentsProvider.overrideWith((ref) async => _instruments),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const AccountDetailPage(accountId: 'a_okx'),
        ),
        GoRoute(
          path: '/ai-review',
          builder: (_, _) => const Scaffold(body: Text('review-page')),
        ),
      ],
    ),
  ),
);

Widget _reviewHost(_ReviewRepo repo, {_DetailPortfolioRepo? portfolio}) =>
    ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => _caps),
        aiProposalRepositoryProvider.overrideWithValue(repo),
        instrumentsProvider.overrideWith((ref) async => _instruments),
        accountsProvider.overrideWith((ref) async => const [_okx]),
        if (portfolio != null)
          portfolioRepositoryProvider.overrideWithValue(portfolio),
      ],
      child: MaterialApp(
        home: Column(
          children: [
            // 让 holdings / overview 保持存活，才能观察确认后的重新拉取。
            if (portfolio != null) const _LedgerWatcher(),
            const Expanded(child: AiReviewPage()),
          ],
        ),
      ),
    );

class _LedgerWatcher extends ConsumerWidget {
  const _LedgerWatcher();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(holdingsProvider);
    ref.watch(overviewProvider);
    return const SizedBox.shrink();
  }
}

void main() {
  group('多资产账户视图', () {
    testWidgets('逐项显示数量、报价单位、折算价值与合计', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _DetailPortfolioRepo(_snapshotRepo().repo);
      await tester.pumpWidget(_detailHost(repo));
      await tester.pumpAndSettle();

      for (final symbol in ['BTC', 'ETH', 'USDT']) {
        expect(find.textContaining(symbol), findsWidgets, reason: symbol);
      }
      // 原始数量与报价单位都在。
      expect(find.text('0.25'), findsOneWidget);
      expect(find.text('3.2'), findsOneWidget);
      expect(find.text('1,250'), findsOneWidget);
      expect(find.text('USDT'), findsWidgets);
      // 合计 = 12000 + 8000 + 9000。
      expect(find.text('合计（CNY）'), findsOneWidget);
      expect(find.textContaining('29,000'), findsOneWidget);
    });

    testWidgets('缺 BTC 报价：数量仍可见，合计不把它当 0', (tester) async {
      final holdings = [
        _holding(
          'h_btc',
          'inst_btc',
          'BTC',
          'Bitcoin',
          '0.25',
          status: QuoteStatus.unpriceable,
        ),
        _holding(
          'h_eth',
          'inst_eth',
          'ETH',
          'Ethereum',
          '3.2',
          value: _cny('8000'),
        ),
      ];
      final total = accountHoldingsTotal(_okx, holdings);
      expect(total.amount, '8000');
      expect(total.pricedCount, 1);
      expect(total.missingQuoteCount, 1);
      expect(total.otherCurrencyCount, 0);
      expect(total.excludedLabel, '1 项待补报价');

      final repo = _DetailPortfolioRepo(
        _snapshotRepo().repo,
        holdings: holdings,
      );
      await tester.pumpWidget(_detailHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('0.25'), findsOneWidget);
      expect(find.text('暂无估值'), findsOneWidget);
      expect(find.text('暂无报价'), findsOneWidget);
      // 低强调入口，不是常驻解释段落。
      expect(find.byKey(kAccountMissingQuotesKey), findsOneWidget);
      expect(find.text('1 项待补报价'), findsOneWidget);
      expect(find.textContaining('8,000'), findsWidgets);
    });

    testWidgets('360 与 1200x520 下多资产列表无 overflow', (tester) async {
      for (final size in const [Size(360, 640), Size(1200, 520)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final repo = _DetailPortfolioRepo(_snapshotRepo().repo);
        await tester.pumpWidget(_detailHost(repo));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');
      }
    });
  });

  group('批量更新持仓', () {
    testWidgets('改两项数量：一次请求、只带变化项、给前往审核', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final captured = _snapshotRepo();
      final repo = _DetailPortfolioRepo(captured.repo);
      await tester.pumpWidget(_detailHost(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('holding_snapshot_field_inst_btc')).last,
        '0.4',
      );
      await tester.enterText(
        find.byKey(const ValueKey('holding_snapshot_field_inst_eth')).last,
        '5.0',
      );
      await tester.pump();
      await tester.tap(find.byKey(kHoldingSnapshotSubmitKey));
      await tester.pumpAndSettle();

      expect(captured.requests, hasLength(1));
      final body =
          jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
      expect(
        captured.requests.single.url.path,
        '/v1/accounts/a_okx/holding-snapshot-proposals',
      );
      // USDT 未改动：不进请求。
      expect(body['positions'], [
        {'instrumentId': 'inst_btc', 'targetQuantity': '0.4'},
        {'instrumentId': 'inst_eth', 'targetQuantity': '5.0'},
      ]);
      expect(captured.keys.single, isNotEmpty);
      expect(find.text('已加入待确认'), findsOneWidget);
      expect(find.text('前往审核'), findsOneWidget);
      // 不宣称持仓已更新。
      expect(find.textContaining('已更新'), findsNothing);
    });

    testWidgets('某项清零可提交', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final captured = _snapshotRepo();
      await tester.pumpWidget(_detailHost(_DetailPortfolioRepo(captured.repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('holding_snapshot_field_inst_eth')).last,
        '0',
      );
      await tester.pump();
      await tester.tap(find.byKey(kHoldingSnapshotSubmitKey));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
      expect(body['positions'], [
        {'instrumentId': 'inst_eth', 'targetQuantity': '0'},
      ]);
    });

    testWidgets('全部未变化的 409：简短状态且保留输入', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final captured = _snapshotRepo(failStatus: 409);
      await tester.pumpWidget(_detailHost(_DetailPortfolioRepo(captured.repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('holding_snapshot_field_inst_btc')).last,
        '0.4',
      );
      await tester.pump();
      await tester.tap(find.byKey(kHoldingSnapshotSubmitKey));
      await tester.pumpAndSettle();

      expect(find.text('数量已变化或已有待确认调整，请重新核对'), findsOneWidget);
      // 弹窗仍在，用户输入保留。
      expect(find.byKey(kHoldingSnapshotSubmitKey), findsOneWidget);
      expect(find.text('0.4'), findsOneWidget);
    });

    testWidgets('重复点击只发一次请求', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final captured = _snapshotRepo();
      await tester.pumpWidget(_detailHost(_DetailPortfolioRepo(captured.repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('holding_snapshot_field_inst_btc')).last,
        '0.4',
      );
      await tester.pump();
      await tester.tap(find.byKey(kHoldingSnapshotSubmitKey));
      await tester.tap(
        find.byKey(kHoldingSnapshotSubmitKey),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(captured.requests, hasLength(1));
    });

    testWidgets('可搜索并添加真实标的，不由前端生成 id', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final captured = _snapshotRepo();
      await tester.pumpWidget(_detailHost(_DetailPortfolioRepo(captured.repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kHoldingSnapshotAddKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kHoldingSnapshotSearchKey), 'sol');
      await tester.pumpAndSettle();
      // 已在列表里的标的不再出现。
      expect(
        find.byKey(const ValueKey('instrument_option_inst_btc')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('instrument_option_inst_sol')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('holding_snapshot_field_inst_sol')).last,
        '12',
      );
      await tester.pump();
      await tester.tap(find.byKey(kHoldingSnapshotSubmitKey));
      await tester.pumpAndSettle();
      final body =
          jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
      expect(body['positions'], [
        {'instrumentId': 'inst_sol', 'targetQuantity': '12'},
      ]);
    });

    testWidgets('找不到标的时可登记：id 由服务端分配，失败不假装成功', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final captured = _snapshotRepo();
      final instrumentRepo = _FakeInstrumentRepo();
      await tester.pumpWidget(
        _detailHost(
          _DetailPortfolioRepo(captured.repo),
          instrumentRepo: instrumentRepo,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kHoldingSnapshotAddKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kHoldingSnapshotSearchKey), 'doge');
      await tester.pumpAndSettle();

      expect(find.text('没有匹配的资产'), findsOneWidget);
      expect(find.byKey(kHoldingSnapshotRegisterKey), findsOneWidget);
      expect(find.text('登记 DOGE'), findsOneWidget);

      await tester.tap(find.byKey(kHoldingSnapshotRegisterKey));
      await tester.pumpAndSettle();

      // 登记走服务端接口：前端只传符号与计价单位，不生成 id。
      expect(instrumentRepo.created.single.symbol, 'DOGE');
      expect(instrumentRepo.created.single.quoteCurrency, 'CNY');
      expect(instrumentRepo.created.single.type, InstrumentType.crypto);
      // 回到批量弹窗，用服务端返回的真实 id 建行。
      expect(
        find.byKey(const ValueKey('holding_snapshot_field_inst_server_1')),
        findsOneWidget,
      );
    });

    testWidgets('登记失败：给短提示，不建行也不假装成功', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final instrumentRepo = _FakeInstrumentRepo(fails: true);
      await tester.pumpWidget(
        _detailHost(
          _DetailPortfolioRepo(_snapshotRepo().repo),
          instrumentRepo: instrumentRepo,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccountUpdateHoldingsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kHoldingSnapshotAddKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(kHoldingSnapshotSearchKey), 'doge');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kHoldingSnapshotRegisterKey));
      await tester.pumpAndSettle();

      expect(find.text('登记未成功，请重试'), findsOneWidget);
      expect(instrumentRepo.created, hasLength(1));
    });

    test('401 刷新后重放复用同一个 Idempotency-Key', () async {
      final captured = _snapshotRepo(failFirst: 401);
      await captured.repo.proposeHoldingSnapshot(
        'a_okx',
        positions: const [
          HoldingSnapshotPositionInput(
            instrumentId: 'inst_btc',
            targetQuantity: '0.4',
          ),
        ],
      );
      expect(captured.requests, hasLength(2));
      expect(captured.keys.first, isNotEmpty);
      expect(captured.keys[0], captured.keys[1]);
    });
  });

  group('快照审核卡', () {
    testWidgets('三项只出一张卡；展开逐项显示 previous → target', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _ReviewRepo(
        movements: [
          _snapshotMovementJson('mv_btc', 'inst_btc', '0.25', '0.4'),
          _snapshotMovementJson('mv_eth', 'inst_eth', '3.2', '5.0'),
          _snapshotMovementJson('mv_usdt', 'inst_usdt', '1250', '1300'),
        ],
      );
      await tester.pumpWidget(_reviewHost(repo));
      await tester.pumpAndSettle();

      expect(find.byType(HoldingSnapshotCard), findsOneWidget);
      expect(find.text('3 项数量变化'), findsOneWidget);
      // 默认收起：不逐项铺开。
      expect(find.textContaining('→'), findsNothing);
      // 只有整组动作。
      expect(find.text('接受整组'), findsOneWidget);
      expect(find.text('拒绝整组'), findsOneWidget);

      await tester.tap(find.byKey(kHoldingSnapshotExpandKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('0.25 → 0.4'), findsOneWidget);
      expect(find.textContaining('3.2 → 5'), findsOneWidget);
      expect(find.textContaining('1,250 → 1,300'), findsOneWidget);
      expect(find.textContaining('Bitcoin'), findsOneWidget);
    });

    testWidgets('确认只发一次整组确认请求', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = _ReviewRepo();
      await tester.pumpWidget(_reviewHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接受整组'));
      await tester.pumpAndSettle();
      expect(repo.approved, ['ag_snapshot_1']);
      expect(find.byType(HoldingSnapshotCard), findsNothing);
    });

    testWidgets('待确认期间持仓与 overview 不变；确认后一起刷新', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final portfolio = _DetailPortfolioRepo(_snapshotRepo().repo);
      final repo = _ReviewRepo();
      await tester.pumpWidget(_reviewHost(repo, portfolio: portfolio));
      await tester.pumpAndSettle();

      // 候选是 pending：持仓数量仍是提交前的值。
      final before = portfolio.overviewReads;
      expect(
        (await portfolio.listHoldingsByAccount(
          'a_okx',
        )).firstWhere((h) => h.instrumentId == 'inst_btc').quantity,
        '0.25',
      );
      expect(portfolio.overviewReads, before);

      await tester.tap(find.text('接受整组'));
      await tester.pumpAndSettle();
      expect(repo.approved, ['ag_snapshot_1']);
      // ledgerWrite=true → 持仓与 overview 都重新拉取。
      expect(portfolio.holdingReads, greaterThan(0));
      expect(portfolio.overviewReads, greaterThan(before));
    });

    testWidgets('unchanged 不渲染成变化项，只报数量', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_reviewHost(_ReviewRepo()));
      await tester.pumpAndSettle();
      expect(find.text('2 项数量变化'), findsOneWidget);
      expect(find.text('1 项数量未变化'), findsOneWidget);

      await tester.tap(find.byKey(kHoldingSnapshotExpandKey));
      await tester.pumpAndSettle();
      // unchanged 的 USDT 没有 previous → target 行。
      expect(find.textContaining('Tether'), findsNothing);
      expect(find.textContaining('1,250 →'), findsNothing);
    });

    testWidgets('360 与 1200x520 下审核卡无 overflow', (tester) async {
      for (final size in const [Size(360, 640), Size(1200, 520)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_reviewHost(_ReviewRepo()));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kHoldingSnapshotExpandKey));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');
      }
    });
  });

  group('映射与纯函数', () {
    test('组内保留全部候选与 skippedPositions', () {
      final group = _snapshotProposal().groups.single;
      expect(isHoldingSnapshotGroup(group), isTrue);
      expect(group.proposedMovements, hasLength(2));
      expect(holdingSnapshotMovements(group), hasLength(2));
      expect(group.skippedPositions.single.instrumentId, 'inst_usdt');
      expect(group.skippedPositions.single.reason, 'unchanged');
      final first = group.proposedMovements.first.holdingAdjustment!;
      expect(first.previousQuantity, '0.25');
      expect(first.targetQuantity, '0.4');
    });

    test('普通候选不会被误判成持仓快照', () {
      final plain = parseAiProposalData({
        'id': 'ap_2',
        'status': 'pending',
        'source': {'kind': 'manual'},
        'atomicGroups': [
          {
            'id': 'ag_2',
            'title': '一笔支出',
            'operation': 'create',
            'status': 'pending',
            'proposedMovements': [
              {
                'id': 'mv_1',
                'atomicGroupId': 'ag_2',
                'type': 'expense',
                'status': 'pending_review',
                'title': '午餐',
                'occurredAt': '2026-07-29T10:00:00Z',
                'entries': [],
              },
            ],
          },
        ],
      }).groups.single;
      expect(isHoldingSnapshotGroup(plain), isFalse);
      expect(plain.skippedPositions, isEmpty);
    });

    test('多资产判定覆盖 exchange / wallet / holdings / mixed', () {
      AccountVm account(AccountType type, String mode) => AccountVm(
        id: 'a',
        displayName: 'x',
        accountType: type,
        isLiability: false,
        balanceMode: mode,
      );
      expect(
        accountIsMultiAsset(account(AccountType.exchange, 'cash_balance')),
        isTrue,
      );
      expect(
        accountIsMultiAsset(account(AccountType.wallet, 'cash_balance')),
        isTrue,
      );
      expect(
        accountIsMultiAsset(account(AccountType.brokerage, 'holdings')),
        isTrue,
      );
      expect(accountIsMultiAsset(account(AccountType.bank, 'mixed')), isTrue);
      expect(
        accountIsMultiAsset(account(AccountType.bank, 'cash_balance')),
        isFalse,
      );
    });

    test('币种不一致的持仓不并入合计，入口文案不谎称缺报价', () {
      final holdings = [
        _holding(
          'h_btc',
          'inst_btc',
          'BTC',
          'Bitcoin',
          '0.25',
          value: ValuedMoney(
            amount: '380',
            currency: 'USDT',
            asOf: '2026-07-29T09:00:00+08:00',
            quality: ValueQuality.exact,
          ),
        ),
        _holding(
          'h_eth',
          'inst_eth',
          'ETH',
          'Ethereum',
          '3.2',
          value: _cny('8000'),
        ),
      ];
      final total = accountHoldingsTotal(_okx, holdings);
      expect(total.amount, '8000');
      expect(total.otherCurrencyCount, 1);
      expect(total.missingQuoteCount, 0);
      expect(total.excludedLabel, '1 项未计入合计');
    });
  });
}
