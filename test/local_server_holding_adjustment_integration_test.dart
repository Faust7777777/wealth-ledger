// 真实 local_server 联调：持仓导入/校准（2026-07-18 任务单）。
// 增加 → 减少 → 清零，各自经 AI 审核确认后生效；确认前持仓不变；
// 重复提交 409；不支持的报价币种 400。只写临时账本。
import 'package:finwealth/core/format.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

void main() {
  test(
    'holding adjustments import, correct and clear quantities through review',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final instrumentRepo = LocalServerInstrumentRepository(client);
      final portfolioRepo = LocalServerPortfolioRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);

      // OKX 式交易所账户（USDT 计价）+ 两个标的。
      final okx = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '校准联调交易所',
          accountType: AccountType.exchange,
          defaultCurrency: 'USDT',
          balanceMode: 'mixed',
        ),
      );
      final btc = await instrumentRepo.createInstrument(
        const CreateInstrumentInput(
          type: InstrumentType.crypto,
          displayName: '校准联调BTC',
          quoteCurrency: 'USDT',
          symbol: 'BTC',
        ),
      );
      final btcQuoted = await instrumentRepo.createInstrument(
        const CreateInstrumentInput(
          type: InstrumentType.crypto,
          displayName: '校准联调外币标的',
          quoteCurrency: 'BTC',
        ),
      );

      Future<String?> quantity() async {
        final holdings = await portfolioRepo.listHoldingsByAccount(okx.id);
        for (final h in holdings) {
          if (h.instrumentId == btc.id) return h.quantity;
        }
        return null;
      }

      Future<void> proposeAndApprove(String target) async {
        final group = await portfolioRepo.proposeHoldingAdjustment(
          okx.id,
          HoldingAdjustmentInput(instrumentId: btc.id, targetQuantity: target),
        );
        expect(group.status, AiGroupStatus.pending);
        final result = await aiRepo.approveAtomicGroup(group.id);
        expect(result.ledgerWrite, isTrue, reason: 'target=$target');
      }

      // 1. 导入：确认前持仓不变，确认后 0.00076078。
      final importGroup = await portfolioRepo.proposeHoldingAdjustment(
        okx.id,
        HoldingAdjustmentInput(
          instrumentId: btc.id,
          targetQuantity: '0.00076078',
          note: '联调导入',
        ),
      );
      expect(importGroup.status, AiGroupStatus.pending);
      expect(await quantity(), isNull, reason: '确认前不得产生持仓');

      // 2. 重复提交：同一持仓已有待确认调整 → 409。
      await expectLater(
        portfolioRepo.proposeHoldingAdjustment(
          okx.id,
          HoldingAdjustmentInput(instrumentId: btc.id, targetQuantity: '2'),
        ),
        throwsA(isA<ApiConflictException>()),
      );

      final importResult = await aiRepo.approveAtomicGroup(importGroup.id);
      expect(importResult.ledgerWrite, isTrue);
      expect(await quantity(), '0.00076078');

      // 3. 增加 → 10；减少 → 6；清零 → 0/消失。
      await proposeAndApprove('10');
      expect(await quantity(), '10');
      await proposeAndApprove('6');
      expect(await quantity(), '6');
      await proposeAndApprove('0');
      final cleared = await quantity();
      expect(
        cleared == null || compareDecimal(cleared, '0') == 0,
        isTrue,
        reason: '清零后数量应为 0 或持仓消失，实际 $cleared',
      );

      // 4. 报价币种不被账户支持 → 400。
      await expectLater(
        portfolioRepo.proposeHoldingAdjustment(
          okx.id,
          HoldingAdjustmentInput(
            instrumentId: btcQuoted.id,
            targetQuantity: '1',
          ),
        ),
        throwsA(isA<ApiValidationException>()),
      );
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
