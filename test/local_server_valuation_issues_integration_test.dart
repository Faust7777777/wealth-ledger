// 真实 local_server 联调：权威估值问题接口（2026-07-18 任务单必测 1–4）。
// 多跳 USDT → USD → CNY 可用时不得报缺少路径；缺报价报 missing_quote；
// 无任何换算路径才报 missing_fx_path；外币现金 stale FX 报 stale_fx。
// 报价/汇率经公开的 POST /v1/quotes/refresh 载荷种入；只写临时账本。
import 'package:finwealth/core/format.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

void main() {
  test(
    'valuation issues come from the server read model with real fx paths',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final instrumentRepo = LocalServerInstrumentRepository(client);
      final portfolioRepo = LocalServerPortfolioRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);

      // —— 种入汇率：USDT→USD→CNY 两段 fresh（多跳）；JPY→CNY 为 stale；XAU 无任何路径 ——
      await client.postData(
        '/v1/quotes/refresh',
        body: {
          'mode': 'manual',
          'fxRates': [
            {
              'baseCurrency': 'USDT',
              'quoteCurrency': 'USD',
              'rate': '1.0',
              'status': 'fresh',
            },
            {
              'baseCurrency': 'USD',
              'quoteCurrency': 'CNY',
              'rate': '7.2',
              'status': 'fresh',
            },
            {
              'baseCurrency': 'JPY',
              'quoteCurrency': 'CNY',
              'rate': '0.05',
              'status': 'stale',
            },
          ],
        },
      );

      final usdtAccount = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '估值联调交易所',
          accountType: AccountType.exchange,
          defaultCurrency: 'USDT',
          balanceMode: 'mixed',
          openingBalance: Money(amount: '123.45', currency: 'USDT'),
        ),
      );
      // XAU 单独开户：账户 supportedCurrencies 必须包含标的报价币种。
      final xauAccount = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '估值联调无路径账户',
          accountType: AccountType.exchange,
          defaultCurrency: 'XAU',
          balanceMode: 'mixed',
        ),
      );
      final jpyAccount = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '估值联调日元账户',
          accountType: AccountType.bank,
          defaultCurrency: 'JPY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '1000.00', currency: 'JPY'),
        ),
      );

      final btc = await instrumentRepo.createInstrument(
        const CreateInstrumentInput(
          type: InstrumentType.crypto,
          displayName: '估值联调BTC',
          quoteCurrency: 'USDT',
          symbol: 'VALBTC',
        ),
      );
      final gold = await instrumentRepo.createInstrument(
        const CreateInstrumentInput(
          type: InstrumentType.other,
          displayName: '估值联调无路径标的',
          quoteCurrency: 'XAU',
          symbol: 'VALGOLD',
        ),
      );

      Future<void> importHolding(
        String accountId,
        String instrumentId,
        String quantity,
      ) async {
        final group = await portfolioRepo.proposeHoldingAdjustment(
          accountId,
          HoldingAdjustmentInput(
            instrumentId: instrumentId,
            targetQuantity: quantity,
          ),
        );
        final result = await aiRepo.approveAtomicGroup(group.id);
        expect(result.ledgerWrite, isTrue);
      }

      await importHolding(usdtAccount.id, btc.id, '0.00076078');
      await importHolding(xauAccount.id, gold.id, '2');

      // 无路径标的本身有 fresh 报价：问题必须落在换算路径上而不是报价缺失。
      await client.postData(
        '/v1/quotes/refresh',
        body: {
          'mode': 'manual',
          'quotes': [
            {
              'instrumentId': gold.id,
              'price': '1',
              'currency': 'XAU',
              'status': 'fresh',
            },
          ],
        },
      );

      Future<List<ValuationIssueVm>> issuesFor(String accountId) async => [
        for (final i in await portfolioRepo.listValuationIssues())
          if (i.accountId == accountId) i,
      ];

      // —— 必测 1：USDT 有 USDT/USD + USD/CNY 两段 fresh，现金不得报缺少路径 ——
      var usdtIssues = await issuesFor(usdtAccount.id);
      expect(
        usdtIssues.where((i) => i.assetKind == ValuationAssetKind.cash),
        isEmpty,
        reason: '多跳 USDT → USD → CNY 可用时不得报现金缺少路径',
      );

      // —— 必测 3：BTC 无报价 → missing_quote（不是 missing_fx_path），保留原始数量 ——
      final btcIssue = usdtIssues.singleWhere(
        (i) => i.assetKind == ValuationAssetKind.holding,
      );
      expect(btcIssue.reason, ValuationIssueReason.missingQuote);
      expect(btcIssue.status, ValuationIssueStatus.unpriceable);
      expect(compareDecimal(btcIssue.quantity, '0.00076078'), 0);
      expect(btcIssue.targetCurrency, 'CNY');

      // —— 必测 2：有报价但没有任何到本位币的路径 → missing_fx_path ——
      final goldIssue = (await issuesFor(
        xauAccount.id,
      )).singleWhere((i) => i.assetKind == ValuationAssetKind.holding);
      expect(goldIssue.reason, ValuationIssueReason.missingFxPath);
      expect(goldIssue.sourceCurrency, 'XAU');
      expect(goldIssue.targetCurrency, 'CNY');
      expect(compareDecimal(goldIssue.quantity, '2'), 0);

      // —— 必测 4：外币现金 stale FX → stale_fx ——
      final jpyIssue = (await issuesFor(jpyAccount.id)).single;
      expect(jpyIssue.assetKind, ValuationAssetKind.cash);
      expect(jpyIssue.reason, ValuationIssueReason.staleFx);
      expect(jpyIssue.status, ValuationIssueStatus.stale);
      expect(jpyIssue.sourceCurrency, 'JPY');
      expect(compareDecimal(jpyIssue.quantity, '1000.00'), 0);

      // 概览的问题计数与问题列表一致地非零（低强调入口的显示依据）。
      final overview = await portfolioRepo.getOverview();
      expect(overview.pendingSummary.quoteProblemCount, greaterThan(0));

      // —— 补齐 BTC 报价：整个账户经多跳换算后不再有任何问题 ——
      await client.postData(
        '/v1/quotes/refresh',
        body: {
          'mode': 'manual',
          'quotes': [
            {
              'instrumentId': btc.id,
              'price': '60000',
              'currency': 'USDT',
              'status': 'fresh',
            },
          ],
        },
      );
      usdtIssues = await issuesFor(usdtAccount.id);
      expect(
        usdtIssues,
        isEmpty,
        reason: 'BTC/USDT 有报价且 USDT → USD → CNY 可换算时该账户不应再有问题',
      );
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
