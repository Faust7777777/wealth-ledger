// 真实 local_server 联调：多资产持仓快照（2026-07-29 任务单）。
// 一次提交 BTC/ETH/USDT → 一个审核组；确认前持仓与 overview 不变；
// unchanged 不生成 movement；整组确认后三项一起生效；全部未变化 → 409。
// 只写临时账本。
import 'package:finwealth/core/format.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

void main() {
  test(
    'multi-asset holding snapshots review and confirm as one atomic group',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final instrumentRepo = LocalServerInstrumentRepository(client);
      final portfolioRepo = LocalServerPortfolioRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);

      final okx = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '快照联调交易所',
          accountType: AccountType.exchange,
          defaultCurrency: 'USDT',
          balanceMode: 'mixed',
        ),
      );
      Future<InstrumentVm> instrument(String name, String symbol) =>
          instrumentRepo.createInstrument(
            CreateInstrumentInput(
              type: InstrumentType.crypto,
              displayName: name,
              quoteCurrency: 'USDT',
              symbol: symbol,
            ),
          );
      final btc = await instrument('快照联调BTC', 'BTC');
      final eth = await instrument('快照联调ETH', 'ETH');
      final usdt = await instrument('快照联调USDT', 'USDT');

      Future<Map<String, String>> quantities() async {
        final holdings = await portfolioRepo.listHoldingsByAccount(okx.id);
        return {for (final h in holdings) h.instrumentId: h.quantity};
      }

      // 1. 一次提交三项 → 一个审核组，每项一条候选记录。
      final group = await portfolioRepo.proposeHoldingSnapshot(
        okx.id,
        positions: [
          HoldingSnapshotPositionInput(
            instrumentId: btc.id,
            targetQuantity: '0.25',
          ),
          HoldingSnapshotPositionInput(
            instrumentId: eth.id,
            targetQuantity: '3.2',
          ),
          HoldingSnapshotPositionInput(
            instrumentId: usdt.id,
            targetQuantity: '1250',
          ),
        ],
        note: 'OKX 持仓快照',
      );
      expect(group.status, AiGroupStatus.pending);
      expect(group.proposedMovements, hasLength(3));
      for (final m in group.proposedMovements) {
        expect(m.tags, contains('holding_snapshot'));
        expect(m.holdingAdjustment, isNotNull);
        expect(m.atomicGroupId, group.id);
      }
      // 确认前不得产生任何持仓。
      expect(await quantities(), isEmpty);

      // 2. 整组确认：三项一起生效。
      final result = await aiRepo.approveAtomicGroup(group.id);
      expect(result.ledgerWrite, isTrue);
      expect(result.confirmedMovementIds, hasLength(3));
      final applied = await quantities();
      expect(compareDecimal(applied[btc.id]!, '0.25'), 0);
      expect(compareDecimal(applied[eth.id]!, '3.2'), 0);
      expect(compareDecimal(applied[usdt.id]!, '1250'), 0);

      // 3. 只有一项变化时，未变化的项进 skippedPositions 且不生成 movement。
      final second = await portfolioRepo.proposeHoldingSnapshot(
        okx.id,
        positions: [
          HoldingSnapshotPositionInput(
            instrumentId: btc.id,
            targetQuantity: '0.4',
          ),
          HoldingSnapshotPositionInput(
            instrumentId: eth.id,
            targetQuantity: '3.2',
          ),
        ],
      );
      expect(second.proposedMovements, hasLength(1));
      expect(
        second.proposedMovements.single.holdingAdjustment!.instrumentId,
        btc.id,
      );
      expect(second.skippedPositions.single.instrumentId, eth.id);
      expect(second.skippedPositions.single.reason, 'unchanged');
      await aiRepo.approveAtomicGroup(second.id);
      expect(compareDecimal((await quantities())[btc.id]!, '0.4'), 0);

      // 4. 全部数量未变化 → 409。
      await expectLater(
        portfolioRepo.proposeHoldingSnapshot(
          okx.id,
          positions: [
            HoldingSnapshotPositionInput(
              instrumentId: btc.id,
              targetQuantity: '0.4',
            ),
          ],
        ),
        throwsA(isA<ApiConflictException>()),
      );

      // 5. 清零：目标数量 0 可提交并在确认后归零。
      final zeroed = await portfolioRepo.proposeHoldingSnapshot(
        okx.id,
        positions: [
          HoldingSnapshotPositionInput(
            instrumentId: eth.id,
            targetQuantity: '0',
          ),
        ],
      );
      await aiRepo.approveAtomicGroup(zeroed.id);
      final afterZero = (await quantities())[eth.id];
      expect(
        afterZero == null || compareDecimal(afterZero, '0') == 0,
        isTrue,
        reason: '清零后应为 0 或持仓消失，实际 $afterZero',
      );
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
