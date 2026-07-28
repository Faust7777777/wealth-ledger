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
  loanInterest,
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
    this.supportedCurrencies = const [],
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

  /// 账户可持有的现金币种（服务端 supportedCurrencies；缺失时按默认币种）。
  final List<CurrencyCode> supportedCurrencies;
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
    this.openingBalance,
  });
  final String displayName;
  final AccountType accountType;
  final CurrencyCode defaultCurrency;
  final String balanceMode; // cash_balance | holdings | liability | mixed
  final bool includeInNetWorth;
  final String? institutionName;

  /// 期初余额（仅创建时使用；负债欠款已在 UI 层转为账本负数）。
  /// null → openingBalances: []。编辑（PATCH）不发送、不覆盖既有余额。
  final Money? openingBalance;
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
    this.instrumentId = '',
    this.costBasisTotal,
    this.marketValue,
    this.dayChange,
    this.unrealizedPnl,
    this.unrealizedPnlRate,
  });
  final Id id;
  final Id accountId;

  /// 持仓对应的标的 ID（卖出腿必须回填；缺失时为空串）。
  final Id instrumentId;
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
    this.saleResult,
    this.costBasisFx,
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

  /// 卖出确认后服务端固化的成交结果（只读；旧记录可缺失）。
  final InvestmentSaleResultVm? saleResult;

  /// 跨币种买入固化的成本换算依据（只读；旧记录可缺失）。
  final ExecutionFxBasisVm? costBasisFx;
}

/// 已实现盈亏状态（wire: calculated / calculated_with_fx /
/// cost_basis_unavailable / currency_mismatch）。
enum RealizedPnlStatus {
  calculated,
  calculatedWithFx,
  costBasisUnavailable,
  currencyMismatch,
}

/// 成交时实际使用的汇率依据（服务端固化，不可变；前端只展示不重算）。
class ExecutionFxBasisVm {
  const ExecutionFxBasisVm({
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.rate,
    required this.asOf,
    required this.sourceRateId,
    required this.source,
    this.sourceUrl,
    required this.inverted,
  });
  final CurrencyCode baseCurrency;
  final CurrencyCode quoteCurrency;
  final DecimalString rate;
  final IsoDateTime asOf;
  final Id sourceRateId; // 内部 ID，仅供调试/测试；UI 不展示
  final String source;
  final String? sourceUrl;
  final bool inverted;
}

/// 卖出成交结果（服务端按平均成本法固化；前端禁止重算或用浮点推导）。
class InvestmentSaleResultVm {
  const InvestmentSaleResultVm({
    required this.costBasisMethod,
    required this.grossProceeds,
    required this.feeAndTaxTotal,
    required this.netProceeds,
    this.costBasisReleased,
    this.realizedPnl,
    this.netProceedsInCostBasisCurrency,
    this.fxBasis,
    required this.realizedPnlStatus,
  });
  final String costBasisMethod; // average_cost
  final Money grossProceeds;
  final Money feeAndTaxTotal;
  final Money netProceeds;
  final Money? costBasisReleased;
  final Money? realizedPnl;
  final Money? netProceedsInCostBasisCurrency;
  final ExecutionFxBasisVm? fxBasis;
  final RealizedPnlStatus realizedPnlStatus;
}

/// 投资标的（服务端 Instrument 投影；买入只能从中选择，不手填 wire ID）。
class InstrumentVm {
  const InstrumentVm({
    required this.id,
    required this.type,
    this.symbol,
    required this.displayName,
    required this.quoteCurrency,
    this.market,
  });
  final Id id;
  final InstrumentType type;
  final String? symbol;
  final String displayName;
  final CurrencyCode quoteCurrency;
  final String? market;
}

/// 新建标的输入（POST /v1/instruments；仅登记标的，不连券商、不同步行情）。
class CreateInstrumentInput {
  const CreateInstrumentInput({
    required this.type,
    required this.displayName,
    required this.quoteCurrency,
    this.symbol,
  });
  final InstrumentType type;
  final String displayName;
  final CurrencyCode quoteCurrency;
  final String? symbol;
}

/// 持仓导入/数量校准输入（POST /v1/accounts/{id}/holding-adjustment-proposals）。
/// 只生成待确认调整，target 为期望的当前数量（可为 0 = 清零）。
class HoldingAdjustmentInput {
  const HoldingAdjustmentInput({
    required this.instrumentId,
    required this.targetQuantity,
    this.asOf,
    this.note,
  });
  final Id instrumentId;
  final DecimalString targetQuantity; // 非负，≤8 位小数
  final IsoDateTime? asOf;
  final String? note;
}

// ———————————— 贷款条款 / 负债头寸 / 还款计划 ————————————
// 对齐 openapi LiabilityTerms* / LiabilityPosition / LoanRepaymentSchedule。
// 计算结果（应计利息、下一期拆分、逐期计划）一律来自服务端，前端不得自行计算。

enum LiabilityType { studentLoan, mortgage, consumerLoan, creditCard, other }

enum LiabilityRateType { fixed, floating }

/// 贷款条款输入（PATCH /v1/accounts/{id}/liability-terms；整表替换）。
/// 年利率为 wire 十进制小数（3.65% → '0.0365'），转换在 UI 层完成。
class LiabilityTermsInput {
  const LiabilityTermsInput({
    required this.liabilityType,
    required this.annualRate,
    required this.rateType,
    required this.dayCountBasis,
    required this.interestStartDate,
    required this.maturityDate,
    required this.repaymentStartDate,
    required this.nextDueDate,
    this.repaymentFrequency = 'monthly',
    required this.scheduledPayment,
    required this.paymentAccountId,
  });
  final LiabilityType liabilityType;
  final DecimalString annualRate;
  final LiabilityRateType rateType;
  final int dayCountBasis; // 360 | 365
  final IsoDate interestStartDate;
  final IsoDate maturityDate;
  final IsoDate repaymentStartDate;
  final IsoDate nextDueDate;
  final String repaymentFrequency; // monthly
  final Money scheduledPayment;
  final Id paymentAccountId;
}

/// 服务端贷款条款（含应计指针与待确认利息指针）。
class LiabilityTermsVm {
  const LiabilityTermsVm({
    required this.liabilityType,
    required this.annualRate,
    required this.rateType,
    required this.dayCountBasis,
    required this.interestStartDate,
    required this.maturityDate,
    required this.repaymentStartDate,
    required this.nextDueDate,
    required this.scheduledPayment,
    required this.paymentAccountId,
    required this.lastInterestAccruedThrough,
    this.pendingLoanInterestMovementId,
    this.pendingLoanInterestThroughDate,
    this.lastLoanInterestMovementId,
  });
  final LiabilityType liabilityType;
  final DecimalString annualRate;
  final LiabilityRateType rateType;
  final int dayCountBasis;
  final IsoDate interestStartDate;
  final IsoDate maturityDate;
  final IsoDate repaymentStartDate;
  final IsoDate nextDueDate;
  final Money scheduledPayment;
  final Id paymentAccountId;
  final IsoDate lastInterestAccruedThrough;
  final Id? pendingLoanInterestMovementId;
  final IsoDate? pendingLoanInterestThroughDate;
  final Id? lastLoanInterestMovementId;

  /// 已有待确认利息：禁重复提交、禁改条款，引导去审核。
  bool get hasPendingInterest => pendingLoanInterestMovementId != null;
}

/// 下一期合同计划金额的预计拆分（服务端计算）。
class LiabilityNextPaymentVm {
  const LiabilityNextPaymentVm({
    required this.dueDate,
    required this.scheduledAmount,
    required this.projectedInterest,
    required this.projectedPrincipal,
  });
  final IsoDate dueDate;
  final Money scheduledAmount;
  final Money projectedInterest;
  final Money projectedPrincipal;
}

/// 负债头寸（GET /v1/liability-positions；计算结果的权威来源）。
class LiabilityPositionVm {
  const LiabilityPositionVm({
    required this.accountId,
    required this.accountName,
    required this.currency,
    required this.terms,
    required this.outstandingPrincipal,
    required this.accruedThrough,
    required this.accrualDays,
    required this.accruedInterest,
    required this.nextPayment,
    required this.status,
  });
  final Id accountId;
  final String accountName;
  final CurrencyCode currency;
  final LiabilityTermsVm terms;
  final Money outstandingPrincipal;
  final IsoDate accruedThrough;
  final int accrualDays;
  final Money accruedInterest;
  final LiabilityNextPaymentVm nextPayment;
  final String status; // active | matured | paid_off
}

/// 还款计划单期（kind=balloon 展示为「到期还款」）。
class LoanRepaymentScheduleItemVm {
  const LoanRepaymentScheduleItemVm({
    required this.sequence,
    required this.dueDate,
    required this.openingBalance,
    required this.interest,
    required this.principal,
    required this.payment,
    required this.closingBalance,
    required this.kind,
  });
  final int sequence;
  final IsoDate dueDate;
  final Money openingBalance;
  final Money interest;
  final Money principal;
  final Money payment;
  final Money closingBalance;
  final String kind; // scheduled | balloon
}

/// 有界还款计划投影（GET /v1/accounts/{id}/repayment-schedule）。
class LoanRepaymentScheduleVm {
  const LoanRepaymentScheduleVm({
    required this.accountId,
    required this.currency,
    required this.maturityDate,
    required this.items,
    required this.hasMore,
  });
  final Id accountId;
  final CurrencyCode currency;
  final IsoDate maturityDate;
  final List<LoanRepaymentScheduleItemVm> items;
  final bool hasMore;
}

enum TradeSide { buy, sell }

/// 手动投资成交输入。买入 principal=成交价款，卖出 principal=毛回款；
/// 现金实际变动与成本增减由服务端按 principal±fee±tax 计算，前端不推导。
class InvestmentTradeInput {
  const InvestmentTradeInput({
    required this.side,
    required this.cashAccountId,
    required this.holdingAccountId,
    required this.instrumentId,
    required this.quantity,
    required this.principalAmount,
    required this.cashCurrency,
    required this.holdingCurrency,
    this.feeAmount,
    this.taxAmount,
    this.occurredAt,
    required this.title,
    this.note,
  });
  final TradeSide side;
  final Id cashAccountId;
  final Id holdingAccountId;
  final Id instrumentId;
  final DecimalString quantity;
  final DecimalString principalAmount;
  final CurrencyCode cashCurrency;
  final CurrencyCode holdingCurrency; // 标的报价币种（由所选标的派生）
  final DecimalString? feeAmount; // 空或 0 → 不发送费用腿
  final DecimalString? taxAmount; // 空或 0 → 不发送税费腿
  final IsoDateTime? occurredAt; // null → 仓库用当前时间
  final String title;
  final String? note;
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

/// 真实成交输入（openapi DcaExecutionInput）。
/// 计划金额只是提醒/默认值，绝不复用为成交数量；本命令只生成候选，不下单。
class DcaExecutionInput {
  const DcaExecutionInput({
    required this.holdingAccountId,
    required this.quantity,
    required this.totalCost,
    required this.quoteCurrency,
    this.executedAt,
  });

  /// 持仓账户（balanceMode=holdings|mixed 的未归档账户）。
  final Id holdingAccountId;

  /// 实际买到的数量（>0，≤8 位小数的十进制字符串）。
  final DecimalString quantity;

  /// 实际总成本（>0；资金账户币种）。
  final Money totalCost;

  /// 标的/持仓分录的报价币种（默认持仓账户 defaultCurrency，可改）。
  final CurrencyCode quoteCurrency;

  /// 成交时间（可空；省略由服务端取当前时间；提供须带时区）。
  final IsoDateTime? executedAt;
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
    this.proposedMovement,
    this.isValid = true,
  });
  final Id id;
  final String title;
  final AiOperation operation;
  final AiGroupStatus status;
  final List<AiFieldDiffVm> diffs;
  final List<String> warnings;

  /// 结构化候选记录（proposedMovements[0]）；待补全候选为 null。
  final MovementVm? proposedMovement;

  /// 服务端 validation.isValid（缺失按 true 兼容旧候选）。
  final bool isValid;

  /// 待补全：无结构化记录或校验未过，只能编辑/拒绝，不能直接确认。
  bool get needsCompletion => proposedMovement == null || !isValid;
}

class AiProposalVm {
  const AiProposalVm({
    required this.id,
    required this.status,
    required this.sourceLabel,
    required this.groups,
    this.summary,
    this.modelName,
  });
  final Id id;
  final AiProposalStatus status;
  final String sourceLabel; // 证据来源摘要（可见）
  final List<AiAtomicGroupVm> groups;
  final String? summary;

  /// source.modelName：仅供诊断，不在候选主卡片展示。
  final String? modelName;
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

/// 汇率读模型（GET /v1/fx-rates；只读，用于估值状态说明，不做前端换算）。
class FxRateVm {
  const FxRateVm({
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.rate,
    required this.asOf,
    required this.status,
  });
  final CurrencyCode baseCurrency;
  final CurrencyCode quoteCurrency;
  final DecimalString rate;
  final IsoDateTime asOf;
  final QuoteStatus status;
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
    this.nextChargeDate,
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

  /// 下次扣费日（与开始日期是两个概念）。null → 服务端按开始日期排期。
  /// 本月已续费的场景由用户直接填下个月日期。
  final IsoDate? nextChargeDate;
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
    required this.nextChargeDate,
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

  /// 下次扣费日；编辑时以服务端返回值初始化，null（如已取消）则不发送。
  final IsoDate? nextChargeDate;
  final SubscriptionDurationVm? duration; // 与 endDate 互斥
  final IsoDate? endDate;
  final bool autoRenew;
  final int reminderDaysBefore;
  final SubscriptionStatus status;
  final String? note;
}

// —— 订阅到期扫描（HTTP_API_V1 §7A due-scan）——
// 显式调用命令：只批量生成 pending_review 候选，不自动确认、不扣款、不推进日期。

enum SubscriptionDueScanSkipReason {
  alreadyPending,
  paymentAccountUnavailable,
  paymentCurrencyUnsupported,
}

/// 被跳过的到期项：already_pending 去审核即可，payment_* 需先修订阅/账户。
class SubscriptionDueScanSkipVm {
  const SubscriptionDueScanSkipVm({
    required this.subscriptionId,
    required this.scheduledChargeDate,
    required this.reason,
  });
  final Id subscriptionId;
  final IsoDate scheduledChargeDate;
  final SubscriptionDueScanSkipReason reason;
}

/// 扫描新建的候选：atomic group 附所属订阅与计费期（AI_PROPOSAL_SCHEMA §3）。
class SubscriptionDueScanCreatedVm {
  const SubscriptionDueScanCreatedVm({
    required this.group,
    required this.subscriptionId,
    required this.scheduledChargeDate,
  });
  final AiAtomicGroupVm group;
  final Id subscriptionId;
  final IsoDate scheduledChargeDate;
}

/// 一次 due-scan 的结果。limit 只限新建数量：
/// remainingEligibleCount 统计仅因 limit 未创建的项，hasMore 等价于其 > 0。
class SubscriptionDueScanResultVm {
  const SubscriptionDueScanResultVm({
    required this.throughDate,
    required this.createdCount,
    required this.alreadyPendingCount,
    required this.blockedCount,
    required this.remainingEligibleCount,
    required this.hasMore,
    this.created = const [],
    this.skipped = const [],
  });
  final IsoDate throughDate;
  final int createdCount;
  final int alreadyPendingCount;
  final int blockedCount;
  final int remainingEligibleCount;
  final bool hasMore;
  final List<SubscriptionDueScanCreatedVm> created;
  final List<SubscriptionDueScanSkipVm> skipped;
}

// ———— Pi Agent 控制中枢（/v1/agent/**）————

enum AgentConversationStatus { active, archived }

enum AgentMessageRole { user, assistant, system }

enum AgentMessageStatus { queued, streaming, completed, failed }

enum AgentMemoryStatus { suggested, active, rejected }

enum AgentEventType {
  runQueued,
  runStarted,
  messageDelta,
  toolStarted,
  toolCompleted,
  runCompleted,
  runFailed,
  unknown,
}

/// Agent 运行时状态。configured=false 表示服务端没有可用模型。
class AgentStatusVm {
  const AgentStatusVm({
    required this.configured,
    required this.modelCount,
    this.primaryConversationId,
  });
  final bool configured;
  final int modelCount;
  final Id? primaryConversationId;
}

/// 服务端允许的模型；不含任何凭据或 provider 配置路径。
class AgentModelVm {
  const AgentModelVm({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.supportsImages,
  });
  final String id;
  final String provider;
  final String displayName;
  final bool supportsImages;
}

class AgentConversationVm {
  const AgentConversationVm({
    required this.id,
    required this.title,
    required this.isPrimary,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.selectedModelId,
  });
  final Id id;
  final String title;
  final bool isPrimary;
  final AgentConversationStatus status;
  final IsoDateTime createdAt;
  final IsoDateTime updatedAt;
  final String? selectedModelId;
}

class AgentMessageVm {
  const AgentMessageVm({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.text,
    required this.status,
    required this.createdAt,
    this.runId,
    this.completedAt,
    this.errorCode,
    this.attachmentIds = const [],
  });
  final Id id;
  final Id conversationId;
  final AgentMessageRole role;
  final String text;
  final AgentMessageStatus status;
  final IsoDateTime createdAt;
  final Id? runId;
  final IsoDateTime? completedAt;
  final String? errorCode;
  final List<Id> attachmentIds;

  AgentMessageVm copyWith({
    String? text,
    AgentMessageStatus? status,
    Id? runId,
    String? errorCode,
  }) => AgentMessageVm(
    id: id,
    conversationId: conversationId,
    role: role,
    text: text ?? this.text,
    status: status ?? this.status,
    createdAt: createdAt,
    runId: runId ?? this.runId,
    completedAt: completedAt,
    errorCode: errorCode ?? this.errorCode,
    attachmentIds: attachmentIds,
  );
}

/// 附件安全元数据；不含服务端存储路径。
class AgentAttachmentVm {
  const AgentAttachmentVm({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required this.createdAt,
  });
  final Id id;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
  final IsoDateTime createdAt;
}

class AgentMemoryVm {
  const AgentMemoryVm({
    required this.id,
    required this.content,
    required this.reason,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
  final Id id;
  final String content;
  final String reason;
  final AgentMemoryStatus status;
  final IsoDateTime createdAt;
  final IsoDateTime updatedAt;
}

/// POST 消息后的受理结果（202）：本地据此立刻建立 queued 占位。
class AgentRunAcceptedVm {
  const AgentRunAcceptedVm({
    required this.runId,
    required this.userMessageId,
    required this.assistantMessageId,
  });
  final Id runId;
  final Id userMessageId;
  final Id assistantMessageId;
}

/// 规范化 SSE 事件。cursor 用于断线续接；不含 tool payload 与隐藏推理。
class AgentEventVm {
  const AgentEventVm({
    required this.cursor,
    required this.type,
    this.runId,
    this.userMessageId,
    this.assistantMessageId,
    this.delta,
    this.toolName,
    this.isError,
    this.code,
  });
  final int cursor;
  final AgentEventType type;
  final Id? runId;
  final Id? userMessageId;
  final Id? assistantMessageId;
  final String? delta;
  final String? toolName;
  final bool? isError;
  final String? code;
}

enum AgentQuoteCandidateKind { instrument, fx }

enum AgentQuoteCandidateStatus { suggested, applied, rejected }

/// Agent 从网页整理出的单条报价/汇率候选。
/// suggested 不改变任何估值；只有用户「采用」才会写入权威报价缓存。
class AgentQuoteCandidateVm {
  const AgentQuoteCandidateVm({
    required this.id,
    required this.kind,
    required this.asOf,
    required this.source,
    required this.sourceUrl,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.instrumentId,
    this.price,
    this.currency,
    this.baseCurrency,
    this.quoteCurrency,
    this.rate,
    this.appliedAt,
  });
  final Id id;
  final AgentQuoteCandidateKind kind;
  final IsoDateTime asOf;
  final String source;
  final String sourceUrl;
  final AgentQuoteCandidateStatus status;
  final IsoDateTime createdAt;
  final IsoDateTime updatedAt;

  /// kind=instrument 时给出标的与报价。
  final Id? instrumentId;
  final DecimalString? price;
  final CurrencyCode? currency;

  /// kind=fx 时给出币对与汇率。
  final CurrencyCode? baseCurrency;
  final CurrencyCode? quoteCurrency;
  final DecimalString? rate;
  final IsoDateTime? appliedAt;
}
