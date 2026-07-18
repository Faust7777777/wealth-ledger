// 真实 local_server 联调：AI 文本整理（2026-07-18 任务单必测）。
// provider 关闭（默认）：纯文本 → 待补全候选，不能 approve；
// 结构化输入路径：expense 18 CNY 候选确认前余额不变、approve 后 -18；
// 同一幂等键重放同一 proposal 不重复生成。只写临时账本。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

void main() {
  test(
    'text organization produces reviewable candidates on the real server',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);

      final cash = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: 'AI 文本联调现金',
          accountType: AccountType.cash,
          defaultCurrency: 'CNY',
          balanceMode: 'cash_balance',
          openingBalance: Money(amount: '100.00', currency: 'CNY'),
        ),
      );

      Future<String> balance() async =>
          (await accountRepo.getAccount(cash.id))!.cashBalances['CNY']!;

      Future<Set<String>> pendingIds() async => {
        for (final p in await aiRepo.listPending()) p.id,
      };

      // —— provider 关闭：纯文本 → 待补全候选（必测 3）——
      final before = await pendingIds();
      await aiRepo.createFromText('午餐 18 元');
      final afterText = await aiRepo.listPending();
      final textProposal = afterText.firstWhere((p) => !before.contains(p.id));
      final incompleteGroup = textProposal.groups.single;
      expect(incompleteGroup.needsCompletion, isTrue);
      expect(incompleteGroup.proposedMovement, isNull);
      expect(incompleteGroup.title, contains('待补全'));

      // 待补全不能 approve；余额不动。
      await expectLater(
        aiRepo.approveAtomicGroup(incompleteGroup.id),
        throwsA(isA<Exception>()),
      );
      expect(await balance(), '100.00');
      await aiRepo.rejectAtomicGroup(incompleteGroup.id, reason: '联调清理');

      // —— 幂等（必测 5）：同一键重放同一 proposal，不重复生成 ——
      Future<(int, Map<String, dynamic>)> rawFromText(String key) async {
        final res = await http.post(
          Uri.parse('$_baseUrl/v1/ai/proposals/from-text'),
          headers: {'content-type': 'application/json', 'idempotency-key': key},
          body: jsonEncode({'text': '打车 30 元'}),
        );
        return (
          res.statusCode,
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map)
              .cast<String, dynamic>(),
        );
      }

      const idemKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbb0719';
      final baseline = await pendingIds();
      final (s1, b1) = await rawFromText(idemKey);
      expect(s1, 200, reason: '$b1');
      final proposalId = '${(b1['data'] as Map)['id']}';
      final (s2, b2) = await rawFromText(idemKey);
      expect(s2, 200, reason: '$b2');
      expect(
        '${(b2['data'] as Map)['id']}',
        proposalId,
        reason: '重放同一 proposal',
      );
      final afterReplay = await pendingIds();
      expect(afterReplay.difference(baseline), {proposalId}, reason: '不重复生成候选');
      final replayProposal = (await aiRepo.listPending()).firstWhere(
        (p) => p.id == proposalId,
      );
      await aiRepo.rejectAtomicGroup(
        replayProposal.groups.single.id,
        reason: '联调清理',
      );

      // —— 结构化路径（必测 1/2 的服务器侧语义）：expense 18 CNY ——
      final structured = _m(
        await client.postData(
          '/v1/ai/proposals/from-text',
          body: {
            'text': '午餐 18 元',
            'movement': {
              'type': 'expense',
              'occurredAt': '2026-07-19T04:00:00Z',
              'title': '午餐',
              'entries': [
                {
                  'accountId': cash.id,
                  'amount': '18',
                  'currency': 'CNY',
                  'direction': 'out',
                  'role': 'source',
                },
              ],
            },
          },
        ),
      );
      final structuredProposal = parseAiProposalData(structured);
      final group = structuredProposal.groups.single;
      expect(group.needsCompletion, isFalse);
      final movement = group.proposedMovement!;
      expect(movement.type, MovementType.expense);
      expect(movement.displayAmount!.amount, '18');
      expect(movement.displayAmount!.currency, 'CNY');
      expect(movement.entries.single.accountId, cash.id);

      // 确认前余额不变；approve 后减少 18。
      expect(await balance(), '100.00');
      final confirm = await aiRepo.approveAtomicGroup(group.id);
      expect(confirm.ledgerWrite, isTrue);
      expect(await balance(), '82.00');
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}

Map<String, dynamic> _m(Object? o) => (o as Map).cast<String, dynamic>();
