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

enum CategoryKind { income, expense, transfer, investment, liability, system }

enum DcaReminderStatus { due, overdue, snoozed, recorded, skipped }

enum AiOperation { create, modify, correction, merge, classify }

enum AiTargetType {
  account,
  holding,
  movement,
  dcaPlan,
  category,
  counterparty,
}

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
    this.isArchived = false,
    this.defaultCurrency = 'CNY',
    this.balanceMode = 'cash_balance',
    this.includeInNetWorth = true,
    this.institutionName,
    this.cashBalances = const {},
  });
  final Id id;
  final String displayName;
  final AccountType accountType;
  final bool isLiability;
  final ValuedMoney? value; // CNY 估值；unpriceable → quality 标记
  final String? note;
  final bool isArchived;
  final CurrencyCode defaultCurrency;
  final String balanceMode; // cash_balance | holdings | liability | mixed
  final bool includeInNetWorth;
  final String? institutionName;
  final Map<CurrencyCode, DecimalString> cashBalances; // 各币种现金余额（local_server）
}

/// 创建账户输入（对齐 APPLICATION_INTERFACES_V1.CreateAccountInput）。
class CreateAccountInput {
  const CreateAccountInput({
    required this.displayName,
    required this.accountType,
    required this.defaultCurrency,
    required this.balanceMode,
    this.includeInNetWorth = true,
    this.institutionName,
  });
  final String displayName;
  final AccountType accountType;
  final CurrencyCode defaultCurrency;
  final String balanceMode; // cash_balance | holdings | liability | mixed
  final bool includeInNetWorth;
  final String? institutionName;
}

/// 用户维护的分类词表。不是封闭目录；AI 可读取并填充，用户确认后才入账。
class CategoryVm {
  const CategoryVm({
    required this.id,
    required this.displayName,
    required this.kind,
    this.parentId,
    this.isSystem = false,
    this.aiDescription,
  });
  final Id id;
  final String displayName;
  final CategoryKind kind;
  final Id? parentId;
  final bool isSystem;
  final String? aiDescription;
}

class CreateCategoryInput {
  const CreateCategoryInput({
    required this.displayName,
    required this.kind,
    this.parentId,
    this.aiDescription,
  });
  final String displayName;
  final CategoryKind kind;
  final Id? parentId;
  final String? aiDescription;
}

/// 对手方词表。名字不要求穷举；后续合并/归档基于这些实体继续做。
class CounterpartyVm {
  const CounterpartyVm({
    required this.id,
    required this.displayName,
    this.aliases = const [],
    this.normalizedName,
    this.categoryHintId,
    this.isUserMerged = false,
  });
  final Id id;
  final String displayName;
  final List<String> aliases;
  final String? normalizedName;
  final Id? categoryHintId;
  final bool isUserMerged;
}

class CreateCounterpartyInput {
  const CreateCounterpartyInput({
    required this.displayName,
    this.aliases = const [],
    this.normalizedName,
    this.categoryHintId,
  });
  final String displayName;
  final List<String> aliases;
  final String? normalizedName;
  final Id? categoryHintId;
}

/// 手动记账输入（income/expense 单分录 MVP）。direction/role 由仓库按 type 推导。
class ManualRecordInput {
  const ManualRecordInput({
    required this.type,
    required this.accountId,
    required this.amount,
    required this.currency,
    required this.title,
    this.description,
    this.occurredAt,
    this.categoryId,
    this.counterpartyId,
  });
  final MovementType type; // income | expense（单分录）
  final Id accountId;
  final DecimalString amount; // 正数 decimal 字符串
  final CurrencyCode currency;
  final String title;
  final String? description;
  final IsoDateTime? occurredAt; // null → 仓库用当前时间
  final Id? categoryId;
  final Id? counterpartyId;
}

/// 转账输入（同币种、同额双分录 MVP；暂不做跨币种折算）。
class TransferInput {
  const TransferInput({
    required this.fromAccountId,
    required this.toAccountId,
    required this.amount,
    required this.currency,
    required this.title,
    this.note,
    this.occurredAt,
  });
  final Id fromAccountId;
  final Id toAccountId;
  final DecimalString amount; // 正数 decimal 字符串
  final CurrencyCode currency;
  final String title;
  final String? note;
  final IsoDateTime? occurredAt;
}

/// 余额观察/校准输入：对（实际余额 − 当前余额）的差额生成 adjustment 候选。
class ReconcileInput {
  const ReconcileInput({
    required this.accountId,
    required this.currency,
    required this.currentBalance,
    required this.observedBalance,
    this.note,
  });
  final Id accountId;
  final CurrencyCode currency;
  final DecimalString currentBalance;
  final DecimalString observedBalance;
  final String? note;
}

/// 已确认记录更正输入：MVP 只支持单分录金额更正，确认后新增 correction movement，不改原记录。
class CreateCorrectionInput {
  const CreateCorrectionInput({
    required this.targetMovementId,
    required this.oldAmount,
    required this.newAmount,
    required this.reason,
  });
  final Id targetMovementId;
  final DecimalString oldAmount;
  final DecimalString newAmount;
  final String reason;
}

/// 账本能力（/v1/ledger/bootstrap.data.capabilities 的前端投影）。
/// 写入口 gating 的唯一口径：UI 不得按 DataSourceMode 猜测能力。
class LedgerCapabilitiesVm {
  const LedgerCapabilitiesVm({
    required this.dataSourceMode,
    required this.canWriteConfirmedLedger,
    required this.canCreateAccount,
    required this.canRecordMovement,
    required this.canConfirmProposal,
    required this.canPersistPendingProposal,
    required this.proposalPersistence,
    this.canManageSubscriptions = false,
  });

  final String dataSourceMode;
  final bool canWriteConfirmedLedger;
  final bool canCreateAccount;
  final bool canRecordMovement;
  final bool canConfirmProposal;
  final bool canPersistPendingProposal;
  final String proposalPersistence; // none / memory / file

  /// 订阅管理写入口 gating（创建/编辑/取消/生成扣费候选）。缺失时 fail-closed。
  final bool canManageSubscriptions;

  /// fail-closed 默认：能力未知（加载中 / 请求失败 / 字段缺失）时一律只读。
  static const locked = LedgerCapabilitiesVm(
    dataSourceMode: 'unknown',
    canWriteConfirmedLedger: false,
    canCreateAccount: false,
    canRecordMovement: false,
    canConfirmProposal: false,
    canPersistPendingProposal: false,
    proposalPersistence: 'none',
    canManageSubscriptions: false,
  );
}

/// 确认 atomic group 的结果。UI 必须以 ledgerWrite 为准，不能自行猜测是否已入账。
class ConfirmResultVm {
  const ConfirmResultVm({
    required this.atomicGroupId,
    required this.confirmedMovementIds,
    required this.snapshotInvalidated,
    required this.ledgerWrite,
  });
  final Id atomicGroupId;
  final List<Id> confirmedMovementIds;
  final bool snapshotInvalidated;
  final bool ledgerWrite;
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
  const TransactionAmountBreakdownVm({
    this.gross,
    this.savings,
    required this.paid,
  });
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
    this.entries = const [],
    this.categoryId,
    this.counterpartyId,
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
  final List<MovementEntryVm> entries;
  final Id? categoryId;
  final Id? counterpartyId;
}

/// 分录（双分录账本的一条腿）：方向 in/out、角色、所属账户。
class MovementEntryVm {
  const MovementEntryVm({
    required this.accountId,
    required this.amount,
    required this.currency,
    required this.direction,
    required this.role,
    this.instrumentId,
  });
  final Id accountId;
  final DecimalString amount;
  final CurrencyCode currency;
  final String direction; // in | out
  // source | destination | fee | discount | pnl | tax | adjustment
  final String role;
  final String? instrumentId;
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

class CreateDcaPlanInput {
  const CreateDcaPlanInput({
    required this.displayName,
    required this.targetInstrumentId,
    required this.fundingAccountId,
    required this.plannedAmount,
    required this.frequency,
    required this.nextDueDate,
    this.note,
  });
  final String displayName;
  final String targetInstrumentId;
  final Id fundingAccountId;
  final Money plannedAmount;
  final DcaFrequency frequency;
  final IsoDate nextDueDate;
  final String? note;
}

class UpdateDcaPlanPatch {
  const UpdateDcaPlanPatch({
    this.displayName,
    this.targetInstrumentId,
    this.fundingAccountId,
    this.plannedAmount,
    this.frequency,
    this.nextDueDate,
    this.reminderStatus,
    this.note,
    this.clearNote = false,
  });
  final String? displayName;
  final String? targetInstrumentId;
  final Id? fundingAccountId;
  final Money? plannedAmount;
  final DcaFrequency? frequency;
  final IsoDate? nextDueDate;
  final DcaPlanStatus? reminderStatus;
  final String? note;
  final bool clearNote;
}

class DcaPlanVm {
  const DcaPlanVm({
    required this.id,
    required this.displayName,
    this.targetInstrumentId = '',
    this.fundingAccountId,
    required this.plannedAmount,
    required this.frequency,
    required this.nextDueDate,
    required this.status,
    this.note,
  });
  final Id id;
  final String displayName;
  final String targetInstrumentId;
  final Id? fundingAccountId;
  final Money plannedAmount;
  final DcaFrequency frequency;
  final IsoDate nextDueDate;
  final DcaPlanStatus status;
  final String? note;
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

class QuoteRefreshResultVm {
  const QuoteRefreshResultVm({
    required this.status,
    required this.completedAt,
    this.quoteCount = 0,
    this.fxRateCount = 0,
    this.errors = const [],
  });
  final String status; // success | partial_success | failed | offline
  final IsoDateTime completedAt;
  final int quoteCount;
  final int fxRateCount;
  final List<String> errors;

  bool get hasProblems =>
      status == 'partial_success' ||
      status == 'failed' ||
      status == 'offline' ||
      errors.isNotEmpty;
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

// ———————————— 订阅管理（Subscriptions） ————————————
// 对齐 finwealth-backend 契约：openapi Subscription / DATA_SCHEMA 9A / HTTP_API 7A。
// 订阅计划不是已发生流水；charge-proposal 只生成 pending_review 候选，确认后才动余额。

enum SubscriptionStatus { trial, active, paused, cancelled, expired }

enum BillingUnit { day, week, month, year }

enum SubscriptionDurationUnit { day, month, year }

/// 计费周期：unit + 正整数 interval（如 每 1 month）。
class SubscriptionBillingCycleVm {
  const SubscriptionBillingCycleVm({
    required this.unit,
    required this.interval,
  });
  final BillingUnit unit;
  final int interval;
}

/// 持续时长：unit + count（与 endDate 二选一）。
class SubscriptionDurationVm {
  const SubscriptionDurationVm({required this.unit, required this.count});
  final SubscriptionDurationUnit unit;
  final int count;
}

/// 订阅（服务端投影）。金额保持原币 Money，日期为本地日历 YYYY-MM-DD 字符串。
class SubscriptionVm {
  const SubscriptionVm({
    required this.id,
    required this.displayName,
    required this.provider,
    this.planName,
    required this.amount,
    required this.paymentAccountId,
    required this.billingCycle,
    required this.billingAnchorDay,
    required this.startDate,
    this.duration,
    this.endDate,
    this.nextChargeDate,
    required this.autoRenew,
    required this.reminderDaysBefore,
    required this.status,
    this.pendingChargeMovementId,
    this.pendingChargeDate,
    this.lastChargeMovementId,
    this.lastChargeDate,
    this.cancelledAt,
    this.note,
  });

  final Id id;
  final String displayName;
  final String provider;
  final String? planName;
  final Money amount;
  final Id paymentAccountId;
  final SubscriptionBillingCycleVm billingCycle;
  final int billingAnchorDay; // 1–31，短月取月末后恢复锚点
  final IsoDate startDate;
  final SubscriptionDurationVm? duration;
  final IsoDate? endDate;
  final IsoDate? nextChargeDate;
  final bool autoRenew;
  final int reminderDaysBefore;
  final SubscriptionStatus status;
  final Id? pendingChargeMovementId;
  final IsoDate? pendingChargeDate;
  final Id? lastChargeMovementId;
  final IsoDate? lastChargeDate;
  final IsoDateTime? cancelledAt;
  final String? note;

  /// 本期已有待确认扣费候选：禁重复生成、禁取消，引导去 AI 审核。
  bool get hasPendingCharge =>
      pendingChargeMovementId != null || pendingChargeDate != null;

  /// 仍有未来扣费的活跃态（trial/active）；paused/cancelled/expired 不显示扣费动作。
  bool get isSchedulable =>
      status == SubscriptionStatus.trial || status == SubscriptionStatus.active;
}

/// 创建订阅输入。duration 与 endDate 互斥（UI 层保证只带其一）。
class CreateSubscriptionInput {
  const CreateSubscriptionInput({
    required this.displayName,
    required this.provider,
    this.planName,
    required this.amount,
    required this.paymentAccountId,
    required this.billingCycle,
    required this.startDate,
    this.duration,
    this.endDate,
    this.autoRenew = true,
    this.reminderDaysBefore = 3,
    this.note,
  });

  final String displayName;
  final String provider;
  final String? planName;
  final Money amount;
  final Id paymentAccountId;
  final SubscriptionBillingCycleVm billingCycle;
  final IsoDate startDate;
  final SubscriptionDurationVm? duration;
  final IsoDate? endDate;
  final bool autoRenew;
  final int reminderDaysBefore;
  final String? note;
}

/// 编辑订阅输入（PATCH，整表单字段替换语义；可空字段传 null 表示清除）。
class UpdateSubscriptionInput {
  const UpdateSubscriptionInput({
    required this.displayName,
    required this.provider,
    required this.planName,
    required this.amount,
    required this.paymentAccountId,
    required this.billingCycle,
    required this.startDate,
    required this.duration,
    required this.endDate,
    required this.autoRenew,
    required this.reminderDaysBefore,
    required this.status,
    required this.note,
  });

  final String displayName;
  final String provider;
  final String? planName;
  final Money amount;
  final Id paymentAccountId;
  final SubscriptionBillingCycleVm billingCycle;
  final IsoDate startDate;
  final SubscriptionDurationVm? duration; // 与 endDate 互斥
  final IsoDate? endDate;
  final bool autoRenew;
  final int reminderDaysBefore;
  final SubscriptionStatus status;
  final String? note;
}
