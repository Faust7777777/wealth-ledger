// Wealth Ledger — frontend view models, aligned to DATA_SCHEMA_V1 / AI_PROPOSAL_SCHEMA_V1.
// 这些是前端渲染用 VM；后端/本地账本到位后由 data/mapping 层从领域 DTO 映射而来。
// 命名与 DATA_SCHEMA_V1 一致；不在前端层发明账本字段。
import '../core/types.dart';

enum AccountType {
  bank,
  brokerage,
  exchange,
  wallet,
  platformWallet,
  virtualCard,
  socialSecurity,
  creditCard,
  loan,
  cash,
  other,
}

enum InstrumentType { cash, equity, fund, crypto, fxCash, receivable, other }

enum MovementType {
  income,
  expense,
  transfer,
  buy,
  sell,
  dividend,
  interest,
  fee,
  adjustment,
  loanDisbursement,
  loanRepayment,
  correction,
}

enum MovementStatus {
  draft,
  pendingReview,
  confirmed,
  inTransit,
  cancelled,
  reversed,
}

enum DcaReminderStatus { due, overdue, snoozed, recorded, skipped }

enum AiOperation { create, modify, correction, merge, classify }

enum AiTargetType { account, holding, movement, dcaPlan, category, counterparty }

enum AiGroupStatus { pending, approved, rejected, edited }

enum AiProposalStatus {
  pending,
  partiallyReviewed,
  approved,
  rejected,
  edited,
  expired,
}

enum AiDiffSeverity { normal, important, danger }

enum AnomalyKind {
  quoteStale,
  unpriceable,
  reconcileNeeded,
  negativeBalance,
  dataAnomaly,
}

enum AnomalySeverity { info, warning, critical }

/// 账户列表项（展示用；CNY 估值来自快照/核心，可能为空）。
class AccountVm {
  const AccountVm({
    required this.id,
    required this.displayName,
    required this.accountType,
    required this.isLiability,
    this.value,
    this.note,
  });
  final Id id;
  final String displayName;
  final AccountType accountType;
  final bool isLiability;
  final ValuedMoney? value; // CNY 估值；unpriceable → quality 标记
  final String? note;
}

class HoldingVm {
  const HoldingVm({
    required this.id,
    required this.accountId,
    required this.symbol,
    required this.displayName,
    required this.quantity,
    required this.quoteStatus,
    this.costBasisTotal,
    this.marketValue,
    this.dayChange,
    this.unrealizedPnl,
    this.unrealizedPnlRate,
  });
  final Id id;
  final Id accountId;
  final String symbol;
  final String displayName;
  final DecimalString quantity;
  final QuoteStatus quoteStatus;
  final Money? costBasisTotal; // null → "成本未记录"
  final ValuedMoney? marketValue; // unpriceable → null（UI 显 —）
  final Money? dayChange;
  final Money? unrealizedPnl;
  final DecimalString? unrealizedPnlRate;
}

/// 交易金额拆分（优惠券/免单仅作字段，非功能模块）。paidAmount = gross − savings。
class TransactionAmountBreakdownVm {
  const TransactionAmountBreakdownVm({this.gross, this.savings, required this.paid});
  final Money? gross;
  final Money? savings;
  final Money paid;
}

class MovementVm {
  const MovementVm({
    required this.id,
    required this.atomicGroupId,
    required this.type,
    required this.status,
    required this.title,
    required this.occurredAt,
    this.displayAmount,
    this.inTransit = false,
    this.description,
    this.amountBreakdown,
  });
  final Id id;
  final Id atomicGroupId;
  final MovementType type;
  final MovementStatus status;
  final String title;
  final IsoDateTime occurredAt;
  final Money? displayAmount; // 展示主额（由核心/映射层给出）
  final bool inTransit;
  final String? description;
  final TransactionAmountBreakdownVm? amountBreakdown;
}

class DcaReminderVm {
  const DcaReminderVm({
    required this.id,
    required this.planId,
    required this.displayName,
    required this.plannedAmount,
    required this.dueDate,
    required this.status,
  });
  final Id id;
  final Id planId;
  final String displayName;
  final Money plannedAmount;
  final IsoDate dueDate;
  final DcaReminderStatus status;
}

enum DcaFrequency { weekly, monthly, custom }

enum DcaPlanStatus { active, snoozed, paused, completed }

class DcaPlanVm {
  const DcaPlanVm({
    required this.id,
    required this.displayName,
    required this.plannedAmount,
    required this.frequency,
    required this.nextDueDate,
    required this.status,
  });
  final Id id;
  final String displayName;
  final Money plannedAmount;
  final DcaFrequency frequency;
  final IsoDate nextDueDate;
  final DcaPlanStatus status;
}

class AiFieldDiffVm {
  const AiFieldDiffVm({
    required this.fieldPath,
    required this.oldValue,
    required this.newValue,
    required this.changed,
    this.severity = AiDiffSeverity.normal,
  });
  final String fieldPath;
  final String? oldValue;
  final String? newValue;
  final bool changed;
  final AiDiffSeverity severity;
}

class AiAtomicGroupVm {
  const AiAtomicGroupVm({
    required this.id,
    required this.title,
    required this.operation,
    required this.status,
    this.diffs = const [],
    this.warnings = const [],
  });
  final Id id;
  final String title;
  final AiOperation operation;
  final AiGroupStatus status;
  final List<AiFieldDiffVm> diffs;
  final List<String> warnings;
}

class AiProposalVm {
  const AiProposalVm({
    required this.id,
    required this.status,
    required this.sourceLabel,
    required this.groups,
    this.summary,
  });
  final Id id;
  final AiProposalStatus status;
  final String sourceLabel; // 证据来源摘要（可见）
  final List<AiAtomicGroupVm> groups;
  final String? summary;
}

class AccountAnomalyVm {
  const AccountAnomalyVm({
    required this.id,
    required this.accountName,
    required this.kind,
    required this.severity,
    required this.detail,
  });
  final Id id;
  final String accountName;
  final AnomalyKind kind;
  final AnomalySeverity severity;
  final String detail;
}

class QuoteStatusSummaryVm {
  const QuoteStatusSummaryVm({
    this.freshCount = 0,
    this.staleCount = 0,
    this.offlineCachedCount = 0,
    this.unpriceableCount = 0,
    this.errorCount = 0,
  });
  final int freshCount;
  final int staleCount;
  final int offlineCachedCount;
  final int unpriceableCount;
  final int errorCount;

  /// 仅全 fresh 才允许首页显示"今日涨跌"，否则只显"较上次快照"。
  bool get allFresh =>
      staleCount == 0 &&
      offlineCachedCount == 0 &&
      unpriceableCount == 0 &&
      errorCount == 0;
}

class PendingSummaryVm {
  const PendingSummaryVm({
    this.aiPendingCount = 0,
    this.accountAnomalyCount = 0,
    this.dcaDueCount = 0,
    this.inTransitCount = 0,
    this.quoteProblemCount = 0,
    this.syncProblemCount = 0,
  });
  final int aiPendingCount;
  final int accountAnomalyCount;
  final int dcaDueCount;
  final int inTransitCount;
  final int quoteProblemCount;
  final int syncProblemCount;

  int get total =>
      aiPendingCount +
      accountAnomalyCount +
      dcaDueCount +
      inTransitCount +
      quoteProblemCount +
      syncProblemCount;
}

class NetWorthSnapshotVm {
  const NetWorthSnapshotVm({
    required this.id,
    required this.snapshotAt,
    required this.grossAssets,
    required this.totalLiabilities,
    required this.netWorth,
    required this.quality,
  });
  final Id id;
  final IsoDateTime snapshotAt;
  final Money grossAssets;
  final Money totalLiabilities;
  final Money netWorth;
  final ValueQuality quality;
}

/// 首页聚合（对齐 APPLICATION_INTERFACES_V1 的 PortfolioOverview）。
class PortfolioOverviewVm {
  const PortfolioOverviewVm({
    required this.pendingSummary,
    required this.quoteStatusSummary,
    required this.primaryHoldings,
    required this.recentMovements,
    this.latestSnapshot,
    this.previousSnapshot,
    this.changeSinceLastSnapshot, // 由核心/映射层给出（前端不做 decimal 运算）
  });
  final NetWorthSnapshotVm? latestSnapshot;
  final NetWorthSnapshotVm? previousSnapshot;
  final PendingSummaryVm pendingSummary;
  final QuoteStatusSummaryVm quoteStatusSummary;
  final List<HoldingVm> primaryHoldings;
  final List<MovementVm> recentMovements;
  final Money? changeSinceLastSnapshot;

  /// 真实空账本：无快照、无持仓、无流水、无待处理。
  bool get isEmpty =>
      latestSnapshot == null &&
      primaryHoldings.isEmpty &&
      recentMovements.isEmpty &&
      pendingSummary.total == 0;
}

class AllocationSliceVm {
  const AllocationSliceVm({
    required this.category,
    required this.percent,
    required this.value,
  });
  final String category;
  final DecimalString percent; // 占总资产，如 "30.5"
  final Money value;
}

/// 资产构成（分母=总资产；负债单列减项）。对齐 APPLICATION_INTERFACES_V1.getAssetAllocation。
class AssetAllocationVm {
  const AssetAllocationVm({
    required this.slices,
    required this.totalAssets,
    required this.totalLiabilities,
    required this.netWorth,
  });
  final List<AllocationSliceVm> slices;
  final Money totalAssets;
  final Money totalLiabilities;
  final Money netWorth;
  bool get isEmpty => slices.isEmpty;
}
