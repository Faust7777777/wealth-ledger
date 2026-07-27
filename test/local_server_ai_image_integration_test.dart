// 真实 local_server 联调：AI 图片整理（2026-07-19 任务单）。
// 合法 PNG 生成候选且确认前余额不变；MIME 与内容不一致 → 400；
// HEIC 等不支持的格式 → 400；同一幂等键重放同一 proposal。只写临时账本。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

/// 1x1 透明 PNG（magic 与 IHDR 合法，可通过服务端文件头校验）。
const _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
    'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  test(
    'image organization validates uploads and defers ledger writes to review',
    () async {
      final client = DevApiClient(_baseUrl);
      final accountRepo = LocalServerAccountRepository(client);
      final aiRepo = LocalServerAiProposalRepository(client);

      final cash = await accountRepo.createAccount(
        const CreateAccountInput(
          displayName: '图片联调现金',
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

      // —— 合法 PNG：生成候选；确认前余额不变 ——
      final before = await pendingIds();
      await aiRepo.createFromImage(
        fileName: 'receipt.png',
        imageBase64: _tinyPng,
        mimeType: 'image/png',
      );
      final proposal = (await aiRepo.listPending()).firstWhere(
        (p) => !before.contains(p.id),
      );
      final group = proposal.groups.single;
      expect(await balance(), '100.00', reason: '确认前余额不得变化');

      // provider 关闭时是待补全候选：不能直接确认，余额仍不变。
      if (group.needsCompletion) {
        await expectLater(
          aiRepo.approveAtomicGroup(group.id),
          throwsA(isA<Exception>()),
        );
        expect(await balance(), '100.00');
      }
      await aiRepo.rejectAtomicGroup(group.id, reason: '联调清理');

      // —— MIME 与内容不一致 → 400（必测 3）——
      await expectLater(
        aiRepo.createFromImage(
          fileName: 'receipt.jpg',
          imageBase64: _tinyPng,
          mimeType: 'image/jpeg',
        ),
        throwsA(
          isA<ApiValidationException>().having(
            (e) => e.code,
            'code',
            'ai_image_input_data_invalid',
          ),
        ),
      );

      // —— 不支持的格式（HEIC）→ 400（必测 1 的服务端侧）——
      await expectLater(
        aiRepo.createFromImage(
          fileName: 'receipt.heic',
          imageBase64: _tinyPng,
          mimeType: 'image/heic',
        ),
        throwsA(
          isA<ApiValidationException>().having(
            (e) => e.code,
            'code',
            'ai_image_input_mime_invalid',
          ),
        ),
      );
      expect(await balance(), '100.00', reason: '失败请求不得触碰账本');

      // —— 同一幂等键重放：同一 proposal，不重复生成 ——
      Future<(int, Map<String, dynamic>)> rawFromImage(String key) async {
        final res = await http.post(
          Uri.parse('$_baseUrl/v1/ai/proposals/from-image'),
          headers: {'content-type': 'application/json', 'idempotency-key': key},
          body: jsonEncode({
            'fileName': 'receipt.png',
            'mimeType': 'image/png',
            'imageBase64': _tinyPng,
          }),
        );
        return (
          res.statusCode,
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map)
              .cast<String, dynamic>(),
        );
      }

      const idemKey = 'cccccccccccccccccccccccccccc0727';
      final baseline = await pendingIds();
      final (s1, b1) = await rawFromImage(idemKey);
      expect(s1, 200, reason: '$b1');
      final proposalId = '${(b1['data'] as Map)['id']}';
      final (s2, b2) = await rawFromImage(idemKey);
      expect(s2, 200, reason: '$b2');
      expect(
        '${(b2['data'] as Map)['id']}',
        proposalId,
        reason: '重放同一 proposal',
      );
      expect((await pendingIds()).difference(baseline), {
        proposalId,
      }, reason: '不重复生成候选');
      final replay = (await aiRepo.listPending()).firstWhere(
        (p) => p.id == proposalId,
      );
      await aiRepo.rejectAtomicGroup(replay.groups.single.id, reason: '联调清理');
      expect(await balance(), '100.00');
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_local_server_smoke.ps1.'
        : false,
  );
}
