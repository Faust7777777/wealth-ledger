import 'dart:convert';

import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object? data) => http.Response(
  jsonEncode({'ok': true, 'data': data}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('movement repository forwards the requested recent limit', () async {
    Uri? requested;
    final client = DevApiClient(
      'http://127.0.0.1:8790',
      client: MockClient((request) async {
        requested = request.url;
        return _ok(const []);
      }),
    );

    final result = await LocalServerMovementRepository(
      client,
    ).listRecentMovements(limit: 7);

    expect(result, isEmpty);
    expect(requested?.path, '/v1/movements/recent');
    expect(requested?.queryParameters, {'limit': '7'});
  });

  test('snapshot repository uses the dedicated latest endpoint', () async {
    Uri? requested;
    final client = DevApiClient(
      'http://127.0.0.1:8790',
      client: MockClient((request) async {
        requested = request.url;
        return _ok(null);
      }),
    );

    final result = await LocalServerSnapshotRepository(client).getLatest();

    expect(result, isNull);
    expect(requested?.path, '/v1/snapshots/latest');
    expect(requested?.query, isEmpty);
  });
}
