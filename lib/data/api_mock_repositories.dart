// Wealth Ledger — local_server 仓库（LocalServer*）：读取本地 Rust dev/local server 的 /v1 接口。
// 仅在 DATA_SOURCE=local_server（别名 dev_server / api_mock）时启用，绝非默认；可连 --ledger-path 真实账本；
// 写路径只生成 proposal；禁用端点以 403 呈现。（文件名暂留 api_mock_repositories.dart 以免动测试导入。）
// 形状对齐 docs/contracts（DATA_SCHEMA_V1 / examples / FRONTEND_API_INTEGRATION_HANDOFF_V1）。
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/format.dart';
import '../core/types.dart';
import 'repositories.dart';
import 'view_models.dart';

/// 产品边界禁止的端点（转账/下单/AI 自动写账等）由 server 返回 403。
class ApiForbiddenException implements Exception {
  ApiForbiddenException(this.path);
  final String path;
  @override
  String toString() => '该能力被产品边界禁止（403）：$path';
}

class DevApiClient {
  DevApiClient(this.baseUrl, {this.scenario = '', http.Client? client})
      : _client = client ?? http.Client();
  final String baseUrl;
  final String scenario;
  final http.Client _client;

  String _url(String path) => scenario.isEmpty
      ? '$baseUrl$path'
      : '$baseUrl$path${path.contains('?') ? '&' : '?'}scenario=$scenario';

  Object? _handle(http.Response res, String path) {
    if (res.statusCode == 403) throw ApiForbiddenException(path);
    if (res.statusCode >= 400) throw Exception('HTTP ${res.statusCode} · $path');
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null; // 如 AI reject 返回 204
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is Map<String, dynamic>) {
      if (body['ok'] == false) throw Exception('API error · $path');
      return body['data'] ?? body;
    }
    return body;
  }

  Future<Object?> getData(String path) async =>
      _handle(await _client.get(Uri.parse(_url(path))), path);

  Future<Object?> postData(String path, {Object? body}) async => _handle(
        await _client.post(
          Uri.parse(_url(path)),
          headers: const {'content-type': 'application/json'},
          body: body == null ? null : jsonEncode(body),
        ),
        path,
      );

  Future<Object?> patchData(String path, {Object? body}) async => _handle(
        await _client.patch(
          Uri.parse(_url(path)),
          headers: const {'content-type': 'application/json'},
          body: body == null ? null : jsonEncode(body),
        ),
        path,
      );
}

// ———— 小工具 ————
Map<String, dynamic> _m(Object? o) => (o as Map).cast<String, dynamic>();
List<dynamic> _list(Object? d) => d is List
    ? d
    : (d is Map && d['items'] is List ? d['items'] as List : const []);
int _int(Object? o) => (o as num?)?.toInt() ?? 0;

// ———— enum 解析 ————
ValueQuality _quality(Object? s) => switch (s) {
      'estimated' => ValueQuality.estimated,
      'incomplete' => ValueQuality.incomplete,
      'unpriceable' => ValueQuality.unpriceable,
      'anomaly' => ValueQuality.anomaly,
      _ => ValueQuality.exact,
    };
QuoteStatus _quote(Object? s) => switch (s) {
      'stale' => QuoteStatus.stale,
      'offline_cached' => QuoteStatus.offlineCached,
      'incomplete' => QuoteStatus.incomplete,
      'unpriceable' => QuoteStatus.unpriceable,
      'error' => QuoteStatus.error,
      _ => QuoteStatus.fresh,
    };
AccountType _acctType(Object? s) => switch (s) {
      'bank' => AccountType.bank,
      'brokerage' => AccountType.brokerage,
      'exchange' => AccountType.exchange,
      'wallet' => AccountType.wallet,
      'platform_wallet' => AccountType.platformWallet,
      'virtual_card' => AccountType.virtualCard,
      'social_security' => AccountType.socialSecurity,
      'credit_card' => AccountType.creditCard,
      'loan' => AccountType.loan,
      'cash' => AccountType.cash,
      _ => AccountType.other,
    };
String _acctTypeWire(AccountType t) => switch (t) {
      AccountType.bank => 'bank',
      AccountType.brokerage => 'brokerage',
      AccountType.exchange => 'exchange',
      AccountType.wallet => 'wallet',
      AccountType.platformWallet => 'platform_wallet',
      AccountType.virtualCard => 'virtual_card',
      AccountType.socialSecurity => 'social_security',
      AccountType.creditCard => 'credit_card',
      AccountType.loan => 'loan',
      AccountType.cash => 'cash',
      AccountType.other => 'other',
    };
MovementType _movType(Object? s) => switch (s) {
      'income' => MovementType.income,
      'expense' => MovementType.expense,
      'transfer' => MovementType.transfer,
      'buy' => MovementType.buy,
      'sell' => MovementType.sell,
      'dividend' => MovementType.dividend,
      'interest' => MovementType.interest,
      'fee' => MovementType.fee,
      'loan_disbursement' => MovementType.loanDisbursement,
      'loan_repayment' => MovementType.loanRepayment,
      'correction' => MovementType.correction,
      _ => MovementType.adjustment,
    };
MovementStatus _movStatus(Object? s) => switch (s) {
      'draft' => MovementStatus.draft,
      'pending_review' => MovementStatus.pendingReview,
      'in_transit' => MovementStatus.inTransit,
      'cancelled' => MovementStatus.cancelled,
      'reversed' => MovementStatus.reversed,
      _ => MovementStatus.confirmed,
    };
DcaReminderStatus _remStatus(Object? s) => switch (s) {
      'overdue' => DcaReminderStatus.overdue,
      'snoozed' => DcaReminderStatus.snoozed,
      'recorded' => DcaReminderStatus.recorded,
      'skipped' => DcaReminderStatus.skipped,
      _ => DcaReminderStatus.due,
    };
DcaFrequency _freq(Object? s) => switch (s) {
      'weekly' => DcaFrequency.weekly,
      'monthly' => DcaFrequency.monthly,
      _ => DcaFrequency.custom,
    };
DcaPlanStatus _planStatus(Object? s) => switch (s) {
      'snoozed' => DcaPlanStatus.snoozed,
      'paused' => DcaPlanStatus.paused,
      'completed' => DcaPlanStatus.completed,
      _ => DcaPlanStatus.active,
    };
AiOperation _aiOp(Object? s) => switch (s) {
      'modify' => AiOperation.modify,
      'correction' => AiOperation.correction,
      'merge' => AiOperation.merge,
      'classify' => AiOperation.classify,
      _ => AiOperation.create,
    };
AiGroupStatus _aiGroupStatus(Object? s) => switch (s) {
      'approved' => AiGroupStatus.approved,
      'rejected' => AiGroupStatus.rejected,
      'edited' => AiGroupStatus.edited,
      _ => AiGroupStatus.pending,
    };
AiProposalStatus _aiPropStatus(Object? s) => switch (s) {
      'partially_reviewed' => AiProposalStatus.partiallyReviewed,
      'approved' => AiProposalStatus.approved,
      'rejected' => AiProposalStatus.rejected,
      'edited' => AiProposalStatus.edited,
      'expired' => AiProposalStatus.expired,
      _ => AiProposalStatus.pending,
    };
AiDiffSeverity _diffSev(Object? s) => switch (s) {
      'important' => AiDiffSeverity.important,
      'danger' => AiDiffSeverity.danger,
      _ => AiDiffSeverity.normal,
    };
AnomalyKind _anomKind(Object? s) => switch (s) {
      'quote_stale' => AnomalyKind.quoteStale,
      'unpriceable' => AnomalyKind.unpriceable,
      'reconcile_needed' => AnomalyKind.reconcileNeeded,
      'negative_balance' => AnomalyKind.negativeBalance,
      _ => AnomalyKind.dataAnomaly,
    };
AnomalySeverity _anomSev(Object? s) => switch (s) {
      'critical' => AnomalySeverity.critical,
      'warning' => AnomalySeverity.warning,
      _ => AnomalySeverity.info,
    };

// ———— 值对象 ————
Money _money(Object? o) {
  final j = _m(o);
  return Money(amount: '${j['amount']}', currency: '${j['currency']}');
}

Money? _moneyOrNull(Object? o) => o == null ? null : _money(o);

ValuedMoney _valued(Object? o) {
  final j = _m(o);
  return ValuedMoney(
    amount: '${j['amount']}',
    currency: '${j['currency']}',
    asOf: '${j['asOf']}',
    quality: _quality(j['quality']),
  );
}

ValuedMoney? _valuedOrNull(Object? o) => o == null ? null : _valued(o);

// ———— 实体映射 ————
AccountVm _account(Map<String, dynamic> j) {
  final type = _acctType(j['accountType']);
  final isLiab = j['role'] == 'liability' ||
      j['balanceMode'] == 'liability' ||
      type == AccountType.loan ||
      type == AccountType.creditCard;
  return AccountVm(
    id: '${j['id']}',
    displayName: '${j['displayName']}',
    accountType: type,
    isLiability: isLiab,
    value: _valuedOrNull(j['value']),
    note: j['note'] as String?,
  );
}

HoldingVm _holding(Map<String, dynamic> j) {
  final inst = j['instrument'] is Map ? _m(j['instrument']) : const <String, dynamic>{};
  return HoldingVm(
    id: '${j['id']}',
    accountId: '${j['accountId']}',
    symbol: '${inst['symbol'] ?? j['symbol'] ?? ''}',
    displayName: '${inst['displayName'] ?? j['displayName'] ?? inst['symbol'] ?? ''}',
    quantity: '${j['quantity']}',
    quoteStatus: _quote(j['quoteStatus']),
    costBasisTotal: _moneyOrNull(j['costBasisTotal']),
    marketValue: _valuedOrNull(j['marketValue']),
    dayChange: _moneyOrNull(j['dayChange']),
    unrealizedPnl: _moneyOrNull(j['unrealizedPnl']),
    unrealizedPnlRate: j['unrealizedPnlRate'] as String?,
  );
}

TransactionAmountBreakdownVm? _breakdown(Object? o) {
  if (o == null) return null;
  final j = _m(o);
  return TransactionAmountBreakdownVm(
    gross: _moneyOrNull(j['grossAmount']),
    savings: _moneyOrNull(j['savingsAmount']),
    paid: _money(j['paidAmount']),
  );
}

MovementVm _movement(Map<String, dynamic> j) {
  final settlement = j['settlement'] is Map ? _m(j['settlement']) : const <String, dynamic>{};
  final status = _movStatus(j['status']);
  final inTransit = status == MovementStatus.inTransit || settlement['status'] == 'in_transit';
  Money? amt = _moneyOrNull(j['displayAmount']);
  if (amt == null && j['entries'] is List && (j['entries'] as List).isNotEmpty) {
    final e = _m((j['entries'] as List).first);
    amt = Money(amount: '${e['amount']}', currency: '${e['currency']}');
  }
  return MovementVm(
    id: '${j['id']}',
    atomicGroupId: '${j['atomicGroupId']}',
    type: _movType(j['type']),
    status: status,
    title: '${j['title']}',
    occurredAt: '${j['occurredAt']}',
    displayAmount: amt,
    inTransit: inTransit,
    description: j['description'] as String?,
    amountBreakdown: _breakdown(j['amountBreakdown']),
  );
}

DcaReminderVm _reminder(Map<String, dynamic> j) => DcaReminderVm(
      id: '${j['id']}',
      planId: '${j['planId']}',
      displayName: '${j['displayName'] ?? j['planId']}',
      plannedAmount: _moneyOrNull(j['plannedAmount']) ?? const Money(amount: '0', currency: 'CNY'),
      dueDate: '${j['dueDate']}',
      status: _remStatus(j['status']),
    );

DcaPlanVm _plan(Map<String, dynamic> j) => DcaPlanVm(
      id: '${j['id']}',
      displayName: '${j['displayName']}',
      plannedAmount: _moneyOrNull(j['plannedAmount']) ?? const Money(amount: '0', currency: 'CNY'),
      frequency: _freq(j['frequency']),
      nextDueDate: '${j['nextDueDate']}',
      status: _planStatus(j['reminderStatus'] ?? j['status']),
    );

AiFieldDiffVm _diff(Map<String, dynamic> j) {
  final oldV = j['oldValue']?.toString();
  final newV = j['newValue']?.toString();
  return AiFieldDiffVm(
    fieldPath: '${j['fieldPath']}',
    oldValue: oldV,
    newValue: newV,
    changed: oldV != newV,
    severity: _diffSev(j['severity']),
  );
}

AiAtomicGroupVm _group(Map<String, dynamic> j) => AiAtomicGroupVm(
      id: '${j['id']}',
      title: '${j['title']}',
      operation: _aiOp(j['operation']),
      status: _aiGroupStatus(j['status']),
      diffs: [for (final d in _list(j['diffs'])) _diff(_m(d))],
      warnings: [for (final w in _list(j['warnings'])) (w is Map ? '${w['message']}' : '$w')],
    );

AiProposalVm _proposal(Map<String, dynamic> j) {
  final src = j['source'] is Map ? _m(j['source']) : const <String, dynamic>{};
  final refs = src['evidenceRefs'];
  final ev = refs is List && refs.isNotEmpty ? _m(refs.first) : const <String, dynamic>{};
  return AiProposalVm(
    id: '${j['id']}',
    status: _aiPropStatus(j['status']),
    sourceLabel: '${ev['label'] ?? src['kind'] ?? '输入'}',
    summary: j['summary'] as String?,
    groups: [for (final g in _list(j['atomicGroups'])) _group(_m(g))],
  );
}

AccountAnomalyVm _anomaly(Map<String, dynamic> j) => AccountAnomalyVm(
      id: '${j['id']}',
      accountName: '${j['accountName'] ?? j['accountId']}',
      kind: _anomKind(j['kind']),
      severity: _anomSev(j['severity']),
      detail: '${j['detail']}',
    );

NetWorthSnapshotVm _snapshot(Map<String, dynamic> j) => NetWorthSnapshotVm(
      id: '${j['id']}',
      snapshotAt: '${j['snapshotAt']}',
      grossAssets: _money(j['grossAssets']),
      totalLiabilities: _money(j['totalLiabilities']),
      netWorth: _money(j['netWorth']),
      quality: _quality(j['quality']),
    );

NetWorthSnapshotVm? _snapshotOrNull(Object? o) => o == null ? null : _snapshot(_m(o));

QuoteStatusSummaryVm _quoteSummary(Map<String, dynamic> j) => QuoteStatusSummaryVm(
      freshCount: _int(j['freshCount']),
      staleCount: _int(j['staleCount']),
      offlineCachedCount: _int(j['offlineCachedCount']),
      unpriceableCount: _int(j['unpriceableCount']),
      errorCount: _int(j['errorCount']),
    );

PendingSummaryVm _pending(Map<String, dynamic> j) => PendingSummaryVm(
      aiPendingCount: _int(j['aiPendingCount']),
      accountAnomalyCount: _int(j['accountAnomalyCount']),
      dcaDueCount: _int(j['dcaDueCount']),
      inTransitCount: _int(j['inTransitCount']),
      quoteProblemCount: _int(j['quoteProblemCount']),
      syncProblemCount: _int(j['syncProblemCount']),
    );

AllocationSliceVm _allocationSlice(Map<String, dynamic> j) => AllocationSliceVm(
      category: '${j['category']}',
      percent: '${j['percent']}',
      value: _money(j['value']),
    );

/// 公开以便单测直接喂 examples/*.json（无需起服务）。
PortfolioOverviewVm parseOverviewData(Map<String, dynamic> j) {
  final latest = _snapshotOrNull(j['latestSnapshot']);
  final previous = _snapshotOrNull(j['previousSnapshot']);
  var change = _moneyOrNull(j['changeSinceLastSnapshot']);
  // 服务器未给 delta 时，用快照净值精确相减（同币种）。
  if (change == null &&
      latest != null &&
      previous != null &&
      latest.netWorth.currency == previous.netWorth.currency) {
    change = Money(
      amount: subtractDecimal(latest.netWorth.amount, previous.netWorth.amount),
      currency: latest.netWorth.currency,
    );
  }
  return PortfolioOverviewVm(
    latestSnapshot: latest,
    previousSnapshot: previous,
    pendingSummary: j['pendingSummary'] is Map ? _pending(_m(j['pendingSummary'])) : const PendingSummaryVm(),
    quoteStatusSummary:
        j['quoteStatusSummary'] is Map ? _quoteSummary(_m(j['quoteStatusSummary'])) : const QuoteStatusSummaryVm(),
    primaryHoldings: [for (final h in _list(j['primaryHoldings'])) _holding(_m(h))],
    recentMovements: [for (final m in _list(j['recentMovements'])) _movement(_m(m))],
    changeSinceLastSnapshot: change,
  );
}

/// 公开以便单测直接喂 /v1/portfolio/allocation 的 data。
AssetAllocationVm parseAssetAllocationData(Map<String, dynamic> j) => AssetAllocationVm(
      slices: [for (final s in _list(j['slices'])) _allocationSlice(_m(s))],
      totalAssets: _money(j['totalAssets']),
      totalLiabilities: _money(j['totalLiabilities']),
      netWorth: _money(j['netWorth']),
    );

// ———— 仓库实现 ————
class LocalServerAccountRepository implements AccountRepository {
  LocalServerAccountRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<AccountVm>> listAccounts() async =>
      [for (final a in _list(await _c.getData('/v1/accounts'))) _account(_m(a))];
  @override
  Future<AccountVm?> getAccount(Id id) async {
    final d = await _c.getData('/v1/accounts/$id');
    return d == null ? null : _account(_m(d));
  }
  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async =>
      [for (final a in _list(await _c.getData('/v1/accounts/anomalies'))) _anomaly(_m(a))];
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) async {
    final d = await _c.postData('/v1/accounts', body: {
      'displayName': input.displayName,
      'accountType': _acctTypeWire(input.accountType),
      'defaultCurrency': input.defaultCurrency,
      'supportedCurrencies': [input.defaultCurrency],
      'includeInNetWorth': input.includeInNetWorth,
      'balanceMode': input.balanceMode,
      if (input.institutionName != null) 'institutionName': input.institutionName,
    });
    return _account(_m(d));
  }
  @override
  Future<void> archiveAccount(Id id) async {
    await _c.postData('/v1/accounts/$id/archive');
  }
}

class LocalServerPortfolioRepository implements PortfolioRepository {
  LocalServerPortfolioRepository(this._c);
  final DevApiClient _c;
  @override
  Future<PortfolioOverviewVm> getOverview() async =>
      parseOverviewData(_m(await _c.getData('/v1/portfolio/overview')));
  @override
  Future<List<HoldingVm>> listHoldings() async =>
      [for (final h in _list(await _c.getData('/v1/holdings'))) _holding(_m(h))];
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async =>
      [for (final h in _list(await _c.getData('/v1/accounts/$accountId/holdings'))) _holding(_m(h))];
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      parseAssetAllocationData(_m(await _c.getData('/v1/portfolio/allocation')));
}

class LocalServerMovementRepository implements MovementRepository {
  LocalServerMovementRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async =>
      [for (final m in _list(await _c.getData('/v1/movements/recent'))) _movement(_m(m))];
  @override
  Future<MovementVm?> getMovement(Id id) async {
    final d = await _c.getData('/v1/movements/$id');
    return d == null ? null : _movement(_m(d));
  }
}

class LocalServerDcaRepository implements DcaRepository {
  LocalServerDcaRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<DcaReminderVm>> listDueReminders() async =>
      [for (final r in _list(await _c.getData('/v1/dca/reminders/due'))) _reminder(_m(r))];
  @override
  Future<List<DcaPlanVm>> listPlans() async =>
      [for (final p in _list(await _c.getData('/v1/dca/plans'))) _plan(_m(p))];
  @override
  Future<void> markExecutedAsProposal(Id reminderId) async {
    await _c.postData('/v1/dca/reminders/$reminderId/mark-executed-as-proposal');
  }
}

class LocalServerQuoteRepository implements QuoteRepository {
  LocalServerQuoteRepository(this._c);
  final DevApiClient _c;
  @override
  Future<QuoteStatusSummaryVm> getQuoteSummary() async =>
      _quoteSummary(_m(await _c.getData('/v1/quotes/summary')));
}

class LocalServerAiProposalRepository implements AiProposalRepository {
  LocalServerAiProposalRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<AiProposalVm>> listPending() async =>
      [for (final p in _list(await _c.getData('/v1/ai/proposals/pending'))) _proposal(_m(p))];
  @override
  Future<AiProposalVm?> getProposal(Id id) async {
    final d = await _c.getData('/v1/ai/proposals/$id');
    return d == null ? null : _proposal(_m(d));
  }
  @override
  Future<void> approveAtomicGroup(Id groupId) async {
    await _c.postData('/v1/ai/atomic-groups/$groupId/approve');
  }
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {
    await _c.postData('/v1/ai/atomic-groups/$groupId/reject',
        body: reason == null ? null : {'reason': reason});
  }
  @override
  Future<void> createFromText(String text) async {
    await _c.postData('/v1/ai/proposals/from-text', body: {'text': text});
  }
}

class LocalServerSnapshotRepository implements SnapshotRepository {
  LocalServerSnapshotRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<NetWorthSnapshotVm>> listSnapshots() async =>
      [for (final s in _list(await _c.getData('/v1/snapshots'))) _snapshot(_m(s))];
  @override
  Future<NetWorthSnapshotVm?> getLatest() async {
    final all = await listSnapshots();
    return all.isEmpty ? null : all.first;
  }
}
