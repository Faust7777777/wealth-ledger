import 'dart:convert';

import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'transfer entries and transferMeta carry identical accounts and money',
    () async {
      final requests = <http.Request>[];
      final client = DevApiClient(
        'http://127.0.0.1:1',
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path == '/v1/movements/drafts') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {'id': 'mov_1', 'atomicGroupId': 'group_1'},
              }),
              201,
            );
          }
          if (path == '/v1/movements/mov_1/submit-review') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {'id': 'group_1', 'status': 'pending'},
              }),
              200,
            );
          }
          if (path == '/v1/atomic-groups/group_1/confirm') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {
                  'atomicGroupId': 'group_1',
                  'confirmedMovementIds': ['mov_1'],
                  'ledgerWrite': true,
                  'snapshotInvalidated': true,
                },
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final repository = LocalServerMovementRepository(client);

      final result = await repository.createTransfer(
        const TransferInput(
          fromAccountId: 'acct_bank',
          toAccountId: 'acct_card',
          amount: '60.00',
          currency: 'CNY',
          title: '信用卡还款',
        ),
      );

      expect(result.ledgerWrite, isTrue);
      expect(requests.map((request) => request.url.path), [
        '/v1/movements/drafts',
        '/v1/movements/mov_1/submit-review',
        '/v1/atomic-groups/group_1/confirm',
      ]);
      final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(body['entries'], [
        {
          'accountId': 'acct_bank',
          'amount': '60.00',
          'currency': 'CNY',
          'direction': 'out',
          'role': 'source',
        },
        {
          'accountId': 'acct_card',
          'amount': '60.00',
          'currency': 'CNY',
          'direction': 'in',
          'role': 'destination',
        },
      ]);
      expect(body['transferMeta'], {
        'fromAccountId': 'acct_bank',
        'toAccountId': 'acct_card',
        'fromAmount': {'amount': '60.00', 'currency': 'CNY'},
        'toAmount': {'amount': '60.00', 'currency': 'CNY'},
      });
    },
  );
}
