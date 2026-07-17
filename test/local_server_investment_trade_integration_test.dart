// 真实 local_server 联调（2026-07-17 任务单 §12）：
// 账户+标的创建 → 买入（确认前不变、确认后 现金-103/数量+10/成本+103）→
// 卖出（现金+38、剩 6、平均成本按比例释放、saleResult 映射）→
// 跨币种卖出（两条不同时点 FX，断言用 asOf<=occurredAt 的历史汇率而非未来汇率）。
// 只写临时账本（由 tools/frontend_local_server_smoke.ps1 启动的进程），不碰生产数据。
import 'package:finwealth/core/format.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

void main() {
  test(
    'manual investment trades write the real ledger with server-fixed sale results',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final instrumentRepo = LocalServerInstrumentRepository(client);
      final movementRepo = LocalServerMovementRepository(client);
      final portfolioRepo = LocalServerPortfolioRepository(client);

      // —— 1. 现金账户（期初 1000.00 CNY）、持仓账户、标的 ——
      final cash = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '成交联调资金账户',
          accountType: AccountType.bank,
          defaultCurrency: 'CNY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '1000.00', currency: 'CNY'),
        ),
      );
      final hold = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '成交联调持仓账户',
          accountType: AccountType.brokerage,
          defaultCurrency: 'CNY',
          balanceMode: 'holdings',
        ),
      );
      final inst = await instrumentRepo.createInstrument(
        const CreateInstrumentInput(
          type: InstrumentType.fund,
          displayName: '联调指数基金',
          quoteCurrency: 'CNY',
        ),
      );
      expect(inst.id, isNotEmpty);

      Future<String> cashBalance([
        Id? accountId,
        String currency = 'CNY',
      ]) async {
        final a = await accountRepo.getAccount(accountId ?? cash.id);
        return a!.cashBalances[currency] ?? '0';
      }

      Future<List<HoldingVm>> holdings() =>
          portfolioRepo.listHoldingsByAccount(hold.id);

      expect(await cashBalance(), '1000.00');
      expect(await holdings(), isEmpty);

      // —— 2/3. 确认前不变：草稿 + 提交复核都不动现金/持仓/成本 ——
      final draft = _map(
        await client.postData(
          '/v1/movements/drafts',
          body: {
            'type': 'buy',
            'occurredAt': '2026-07-14T02:00:00Z',
            'title': '联调未确认买入',
            'entries': [
              {
                'accountId': cash.id,
                'amount': '55.00',
                'currency': 'CNY',
                'direction': 'out',
                'role': 'source',
              },
              {
                'accountId': hold.id,
                'instrumentId': inst.id,
                'amount': '5',
                'currency': 'CNY',
                'direction': 'in',
                'role': 'destination',
              },
            ],
          },
        ),
      );
      expect(await cashBalance(), '1000.00', reason: '草稿不得动余额');
      expect(await holdings(), isEmpty, reason: '草稿不得产生持仓');
      await client.postData('/v1/movements/${draft['id']}/submit-review');
      expect(await cashBalance(), '1000.00', reason: '提交复核不得动余额');
      expect(await holdings(), isEmpty, reason: '提交复核不得产生持仓');
      // 该候选保持待确认状态，不再确认（后续断言全部基于自建账户，不受影响）。

      // —— 2/4. 买入（repo 全流水线）：价款 100 + fee 2 + tax 1、数量 10 ——
      final buyResult = await movementRepo.createInvestmentTrade(
        InvestmentTradeInput(
          side: TradeSide.buy,
          cashAccountId: cash.id,
          holdingAccountId: hold.id,
          instrumentId: inst.id,
          quantity: '10',
          principalAmount: '100.00',
          cashCurrency: 'CNY',
          holdingCurrency: 'CNY',
          feeAmount: '2.00',
          taxAmount: '1.00',
          occurredAt: '2026-07-14T03:00:00Z',
          title: '联调买入',
        ),
      );
      expect(buyResult.ledgerWrite, isTrue);
      expect(await cashBalance(), '897.00', reason: '现金减少 103（含费税）');
      final afterBuy = await holdings();
      expect(afterBuy, hasLength(1));
      expect(afterBuy.single.quantity, '10');
      expect(afterBuy.single.costBasisTotal!.amount, '103.00');
      expect(afterBuy.single.costBasisTotal!.currency, 'CNY');

      // —— 5/6/7. 卖出：数量 4、毛回款 40、fee 1 + tax 1 ——
      final sellResult = await movementRepo.createInvestmentTrade(
        InvestmentTradeInput(
          side: TradeSide.sell,
          cashAccountId: cash.id,
          holdingAccountId: hold.id,
          instrumentId: inst.id,
          quantity: '4',
          principalAmount: '40.00',
          cashCurrency: 'CNY',
          holdingCurrency: 'CNY',
          feeAmount: '1.00',
          taxAmount: '1.00',
          occurredAt: '2026-07-15T03:00:00Z',
          title: '联调卖出',
        ),
      );
      expect(sellResult.ledgerWrite, isTrue);
      expect(await cashBalance(), '935.00', reason: '现金净增 38');
      final afterSell = await holdings();
      expect(afterSell.single.quantity, '6');
      // 平均成本按比例释放：103 × 6/10 = 61.80。
      expect(afterSell.single.costBasisTotal!.amount, '61.80');

      // Movement 详情映射服务端固化 saleResult。
      final sellMovement = await movementRepo.getMovement(
        sellResult.confirmedMovementIds.single,
      );
      final sale = sellMovement!.saleResult!;
      expect(sale.costBasisMethod, 'average_cost');
      expect(sale.realizedPnlStatus, RealizedPnlStatus.calculated);
      expect(compareDecimal(sale.grossProceeds.amount, '40.00'), 0);
      expect(compareDecimal(sale.feeAndTaxTotal.amount, '2.00'), 0);
      expect(compareDecimal(sale.netProceeds.amount, '38.00'), 0);
      expect(compareDecimal(sale.costBasisReleased!.amount, '41.20'), 0);
      expect(compareDecimal(sale.realizedPnl!.amount, '-3.20'), 0);
      expect(sale.realizedPnl!.currency, 'CNY');

      // —— 8/9. 跨币种：USD 成本持仓、CNY 回款；历史 FX 优先于未来 FX ——
      final usdCash = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '成交联调美元账户',
          accountType: AccountType.bank,
          defaultCurrency: 'USD',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '1000.00', currency: 'USD'),
        ),
      );
      final holdUsd = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '成交联调美股持仓账户',
          accountType: AccountType.brokerage,
          defaultCurrency: 'USD',
          balanceMode: 'holdings',
        ),
      );
      final usdInst = await instrumentRepo.createInstrument(
        const CreateInstrumentInput(
          type: InstrumentType.equity,
          displayName: '联调美元标的',
          quoteCurrency: 'USD',
        ),
      );
      final usdBuy = await movementRepo.createInvestmentTrade(
        InvestmentTradeInput(
          side: TradeSide.buy,
          cashAccountId: usdCash.id,
          holdingAccountId: holdUsd.id,
          instrumentId: usdInst.id,
          quantity: '5',
          principalAmount: '50.00',
          cashCurrency: 'USD',
          holdingCurrency: 'USD',
          occurredAt: '2026-07-14T05:00:00Z',
          title: '联调美元买入',
        ),
      );
      expect(usdBuy.ledgerWrite, isTrue);

      // 两条时间不同的 CNY→USD 汇率：历史（成交前）与未来（成交后）。
      for (final (rate, asOf) in const [
        ('0.14', '2026-07-15T00:00:00Z'),
        ('0.20', '2026-07-17T00:00:00Z'),
      ]) {
        final refresh = _map(
          await client.postData(
            '/v1/quotes/refresh',
            body: {
              'mode': 'manual',
              'requestedAt': '2026-07-17T01:00:00Z',
              'fxRates': [
                {
                  'baseCurrency': 'CNY',
                  'quoteCurrency': 'USD',
                  'rate': rate,
                  'asOf': asOf,
                  'source': 'integration_test',
                },
              ],
            },
          ),
        );
        expect(refresh['status'], 'success', reason: 'rate=$rate');
      }

      // 卖出 2 股，成交时间 2026-07-16：介于两条汇率之间。
      final fxSell = await movementRepo.createInvestmentTrade(
        InvestmentTradeInput(
          side: TradeSide.sell,
          cashAccountId: cash.id,
          holdingAccountId: holdUsd.id,
          instrumentId: usdInst.id,
          quantity: '2',
          principalAmount: '20.00',
          cashCurrency: 'CNY',
          holdingCurrency: 'USD',
          occurredAt: '2026-07-16T00:00:00Z',
          title: '联调跨币种卖出',
        ),
      );
      expect(fxSell.ledgerWrite, isTrue);
      expect(await cashBalance(), '955.00', reason: 'CNY 现金 +20');

      final fxMovement = await movementRepo.getMovement(
        fxSell.confirmedMovementIds.single,
      );
      final fxSale = fxMovement!.saleResult!;
      expect(fxSale.realizedPnlStatus, RealizedPnlStatus.calculatedWithFx);
      // 释放成本：50 USD × 2/5 = 20.00 USD。
      expect(fxSale.costBasisReleased!.currency, 'USD');
      expect(compareDecimal(fxSale.costBasisReleased!.amount, '20.00'), 0);
      // 使用历史汇率 0.14（asOf 2026-07-15 <= occurredAt），而不是未来的 0.20。
      final basis = fxSale.fxBasis!;
      expect(basis.rate, '0.14');
      expect(basis.asOf, '2026-07-15T00:00:00Z');
      expect(basis.baseCurrency, 'CNY');
      expect(basis.quoteCurrency, 'USD');
      // 折算净回款 20.00 CNY × 0.14 = 2.80 USD；盈亏 = 2.80 − 20.00 = −17.20 USD。
      expect(fxSale.netProceedsInCostBasisCurrency!.currency, 'USD');
      expect(
        compareDecimal(fxSale.netProceedsInCostBasisCurrency!.amount, '2.80'),
        0,
      );
      expect(fxSale.realizedPnl!.currency, 'USD');
      expect(compareDecimal(fxSale.realizedPnl!.amount, '-17.20'), 0);
      // 未来汇率若被误用：折算净回款会是 4.00，而不是 2.80。
      expect(
        compareDecimal(fxSale.netProceedsInCostBasisCurrency!.amount, '4.00'),
        isNot(0),
      );
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
