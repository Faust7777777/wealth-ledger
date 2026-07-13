// 订阅：JSON 解析、capability 映射、HTTP 路由/query、幂等键、401 重放、
// duration/endDate 互斥与 PATCH 清除语义、409 映射、表单纯校验。
import 'dart:convert';

import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/subscription_form_validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _subJson({
  String id = 'sub_1',
  Map<String, dynamic>? overrides,
}) => {
  'id': id,
  'displayName': 'ChatGPT Plus',
  'provider': 'OpenAI',
  'planName': 'Plus',
  'amount': {'amount': '20.00', 'currency': 'USD'},
  'paymentAccountId': 'acct_us',
  'billingCycle': {'unit': 'month', 'interval': 1},
  'billingAnchorDay': 5,
  'startDate': '2026-01-05',
  'duration': {'unit': 'month', 'count': 12},
  'nextChargeDate': '2026-08-05',
  'autoRenew': true,
  'reminderDaysBefore': 3,
  'status': 'active',
  'pendingChargeMovementId': 'mov_p1',
  'pendingChargeDate': '2026-08-05',
  'lastChargeMovementId': 'mov_l1',
  'lastChargeDate': '2026-07-05',
  'note': '团队公用',
  ...?overrides,
};

DevApiClient _client(MockClientHandler handler, {AuthTokenStore? store}) =>
    DevApiClient(
      'http://127.0.0.1:8790',
      tokenStore: store,
      client: MockClient(handler),
    );

http.Response _ok(Object data) => http.Response(
  jsonEncode({'ok': true, 'data': data}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

CreateSubscriptionInput _createInput({
  SubscriptionDurationVm? duration,
  String? endDate,
}) => CreateSubscriptionInput(
  displayName: 'ChatGPT Plus',
  provider: 'OpenAI',
  planName: 'Plus',
  amount: const Money(amount: '20.00', currency: 'USD'),
  paymentAccountId: 'acct_us',
  billingCycle: const SubscriptionBillingCycleVm(
    unit: BillingUnit.month,
    interval: 1,
  ),
  startDate: '2026-01-05',
  duration: duration,
  endDate: endDate,
);

UpdateSubscriptionInput _updateInput({
  SubscriptionDurationVm? duration,
  String? endDate,
  String? planName,
  String? note,
}) => UpdateSubscriptionInput(
  displayName: 'ChatGPT Plus',
  provider: 'OpenAI',
  planName: planName,
  amount: const Money(amount: '20.00', currency: 'USD'),
  paymentAccountId: 'acct_us',
  billingCycle: const SubscriptionBillingCycleVm(
    unit: BillingUnit.month,
    interval: 1,
  ),
  startDate: '2026-01-05',
  duration: duration,
  endDate: endDate,
  autoRenew: true,
  reminderDaysBefore: 3,
  status: SubscriptionStatus.active,
  note: note,
);

void main() {
  group('cat1: Subscription JSON 解析', () {
    test('完整字段', () {
      final s = parseSubscriptionData(_subJson());
      expect(s.id, 'sub_1');
      expect(s.displayName, 'ChatGPT Plus');
      expect(s.provider, 'OpenAI');
      expect(s.planName, 'Plus');
      expect(s.amount.amount, '20.00');
      expect(s.amount.currency, 'USD');
      expect(s.paymentAccountId, 'acct_us');
      expect(s.billingCycle.unit, BillingUnit.month);
      expect(s.billingCycle.interval, 1);
      expect(s.billingAnchorDay, 5);
      expect(s.startDate, '2026-01-05');
      expect(s.duration?.unit, SubscriptionDurationUnit.month);
      expect(s.duration?.count, 12);
      expect(s.nextChargeDate, '2026-08-05');
      expect(s.autoRenew, isTrue);
      expect(s.reminderDaysBefore, 3);
      expect(s.status, SubscriptionStatus.active);
      expect(s.hasPendingCharge, isTrue);
      expect(s.pendingChargeDate, '2026-08-05');
      expect(s.lastChargeDate, '2026-07-05');
      expect(s.note, '团队公用');
    });

    test('可选字段缺省安全', () {
      final s = parseSubscriptionData({
        'id': 'sub_2',
        'displayName': 'Claude Pro',
        'provider': 'Anthropic',
        'amount': {'amount': '20', 'currency': 'USD'},
        'paymentAccountId': 'acct_us',
        'billingCycle': {'unit': 'year', 'interval': 1},
        'billingAnchorDay': 12,
        'startDate': '2026-03-12',
        'autoRenew': false,
        'reminderDaysBefore': 0,
        'status': 'trial',
      });
      expect(s.planName, isNull);
      expect(s.duration, isNull);
      expect(s.endDate, isNull);
      expect(s.nextChargeDate, isNull);
      expect(s.hasPendingCharge, isFalse);
      expect(s.lastChargeDate, isNull);
      expect(s.note, isNull);
      expect(s.status, SubscriptionStatus.trial);
      expect(s.billingCycle.unit, BillingUnit.year);
      expect(s.isSchedulable, isTrue); // trial 可排期
    });

    test('duration 与 endDate 二选一：仅 endDate', () {
      final s = parseSubscriptionData(
        _subJson(overrides: {'duration': null, 'endDate': '2027-01-05'}),
      );
      expect(s.duration, isNull);
      expect(s.endDate, '2027-01-05');
    });
  });

  group('cat2: capability 映射与 fail-closed', () {
    test('canManageSubscriptions=true 映射', () {
      final caps = parseLedgerCapabilitiesData(const {
        'dataSourceMode': 'local_server',
        'canManageSubscriptions': true,
      });
      expect(caps.canManageSubscriptions, isTrue);
    });

    test('缺字段 fail-closed 为 false', () {
      final caps = parseLedgerCapabilitiesData(const {});
      expect(caps.canManageSubscriptions, isFalse);
    });

    test('locked 常量 canManageSubscriptions 为 false', () {
      expect(LedgerCapabilitiesVm.locked.canManageSubscriptions, isFalse);
    });
  });

  group('cat3: HTTP 路由与 query 映射', () {
    test('list / upcoming(days 夹取) / get', () async {
      final paths = <String>[];
      String? daysQuery;
      final repo = LocalServerSubscriptionRepository(
        _client((req) async {
          paths.add(req.url.path);
          if (req.url.path.endsWith('/upcoming')) {
            daysQuery = req.url.queryParameters['days'];
          }
          // list / upcoming 返回列表；get 单条返回对象。
          final isCollection =
              req.url.path == '/v1/subscriptions' ||
              req.url.path.endsWith('/upcoming');
          return _ok(
            isCollection
                ? {
                    'items': [_subJson()],
                  }
                : _subJson(),
          );
        }),
      );
      await repo.listSubscriptions();
      await repo.listUpcomingSubscriptions(days: 500); // clamp → 365
      await repo.getSubscription('sub_9');
      expect(paths[0], '/v1/subscriptions');
      expect(paths[1], '/v1/subscriptions/upcoming');
      expect(daysQuery, '365');
      expect(paths[2], '/v1/subscriptions/sub_9');
    });

    test('get 单条解析 data', () async {
      final repo = LocalServerSubscriptionRepository(
        _client((_) async => _ok(_subJson(id: 'sub_x'))),
      );
      final s = await repo.getSubscription('sub_x');
      expect(s.id, 'sub_x');
    });
  });

  group('cat4: 写请求携带幂等键', () {
    Future<String?> keyForWrite(
      Future<void> Function(SubscriptionRepository repo) op, {
      required String method,
    }) async {
      String? key;
      final repo = LocalServerSubscriptionRepository(
        _client((req) async {
          if (req.method == method) key = req.headers['idempotency-key'];
          return _ok(_subJson());
        }),
      );
      await op(repo);
      return key;
    }

    test('create(POST) 带 32 位 hex key', () async {
      final key = await keyForWrite(
        (r) => r.createSubscription(_createInput()),
        method: 'POST',
      );
      expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('update(PATCH) 带 key', () async {
      final key = await keyForWrite(
        (r) => r.updateSubscription('sub_1', _updateInput()),
        method: 'PATCH',
      );
      expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('cancel(POST) 带 key', () async {
      final key = await keyForWrite(
        (r) => r.cancelSubscription('sub_1'),
        method: 'POST',
      );
      expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('charge-proposal(POST) 带 key', () async {
      String? key;
      final repo = LocalServerSubscriptionRepository(
        _client((req) async {
          key = req.headers['idempotency-key'];
          return _ok({
            'id': 'ag_1',
            'title': '订阅扣费',
            'operation': 'create',
            'status': 'pending',
          });
        }),
      );
      await repo.createChargeProposal('sub_1');
      expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('cat5: 401 refresh 后复用同一幂等键', () {
    test('createSubscription 经 401 重放复用 key', () async {
      final store = MemoryAuthTokenStore();
      await store.write(
        const StoredAuthSession(
          accessToken: 'access_expired',
          refreshToken: 'refresh_old',
          expiresAt: '2026-07-13T12:00:00+08:00',
          deviceId: 'device_1',
        ),
      );
      final businessKeys = <String>[];
      final repo = LocalServerSubscriptionRepository(
        _client(store: store, (req) async {
          if (req.url.path == '/v1/auth/refresh') {
            return _ok({
              'accessToken': 'access_new',
              'refreshToken': 'refresh_new',
              'expiresAt': '2026-07-13T13:00:00+08:00',
              'deviceId': 'device_1',
            });
          }
          final k = req.headers['idempotency-key'];
          if (k != null) businessKeys.add(k);
          if (req.headers['authorization'] == 'Bearer access_expired') {
            return http.Response(jsonEncode({'ok': false}), 401);
          }
          return _ok(_subJson());
        }),
      );
      await repo.createSubscription(_createInput());
      expect(businessKeys, hasLength(2));
      expect(businessKeys[0], businessKeys[1]);
    });
  });

  group('cat6: duration/endDate 互斥与 PATCH 清除语义（wire）', () {
    Future<Map<String, dynamic>> captureBody(
      Future<void> Function(SubscriptionRepository repo) op,
    ) async {
      late Map<String, dynamic> body;
      final repo = LocalServerSubscriptionRepository(
        _client((req) async {
          if (req.body.isNotEmpty) {
            body = jsonDecode(req.body) as Map<String, dynamic>;
          }
          return _ok(_subJson());
        }),
      );
      await op(repo);
      return body;
    }

    test('create 仅 duration：body 有 duration、无 endDate', () async {
      final body = await captureBody(
        (r) => r.createSubscription(
          _createInput(
            duration: const SubscriptionDurationVm(
              unit: SubscriptionDurationUnit.month,
              count: 12,
            ),
          ),
        ),
      );
      expect(body['duration'], isNotNull);
      expect(body.containsKey('endDate'), isFalse);
    });

    test('create 仅 endDate：body 有 endDate、无 duration', () async {
      final body = await captureBody(
        (r) => r.createSubscription(_createInput(endDate: '2027-01-05')),
      );
      expect(body['endDate'], '2027-01-05');
      expect(body.containsKey('duration'), isFalse);
    });

    test('patch 整表替换：清除的可空字段显式传 null', () async {
      final body = await captureBody(
        (r) => r.updateSubscription(
          'sub_1',
          _updateInput(), // duration/endDate/planName/note 均 null
        ),
      );
      expect(body.containsKey('duration'), isTrue);
      expect(body['duration'], isNull);
      expect(body.containsKey('endDate'), isTrue);
      expect(body['endDate'], isNull);
      expect(body['planName'], isNull);
      expect(body['note'], isNull);
      expect(body['status'], 'active');
    });
  });

  group('cat8(repo): 409 映射为 ApiConflictException', () {
    http.Response conflict() => http.Response(
      jsonEncode({
        'ok': false,
        'error': {'code': 'pending_charge_exists', 'message': '本期已有待确认扣费'},
      }),
      409,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

    test('charge-proposal 409', () async {
      final repo = LocalServerSubscriptionRepository(
        _client((_) async => conflict()),
      );
      await expectLater(
        repo.createChargeProposal('sub_1'),
        throwsA(isA<ApiConflictException>()),
      );
    });

    test('cancel 409', () async {
      final repo = LocalServerSubscriptionRepository(
        _client((_) async => conflict()),
      );
      await expectLater(
        repo.cancelSubscription('sub_1'),
        throwsA(
          isA<ApiConflictException>().having(
            (e) => e.message,
            'message',
            contains('待确认'),
          ),
        ),
      );
    });
  });

  group('cat6: 表单纯校验', () {
    test('金额：正数、≤8 位小数', () {
      expect(amountError(''), isNotNull);
      expect(amountError('0'), isNotNull);
      expect(amountError('0.00'), isNotNull);
      expect(amountError('-5'), isNotNull);
      expect(amountError('1.234567890'), isNotNull); // 9 位小数
      expect(amountError('abc'), isNotNull);
      expect(amountError('20'), isNull);
      expect(amountError('20.00'), isNull);
      expect(amountError('0.12345678'), isNull); // 恰好 8 位
    });

    test('正整数 / 非负整数', () {
      expect(positiveIntError('0', '计费周期'), isNotNull);
      expect(positiveIntError('-1', '计费周期'), isNotNull);
      expect(positiveIntError('', '计费周期'), isNotNull);
      expect(positiveIntError('1', '计费周期'), isNull);
      expect(nonNegativeIntError('-1', '提醒'), isNotNull);
      expect(nonNegativeIntError('0', '提醒'), isNull);
      expect(nonNegativeIntError('3', '提醒'), isNull);
    });

    test('结束日期须晚于开始日期', () {
      expect(endDateAfterStartError(null, '2026-01-05'), isNotNull);
      expect(endDateAfterStartError('2026-01-05', '2026-01-05'), isNotNull);
      expect(endDateAfterStartError('2025-12-31', '2026-01-05'), isNotNull);
      expect(endDateAfterStartError('2026-02-01', '2026-01-05'), isNull);
    });
  });
}

typedef MockClientHandler = Future<http.Response> Function(http.Request);
