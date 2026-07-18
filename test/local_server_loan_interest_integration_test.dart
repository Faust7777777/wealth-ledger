// 真实 local_server 联调：贷款条款 / 应计利息 / 还款计划（2026-07-18 任务单必测）。
// 债务 400、年利率 36.5%、365 基准：截至 01-31 应计 12；下一期（02-01，计划 100）
// 预计利息 12.4 / 本金 87.6；确认前债务不变、确认后 412；拒绝后可重建；
// 同一幂等键重放不产生第二条候选；两期计划数值与 loan_interest 类型映射。
import 'dart:convert';

import 'package:finwealth/core/format.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

void main() {
  test(
    'loan terms, accrued interest and repayment schedule flow on the real server',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final loanRepo = LocalServerLoanRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);
      final movementRepo = LocalServerMovementRepository(client);

      final cash = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '贷款联调还款账户',
          accountType: AccountType.bank,
          defaultCurrency: 'CNY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '1000.00', currency: 'CNY'),
        ),
      );
      final loan = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '贷款联调助学贷款',
          accountType: AccountType.loan,
          defaultCurrency: 'CNY',
          balanceMode: 'liability',
          openingBalance: Money(amount: '-400', currency: 'CNY'),
        ),
      );

      await loanRepo.updateLiabilityTerms(
        loan.id,
        LiabilityTermsInput(
          liabilityType: LiabilityType.studentLoan,
          annualRate: '0.365',
          rateType: LiabilityRateType.fixed,
          dayCountBasis: 365,
          interestStartDate: '2026-01-01',
          maturityDate: '2026-12-01',
          repaymentStartDate: '2026-02-01',
          nextDueDate: '2026-02-01',
          scheduledPayment: const Money(amount: '100', currency: 'CNY'),
          paymentAccountId: cash.id,
        ),
      );

      Future<LiabilityPositionVm> position({String? throughDate}) async {
        final positions = await loanRepo.listLiabilityPositions(
          throughDate: throughDate,
        );
        return positions.firstWhere((p) => p.accountId == loan.id);
      }

      Future<String> debt() async =>
          (await position()).outstandingPrincipal.amount;

      // 必测 1/2：截至 01-31 应计 12；下一期预计利息 12.4 / 本金 87.6，
      // 不得误用查询截止日的 12。
      final p = await position(throughDate: '2026-01-31');
      expect(compareDecimal(p.outstandingPrincipal.amount, '400'), 0);
      expect(compareDecimal(p.accruedInterest.amount, '12'), 0);
      expect(p.nextPayment.dueDate, '2026-02-01');
      expect(compareDecimal(p.nextPayment.scheduledAmount.amount, '100'), 0);
      expect(compareDecimal(p.nextPayment.projectedInterest.amount, '12.4'), 0);
      expect(
        compareDecimal(p.nextPayment.projectedPrincipal.amount, '87.6'),
        0,
      );

      // 必测 6：两期计划。
      final schedule = await loanRepo.getRepaymentSchedule(loan.id, limit: 2);
      expect(schedule.items, hasLength(2));
      final first = schedule.items[0];
      expect(compareDecimal(first.interest.amount, '12.4'), 0);
      expect(compareDecimal(first.principal.amount, '87.6'), 0);
      expect(compareDecimal(first.closingBalance.amount, '312.4'), 0);
      final second = schedule.items[1];
      expect(compareDecimal(second.interest.amount, '8.7472'), 0);
      expect(compareDecimal(second.principal.amount, '91.2528'), 0);
      expect(compareDecimal(second.closingBalance.amount, '221.1472'), 0);

      // 必测 4（幂等）：同一 Idempotency-Key 重放不产生第二条候选。
      Future<(int, Map<String, dynamic>)> rawPropose(String key) async {
        final res = await http.post(
          Uri.parse('$_baseUrl/v1/accounts/${loan.id}/loan-interest-proposals'),
          headers: {'content-type': 'application/json', 'idempotency-key': key},
          body: jsonEncode({'throughDate': '2026-01-31'}),
        );
        return (
          res.statusCode,
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map)
              .cast<String, dynamic>(),
        );
      }

      const idemKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa0718';
      final (s1, b1) = await rawPropose(idemKey);
      expect(s1, 200, reason: '$b1');
      final groupId = '${(b1['data'] as Map)['id']}';
      final (s2, b2) = await rawPropose(idemKey);
      expect(s2, 200, reason: '$b2');
      expect('${(b2['data'] as Map)['id']}', groupId, reason: '幂等重放返回同一候选');

      // pending 状态可见；新幂等键重复提交 → 409。
      expect((await position()).terms.hasPendingInterest, isTrue);
      await expectLater(
        loanRepo.proposeLoanInterest(loan.id, throughDate: '2026-01-31'),
        throwsA(isA<ApiConflictException>()),
      );

      // 必测 3：确认前债务仍 400；确认后 412；付款账户不变。
      expect(compareDecimal(await debt(), '400'), 0);
      final confirm = await aiRepo.approveAtomicGroup(groupId);
      expect(confirm.ledgerWrite, isTrue);
      expect(compareDecimal(await debt(), '412'), 0);
      final cashAfter = await accountRepo.getAccount(cash.id);
      expect(cashAfter!.cashBalances['CNY'], '1000.00', reason: '付款账户不变');

      // 必测 5：loan_interest 类型映射（不落 adjustment 兜底）。
      final movementId = confirm.confirmedMovementIds.single;
      final movement = await movementRepo.getMovement(movementId);
      expect(movement!.type, MovementType.loanInterest);

      // 必测 4（拒绝）：拒绝后 pending 清除且可重新创建。
      final again = await loanRepo.proposeLoanInterest(
        loan.id,
        throughDate: '2026-02-15',
      );
      expect((await position()).terms.hasPendingInterest, isTrue);
      await aiRepo.rejectAtomicGroup(again.id, reason: '联调拒绝');
      expect((await position()).terms.hasPendingInterest, isFalse);
      final recreated = await loanRepo.proposeLoanInterest(
        loan.id,
        throughDate: '2026-02-15',
      );
      expect(recreated.status, AiGroupStatus.pending);
      await aiRepo.rejectAtomicGroup(recreated.id, reason: '联调收尾清理');
      expect((await position()).terms.hasPendingInterest, isFalse);
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
