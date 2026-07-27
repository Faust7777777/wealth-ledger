// 真实 local_server 联调：固定收益条款与计息（2026-07-18 任务单必测 1–4）。
// 10000 CNY / 3.65% / 365 / 2026-01-01→2026-01-31 应计 30 CNY；
// 同名义利率下月复利高于单利；确认前收款余额与本金持仓不变，确认后才入账；
// 已有待确认利息时重复提交与改条款均 409。只写临时账本。
import 'package:finwealth/core/format.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

void main() {
  test(
    'fixed yield terms, accrual and interest proposals flow on the real server',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final instrumentRepo = LocalServerInstrumentRepository(client);
      final portfolioRepo = LocalServerPortfolioRepository(client);
      final yieldRepo = LocalServerYieldRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);

      final payout = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '收益联调收款账户',
          accountType: AccountType.bank,
          defaultCurrency: 'CNY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '100.00', currency: 'CNY'),
        ),
      );
      final custody = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '收益联调持有账户',
          accountType: AccountType.brokerage,
          defaultCurrency: 'CNY',
          balanceMode: 'mixed',
        ),
      );

      Future<String> holdingIdFor(String instrumentName, String symbol) async {
        final instrument = await instrumentRepo.createInstrument(
          CreateInstrumentInput(
            type: InstrumentType.fund,
            displayName: instrumentName,
            quoteCurrency: 'CNY',
            symbol: symbol,
          ),
        );
        final group = await portfolioRepo.proposeHoldingAdjustment(
          custody.id,
          HoldingAdjustmentInput(
            instrumentId: instrument.id,
            targetQuantity: '10000',
          ),
        );
        final result = await aiRepo.approveAtomicGroup(group.id);
        expect(result.ledgerWrite, isTrue);
        final holdings = await portfolioRepo.listHoldingsByAccount(custody.id);
        return holdings.firstWhere((h) => h.instrumentId == instrument.id).id;
      }

      Future<String> payoutBalance() async =>
          (await accountRepo.getAccount(payout.id))!.cashBalances['CNY']!;

      Future<String> quantityOf(String holdingId) async =>
          (await portfolioRepo.listHoldingsByAccount(
            custody.id,
          )).firstWhere((h) => h.id == holdingId).quantity;

      Future<YieldPositionVm> positionOf(
        String holdingId, {
        required String throughDate,
      }) async => (await yieldRepo.listYieldPositions(
        throughDate: throughDate,
      )).firstWhere((p) => p.holdingId == holdingId);

      YieldTermsInput terms({
        required YieldInterestMethod method,
        required YieldCompoundingFrequency frequency,
      }) => YieldTermsInput(
        principal: const Money(amount: '10000', currency: 'CNY'),
        // 用户输入 3.65% → wire 0.0365（纯字符串移位，不经 double）。
        annualRate: '0.0365',
        rateType: YieldRateType.fixed,
        interestMethod: method,
        dayCountBasis: 365,
        compoundingFrequency: frequency,
        interestStartDate: '2026-01-01',
        maturityDate: '2027-01-01',
        payoutAccountId: payout.id,
      );

      // —— 必测 1：单利 10000 CNY / 3.65% / 365，30 天应计 30 CNY ——
      final simpleHolding = await holdingIdFor('收益联调单利定存', 'YSIMPLE');
      final updated = await yieldRepo.updateYieldTerms(
        simpleHolding,
        terms(
          method: YieldInterestMethod.simple,
          frequency: YieldCompoundingFrequency.none,
        ),
      );
      expect(updated.yieldTerms, isNotNull);
      expect(updated.yieldTerms!.annualRate, '0.0365');
      expect(
        updated.yieldTerms!.compoundingFrequency,
        YieldCompoundingFrequency.none,
      );

      final simple31 = await positionOf(
        simpleHolding,
        throughDate: '2026-01-31',
      );
      expect(simple31.accrualDays, 30);
      expect(compareDecimal(simple31.accruedInterest.amount, '30'), 0);
      expect(simple31.accruedInterest.currency, 'CNY');
      expect(simple31.status, YieldPositionStatus.active);
      expect(compareDecimal(simple31.terms.principal.amount, '10000'), 0);

      // —— 必测 2：同名义利率，月复利高于单利（前端只展示服务端结果）——
      final compoundHolding = await holdingIdFor('收益联调复利定存', 'YCOMP');
      await yieldRepo.updateYieldTerms(
        compoundHolding,
        terms(
          method: YieldInterestMethod.compound,
          frequency: YieldCompoundingFrequency.monthly,
        ),
      );
      const horizon = '2026-12-31';
      final simpleYear = await positionOf(simpleHolding, throughDate: horizon);
      final compoundYear = await positionOf(
        compoundHolding,
        throughDate: horizon,
      );
      expect(
        compareDecimal(
          compoundYear.accruedInterest.amount,
          simpleYear.accruedInterest.amount,
        ),
        greaterThan(0),
        reason:
            '月复利 ${compoundYear.accruedInterest.amount} 应高于单利 ${simpleYear.accruedInterest.amount}',
      );

      // —— 必测 3：确认前收款余额与本金持仓不变 ——
      expect(await payoutBalance(), '100.00');
      final group = await yieldRepo.proposeInterest(
        simpleHolding,
        throughDate: '2026-01-31',
        note: '联调计息',
      );
      expect(group.status, AiGroupStatus.pending);
      expect(await payoutBalance(), '100.00', reason: '确认前收款余额不得变化');
      expect(compareDecimal(await quantityOf(simpleHolding), '10000'), 0);

      // —— 必测 4：已有待确认利息 → 重复提交 409；同时条款也不可改 ——
      await expectLater(
        yieldRepo.proposeInterest(simpleHolding, throughDate: '2026-01-31'),
        throwsA(isA<ApiConflictException>()),
      );
      await expectLater(
        yieldRepo.updateYieldTerms(
          simpleHolding,
          terms(
            method: YieldInterestMethod.simple,
            frequency: YieldCompoundingFrequency.none,
          ),
        ),
        throwsA(isA<ApiConflictException>()),
      );
      final pendingPosition = await positionOf(
        simpleHolding,
        throughDate: '2026-01-31',
      );
      expect(pendingPosition.terms.hasPendingInterest, isTrue);
      expect(pendingPosition.terms.pendingInterestThroughDate, '2026-01-31');

      // —— 确认后：只增加收款账户余额，本金 holding 数量不变 ——
      final confirm = await aiRepo.approveAtomicGroup(group.id);
      expect(confirm.ledgerWrite, isTrue);
      expect(await payoutBalance(), '130.00');
      expect(compareDecimal(await quantityOf(simpleHolding), '10000'), 0);
      final afterConfirm = await positionOf(
        simpleHolding,
        throughDate: '2026-01-31',
      );
      expect(afterConfirm.terms.hasPendingInterest, isFalse);
      expect(afterConfirm.terms.lastAccruedThrough, '2026-01-31');
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
