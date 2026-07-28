// Wealth Ledger — API 仓库（LocalServer*）：读取 Rust server 的 /v1 接口。
// DATA_SOURCE=local_server 用于本机服务；DATA_SOURCE=api_remote 用于 HTTPS VPS；
// 写路径只生成 proposal；禁用端点以 403 呈现。（文件名暂留 api_mock_repositories.dart 以免动测试导入。）
// 形状对齐 docs/contracts（DATA_SCHEMA_V1 / examples / FRONTEND_API_INTEGRATION_HANDOFF_V1）。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/format.dart';
import '../core/types.dart';
import 'auth_store.dart';
import 'repositories.dart';
import 'view_models.dart';

/// 产品边界禁止的端点（转账/下单/AI 自动写账等）由 server 返回 403。
class ApiForbiddenException implements Exception {
  ApiForbiddenException(this.path);
  final String path;
  @override
  String toString() => '该能力被产品边界禁止（403）：$path';
}

class ApiUnauthorizedException implements Exception {
  ApiUnauthorizedException(this.path);
  final String path;
  @override
  String toString() => '登录已失效或未登录（401）：请到「设置」重新登录后重试（$path）';
}

/// 业务冲突（409）：带服务端 error.code（如 duplicate_pending_charge / cancel_conflict），
/// 由 UI 映射成可恢复提示，不清空用户输入。
class ApiConflictException implements Exception {
  ApiConflictException(this.path, {this.code, this.message});
  final String path;
  final String? code;
  final String? message;
  @override
  String toString() =>
      message ?? '操作冲突（409${code == null ? '' : ' · $code'}）：$path';
}

/// 服务暂不可用（503）：如 AI 整理失败。UI 只显示简短失败状态并允许重试，
/// 不展示 provider 名、上游状态码或配置字段。
class ApiServiceUnavailableException implements Exception {
  ApiServiceUnavailableException(this.path, {this.code, this.message});
  final String path;
  final String? code;
  final String? message;
  @override
  String toString() => '服务暂时不可用，请稍后重试';
}

/// 请求校验失败（400）：携带服务端 message 与 details.errors。
/// UI 用 [userMessage] 呈现具体校验原因，不展示裸 HTTP 细节。
class ApiValidationException implements Exception {
  ApiValidationException(
    this.path, {
    this.code,
    this.message,
    this.details = const [],
  });
  final String path;
  final String? code;
  final String? message;
  final List<String> details;

  String get userMessage =>
      details.isNotEmpty ? details.first : (message ?? '提交内容未通过校验');

  @override
  String toString() => '提交内容未通过校验（400）：$userMessage';
}

class DevApiClient {
  DevApiClient(
    this.baseUrl, {
    this.scenario = '',
    this.tokenStore,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String scenario;
  final AuthTokenStore? tokenStore;
  final http.Client _client;
  final Random _rng = Random.secure();

  Future<Map<String, String>> _headers({bool json = false}) async {
    final headers = <String, String>{};
    if (json) headers['content-type'] = 'application/json';
    final token = await tokenStore?.readAccessToken();
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// 后端要求所有非 auth 持久化写入（POST/PATCH/PUT/DELETE）带 Idempotency-Key。
  static bool _needsIdempotencyKey(String method, String path) =>
      method != 'GET' && !path.startsWith('/v1/auth/');

  /// 128-bit 高熵 key，小写 hex（32 字符，可见 ASCII）。一个逻辑写操作一个 key，
  /// 包括其 401 refresh 后的自动重放；不持久化、不记录。
  String _newIdempotencyKey() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _url(String path) => scenario.isEmpty
      ? '$baseUrl$path'
      : '$baseUrl$path${path.contains('?') ? '&' : '?'}scenario=$scenario';

  Object? _handle(http.Response res, String path) {
    _throwForStatus(res, path);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) {
      return null; // 如 AI reject 返回 204
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is Map<String, dynamic>) {
      if (body['ok'] == false) throw Exception('API error · $path');
      return body.containsKey('data') ? body['data'] : body;
    }
    return body;
  }

  /// 状态码 → 类型化异常。JSON 与二进制响应共用同一套错误语义。
  void _throwForStatus(http.Response res, String path) {
    if (res.statusCode == 401) {
      throw ApiUnauthorizedException(path);
    }
    if (res.statusCode == 403) {
      throw ApiForbiddenException(path);
    }
    if (res.statusCode == 409) {
      throw ApiConflictException(
        path,
        code: _errorField(res, 'code'),
        message: _errorField(res, 'message'),
      );
    }
    if (res.statusCode == 503) {
      throw ApiServiceUnavailableException(
        path,
        code: _errorField(res, 'code'),
        message: _errorField(res, 'message'),
      );
    }
    // 400 与 413（附件过大）同属"请求本身不合法"，用同一种类型化异常呈现。
    if (res.statusCode == 400 || res.statusCode == 413) {
      throw ApiValidationException(
        path,
        code: _errorField(res, 'code'),
        message: _errorField(res, 'message'),
        details: _errorDetails(res),
      );
    }
    if (res.statusCode >= 400) {
      final message = _errorField(res, 'message');
      throw Exception(
        'HTTP ${res.statusCode} · $path${message == null ? '' : ' · $message'}',
      );
    }
  }

  /// 读取错误信封 error.details.errors（服务端校验失败的逐条原因）。
  List<String> _errorDetails(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final error = body is Map ? body['error'] : null;
      final details = error is Map ? error['details'] : null;
      final errors = details is Map ? details['errors'] : details;
      if (errors is List) return [for (final e in errors) '$e'];
    } catch (_) {
      // 信封不完整时回落到 message。
    }
    return const [];
  }

  /// 读取错误信封 {ok:false, error:{code, message}} 的字段（供 409 等使用）。
  String? _errorField(http.Response res, String key) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final error = body is Map ? body['error'] : null;
      return error is Map ? error[key]?.toString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<Object?> getData(String path) => _send('GET', path);

  Future<Object?> postData(String path, {Object? body}) =>
      _send('POST', path, body: body);

  Future<Object?> patchData(String path, {Object? body}) =>
      _send('PATCH', path, body: body);

  /// multipart 上传（Agent 附件）。写入语义与 JSON POST 一致：
  /// 首次调用前生成 Idempotency-Key，401 刷新后的重放复用同一个 key，
  /// 不会因为重试重复归档同一张图。
  Future<Object?> postMultipart(
    String path, {
    required String field,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) => _sendMultipart(
    path,
    field: field,
    fileName: fileName,
    mimeType: mimeType,
    bytes: bytes,
    idempotencyKey: _newIdempotencyKey(),
  );

  Future<Object?> _sendMultipart(
    String path, {
    required String field,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    required String idempotencyKey,
    bool retried = false,
  }) async {
    // 手写 multipart：part 的 Content-Type 必须是真实图片 MIME（服务端据此校验），
    // 而 http 包的 MultipartFile 需要额外依赖才能设置它。
    final boundary = '----finwealth${_newIdempotencyKey()}';
    final safeName = fileName.replaceAll(RegExp(r'[\r\n"]'), '_');
    final head = utf8.encode(
      '--$boundary\r\n'
      'content-disposition: form-data; name="$field"; filename="$safeName"\r\n'
      'content-type: $mimeType\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final request = http.Request('POST', Uri.parse(_url(path)))
      ..headers.addAll(await _headers())
      ..headers['idempotency-key'] = idempotencyKey
      ..headers['content-type'] = 'multipart/form-data; boundary=$boundary'
      ..bodyBytes = <int>[...head, ...bytes, ...tail];
    final res = await http.Response.fromStream(await _client.send(request));
    if (res.statusCode == 401 && !retried && await _refreshSession()) {
      return _sendMultipart(
        path,
        field: field,
        fileName: fileName,
        mimeType: mimeType,
        bytes: bytes,
        idempotencyKey: idempotencyKey,
        retried: true,
      );
    }
    return _handle(res, path);
  }

  /// 二进制读取（Agent 附件原图）：返回字节与服务端声明的 MIME。
  Future<({Uint8List bytes, String mimeType})> getBytes(
    String path, {
    bool retried = false,
  }) async {
    final res = await _client.get(
      Uri.parse(_url(path)),
      headers: await _headers(),
    );
    if (res.statusCode == 401 && !retried && await _refreshSession()) {
      return getBytes(path, retried: true);
    }
    _throwForStatus(res, path);
    return (
      bytes: res.bodyBytes,
      mimeType: res.headers['content-type']?.split(';').first.trim() ?? '',
    );
  }

  /// SSE 订阅：逐帧产出 (cursor, event, data)。`after` 为已应用的最大 cursor，
  /// 断线重连时由调用方续接；401 刷新后重连一次。
  Stream<({int cursor, String event, Map<String, dynamic> data})> streamEvents(
    String path, {
    int? after,
  }) async* {
    var retried = false;
    while (true) {
      final uri = Uri.parse(_url(after == null ? path : '$path?after=$after'));
      final request = http.Request('GET', uri)
        ..headers.addAll(await _headers())
        ..headers['accept'] = 'text/event-stream';
      if (after != null) request.headers['last-event-id'] = '$after';
      final res = await _client.send(request);
      if (res.statusCode == 401 && !retried && await _refreshSession()) {
        retried = true;
        continue;
      }
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw res.statusCode == 401
            ? ApiUnauthorizedException(path)
            : Exception('HTTP ${res.statusCode} · $path');
      }
      var id = 0;
      var event = '';
      final data = StringBuffer();
      await for (final line
          in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) {
          if (event.isNotEmpty && data.isNotEmpty) {
            final decoded = jsonDecode(data.toString());
            yield (
              cursor: id,
              event: event,
              data: decoded is Map
                  ? decoded.cast<String, dynamic>()
                  : <String, dynamic>{},
            );
          }
          event = '';
          data.clear();
          continue;
        }
        if (line.startsWith(':')) continue; // keep-alive
        final colon = line.indexOf(':');
        if (colon < 0) continue;
        final key = line.substring(0, colon);
        final value = line.substring(colon + 1).trimLeft();
        switch (key) {
          case 'id':
            id = int.tryParse(value) ?? id;
          case 'event':
            event = value;
          case 'data':
            data.write(value);
        }
      }
      return;
    }
  }

  /// 统一请求入口：access token 过期（401）时用 refresh token 换新并重放一次。
  /// auth 端点自身不重试，避免刷新循环。写入的 Idempotency-Key 在首次调用前生成，
  /// 401 重放时复用同一个（不重新生成）。
  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    bool retried = false,
    String? idempotencyKey,
  }) async {
    final key =
        idempotencyKey ??
        (_needsIdempotencyKey(method, path) ? _newIdempotencyKey() : null);
    final res = await _dispatch(method, path, body, key);
    if (res.statusCode == 401 &&
        !retried &&
        !path.startsWith('/v1/auth/') &&
        await _refreshSession()) {
      return _send(
        method,
        path,
        body: body,
        retried: true,
        idempotencyKey: key,
      );
    }
    return _handle(res, path);
  }

  Future<http.Response> _dispatch(
    String method,
    String path,
    Object? body,
    String? idempotencyKey,
  ) async {
    final uri = Uri.parse(_url(path));
    final encoded = body == null ? null : jsonEncode(body);
    final headers = await _headers(json: method != 'GET');
    if (idempotencyKey != null) headers['idempotency-key'] = idempotencyKey;
    return switch (method) {
      'GET' => _client.get(uri, headers: headers),
      'POST' => _client.post(uri, headers: headers, body: encoded),
      'PATCH' => _client.patch(uri, headers: headers, body: encoded),
      _ => throw ArgumentError.value(method, 'method'),
    };
  }

  // 单飞：并发 401 只触发一次 refresh，避免旋转后旧 refresh token 互相失效。
  Future<bool>? _refreshing;

  Future<bool> _refreshSession() => _refreshing ??= _doRefreshSession()
      .whenComplete(() => _refreshing = null);

  Future<bool> _doRefreshSession() async {
    final store = tokenStore;
    if (store == null) return false;
    final session = await store.read();
    if (session == null || session.refreshToken.isEmpty) return false;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/v1/auth/refresh'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'refreshToken': session.refreshToken}),
      );
      if (res.statusCode != 200) return false;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final data = decoded is Map<String, dynamic>
          ? (decoded['data'] ?? decoded)
          : null;
      if (data is! Map) return false;
      final next = StoredAuthSession(
        accessToken: '${data['accessToken'] ?? ''}',
        refreshToken: '${data['refreshToken'] ?? ''}',
        expiresAt: '${data['expiresAt'] ?? ''}',
        deviceId: '${data['deviceId'] ?? ''}',
      );
      if (!next.isComplete) return false;
      await store.write(next);
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ———— 小工具 ————
Map<String, dynamic> _m(Object? o) => (o as Map).cast<String, dynamic>();
List<dynamic> _list(Object? d) => d is List
    ? d
    : (d is Map && d['items'] is List ? d['items'] as List : const []);
int _int(Object? o) => (o as num?)?.toInt() ?? 0;
bool _bool(Object? o, {bool fallback = false}) => o is bool ? o : fallback;

// ———— enum 解析 ————
ValueQuality _quality(Object? s) => switch (s) {
  'estimated' => ValueQuality.estimated,
  'incomplete' => ValueQuality.incomplete,
  'unpriceable' => ValueQuality.unpriceable,
  'anomaly' => ValueQuality.anomaly,
  _ => ValueQuality.exact,
};
QuoteStatus _quote(Object? s) => switch (s) {
  'stale' => QuoteStatus.stale,
  'offline_cached' => QuoteStatus.offlineCached,
  'incomplete' => QuoteStatus.incomplete,
  'unpriceable' => QuoteStatus.unpriceable,
  'error' => QuoteStatus.error,
  _ => QuoteStatus.fresh,
};
AccountType _acctType(Object? s) => switch (s) {
  'bank' => AccountType.bank,
  'brokerage' => AccountType.brokerage,
  'exchange' => AccountType.exchange,
  'wallet' => AccountType.wallet,
  'platform_wallet' => AccountType.platformWallet,
  'virtual_card' => AccountType.virtualCard,
  'social_security' => AccountType.socialSecurity,
  'credit_card' => AccountType.creditCard,
  'loan' => AccountType.loan,
  'cash' => AccountType.cash,
  _ => AccountType.other,
};
String _acctTypeWire(AccountType t) => switch (t) {
  AccountType.bank => 'bank',
  AccountType.brokerage => 'brokerage',
  AccountType.exchange => 'exchange',
  AccountType.wallet => 'wallet',
  AccountType.platformWallet => 'platform_wallet',
  AccountType.virtualCard => 'virtual_card',
  AccountType.socialSecurity => 'social_security',
  AccountType.creditCard => 'credit_card',
  AccountType.loan => 'loan',
  AccountType.cash => 'cash',
  AccountType.other => 'other',
};
String _movementTypeWire(MovementType t) => switch (t) {
  MovementType.income => 'income',
  MovementType.expense => 'expense',
  MovementType.transfer => 'transfer',
  MovementType.buy => 'buy',
  MovementType.sell => 'sell',
  MovementType.dividend => 'dividend',
  MovementType.interest => 'interest',
  MovementType.fee => 'fee',
  MovementType.adjustment => 'adjustment',
  MovementType.loanDisbursement => 'loan_disbursement',
  MovementType.loanInterest => 'loan_interest',
  MovementType.loanRepayment => 'loan_repayment',
  MovementType.correction => 'correction',
};
String _categoryKindWire(CategoryKind k) => switch (k) {
  CategoryKind.income => 'income',
  CategoryKind.expense => 'expense',
  CategoryKind.transfer => 'transfer',
  CategoryKind.investment => 'investment',
  CategoryKind.liability => 'liability',
  CategoryKind.system => 'system',
};
String _dcaFrequencyWire(DcaFrequency f) => switch (f) {
  DcaFrequency.weekly => 'weekly',
  DcaFrequency.monthly => 'monthly',
  DcaFrequency.custom => 'custom',
};
String _dcaPlanStatusWire(DcaPlanStatus s) => switch (s) {
  DcaPlanStatus.active => 'active',
  DcaPlanStatus.snoozed => 'snoozed',
  DcaPlanStatus.paused => 'paused',
  DcaPlanStatus.completed => 'completed',
};
MovementType _movType(Object? s) => switch (s) {
  'income' => MovementType.income,
  'expense' => MovementType.expense,
  'transfer' => MovementType.transfer,
  'buy' => MovementType.buy,
  'sell' => MovementType.sell,
  'dividend' => MovementType.dividend,
  'interest' => MovementType.interest,
  'fee' => MovementType.fee,
  'loan_disbursement' => MovementType.loanDisbursement,
  'loan_repayment' => MovementType.loanRepayment,
  'loan_interest' => MovementType.loanInterest,
  'correction' => MovementType.correction,
  _ => MovementType.adjustment,
};
MovementStatus _movStatus(Object? s) => switch (s) {
  'draft' => MovementStatus.draft,
  'pending_review' => MovementStatus.pendingReview,
  'in_transit' => MovementStatus.inTransit,
  'cancelled' => MovementStatus.cancelled,
  'reversed' => MovementStatus.reversed,
  _ => MovementStatus.confirmed,
};
CategoryKind _catKind(Object? s) => switch (s) {
  'income' => CategoryKind.income,
  'transfer' => CategoryKind.transfer,
  'investment' => CategoryKind.investment,
  'liability' => CategoryKind.liability,
  'system' => CategoryKind.system,
  _ => CategoryKind.expense,
};
DcaReminderStatus _remStatus(Object? s) => switch (s) {
  'overdue' => DcaReminderStatus.overdue,
  'snoozed' => DcaReminderStatus.snoozed,
  'recorded' => DcaReminderStatus.recorded,
  'skipped' => DcaReminderStatus.skipped,
  _ => DcaReminderStatus.due,
};
DcaFrequency _freq(Object? s) => switch (s) {
  'weekly' => DcaFrequency.weekly,
  'monthly' => DcaFrequency.monthly,
  _ => DcaFrequency.custom,
};
DcaPlanStatus _planStatus(Object? s) => switch (s) {
  'snoozed' => DcaPlanStatus.snoozed,
  'paused' => DcaPlanStatus.paused,
  'completed' => DcaPlanStatus.completed,
  _ => DcaPlanStatus.active,
};
AiOperation _aiOp(Object? s) => switch (s) {
  'modify' => AiOperation.modify,
  'correction' => AiOperation.correction,
  'merge' => AiOperation.merge,
  'classify' => AiOperation.classify,
  _ => AiOperation.create,
};
AiGroupStatus _aiGroupStatus(Object? s) => switch (s) {
  'approved' => AiGroupStatus.approved,
  'rejected' => AiGroupStatus.rejected,
  'edited' => AiGroupStatus.edited,
  _ => AiGroupStatus.pending,
};
AiProposalStatus _aiPropStatus(Object? s) => switch (s) {
  'partially_reviewed' => AiProposalStatus.partiallyReviewed,
  'approved' => AiProposalStatus.approved,
  'rejected' => AiProposalStatus.rejected,
  'edited' => AiProposalStatus.edited,
  'expired' => AiProposalStatus.expired,
  _ => AiProposalStatus.pending,
};
AiDiffSeverity _diffSev(Object? s) => switch (s) {
  'important' => AiDiffSeverity.important,
  'danger' => AiDiffSeverity.danger,
  _ => AiDiffSeverity.normal,
};
AnomalyKind _anomKind(Object? s) => switch (s) {
  'quote_stale' => AnomalyKind.quoteStale,
  'unpriceable' => AnomalyKind.unpriceable,
  'reconcile_needed' => AnomalyKind.reconcileNeeded,
  'negative_balance' => AnomalyKind.negativeBalance,
  _ => AnomalyKind.dataAnomaly,
};
AnomalySeverity _anomSev(Object? s) => switch (s) {
  'critical' => AnomalySeverity.critical,
  'warning' => AnomalySeverity.warning,
  _ => AnomalySeverity.info,
};

// ———— 值对象 ————
Money _money(Object? o) {
  final j = _m(o);
  return Money(amount: '${j['amount']}', currency: '${j['currency']}');
}

Money? _moneyOrNull(Object? o) => o == null ? null : _money(o);

ValuedMoney _valued(Object? o) {
  final j = _m(o);
  return ValuedMoney(
    amount: '${j['amount']}',
    currency: '${j['currency']}',
    asOf: '${j['asOf']}',
    quality: _quality(j['quality']),
  );
}

ValuedMoney? _valuedOrNull(Object? o) => o == null ? null : _valued(o);

// ———— 实体映射 ————
Map<String, String> _cashBalances(Object? v) {
  if (v is! List) return const {};
  final m = <String, String>{};
  for (final e in v) {
    if (e is Map && e['currency'] != null && e['amount'] != null) {
      m['${e['currency']}'] = '${e['amount']}';
    }
  }
  return m;
}

AccountVm _account(Map<String, dynamic> j) {
  final type = _acctType(j['accountType']);
  final isLiab =
      j['role'] == 'liability' ||
      j['balanceMode'] == 'liability' ||
      type == AccountType.loan ||
      type == AccountType.creditCard;
  return AccountVm(
    id: '${j['id']}',
    displayName: '${j['displayName']}',
    accountType: type,
    isLiability: isLiab,
    value: _valuedOrNull(j['value']),
    note: j['note'] as String?,
    defaultCurrency: (j['defaultCurrency'] as String?) ?? 'CNY',
    balanceMode: (j['balanceMode'] as String?) ?? 'cash_balance',
    includeInNetWorth: j['includeInNetWorth'] as bool? ?? true,
    institutionName: j['institutionName'] as String?,
    cashBalances: _cashBalances(j['cashBalances']),
    supportedCurrencies: [
      for (final c in _list(j['supportedCurrencies'])) '$c',
    ],
    isArchived: j['status'] == 'archived' || j['visibility'] == 'archived',
  );
}

CategoryVm _category(Map<String, dynamic> j) => CategoryVm(
  id: '${j['id']}',
  displayName: '${j['displayName']}',
  kind: _catKind(j['kind']),
  parentId: j['parentId'] as String?,
  isSystem: j['isSystem'] as bool? ?? false,
  aiDescription: j['aiDescription'] as String?,
);

CounterpartyVm _counterparty(Map<String, dynamic> j) => CounterpartyVm(
  id: '${j['id']}',
  displayName: '${j['displayName']}',
  aliases: [for (final a in _list(j['aliases'])) '$a'],
  normalizedName: j['normalizedName'] as String?,
  categoryHintId: j['categoryHintId'] as String?,
  isUserMerged: j['isUserMerged'] as bool? ?? false,
);

HoldingVm _holding(Map<String, dynamic> j) {
  final inst = j['instrument'] is Map
      ? _m(j['instrument'])
      : const <String, dynamic>{};
  return HoldingVm(
    id: '${j['id']}',
    accountId: '${j['accountId']}',
    instrumentId: '${j['instrumentId'] ?? inst['id'] ?? ''}',
    symbol: '${inst['symbol'] ?? j['symbol'] ?? ''}',
    displayName:
        '${inst['displayName'] ?? j['displayName'] ?? inst['symbol'] ?? ''}',
    quantity: '${j['quantity']}',
    quoteStatus: _quote(j['quoteStatus']),
    costBasisTotal: _moneyOrNull(j['costBasisTotal']),
    marketValue: _valuedOrNull(j['marketValue']),
    dayChange: _moneyOrNull(j['dayChange']),
    unrealizedPnl: _moneyOrNull(j['unrealizedPnl']),
    unrealizedPnlRate: j['unrealizedPnlRate'] as String?,
  );
}

TransactionAmountBreakdownVm? _breakdown(Object? o) {
  if (o == null) return null;
  final j = _m(o);
  return TransactionAmountBreakdownVm(
    gross: _moneyOrNull(j['grossAmount']),
    savings: _moneyOrNull(j['savingsAmount']),
    paid: _money(j['paidAmount']),
  );
}

List<MovementEntryVm> _entries(Object? v) {
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is Map)
        MovementEntryVm(
          accountId: '${e['accountId']}',
          amount: '${e['amount']}',
          currency: '${e['currency']}',
          direction: '${e['direction']}',
          role: '${e['role']}',
          instrumentId: e['instrumentId'] as String?,
        ),
  ];
}

RealizedPnlStatus _pnlStatus(Object? s) => switch (s) {
  'calculated' => RealizedPnlStatus.calculated,
  'calculated_with_fx' => RealizedPnlStatus.calculatedWithFx,
  'currency_mismatch' => RealizedPnlStatus.currencyMismatch,
  // 未知状态按"暂不可计算"兜底：宁可少展示，也不给出错误盈亏。
  _ => RealizedPnlStatus.costBasisUnavailable,
};

ExecutionFxBasisVm? _fxBasis(Object? o) {
  if (o is! Map) return null;
  final j = _m(o);
  return ExecutionFxBasisVm(
    baseCurrency: '${j['baseCurrency']}',
    quoteCurrency: '${j['quoteCurrency']}',
    rate: '${j['rate']}',
    asOf: '${j['asOf']}',
    sourceRateId: '${j['sourceRateId']}',
    source: '${j['source']}',
    sourceUrl: j['sourceUrl'] as String?,
    inverted: _bool(j['inverted']),
  );
}

InvestmentSaleResultVm? _saleResult(Object? o) {
  if (o is! Map) return null;
  final j = _m(o);
  return InvestmentSaleResultVm(
    costBasisMethod: '${j['costBasisMethod']}',
    grossProceeds: _money(j['grossProceeds']),
    feeAndTaxTotal: _money(j['feeAndTaxTotal']),
    netProceeds: _money(j['netProceeds']),
    costBasisReleased: _moneyOrNull(j['costBasisReleased']),
    realizedPnl: _moneyOrNull(j['realizedPnl']),
    netProceedsInCostBasisCurrency: _moneyOrNull(
      j['netProceedsInCostBasisCurrency'],
    ),
    fxBasis: _fxBasis(j['fxBasis']),
    realizedPnlStatus: _pnlStatus(j['realizedPnlStatus']),
  );
}

MovementVm _movement(Map<String, dynamic> j) {
  final settlement = j['settlement'] is Map
      ? _m(j['settlement'])
      : const <String, dynamic>{};
  final status = _movStatus(j['status']);
  final inTransit =
      status == MovementStatus.inTransit ||
      settlement['status'] == 'in_transit';
  Money? amt = _moneyOrNull(j['displayAmount']);
  if (amt == null &&
      j['entries'] is List &&
      (j['entries'] as List).isNotEmpty) {
    final e = _m((j['entries'] as List).first);
    amt = Money(amount: '${e['amount']}', currency: '${e['currency']}');
  }
  return MovementVm(
    id: '${j['id']}',
    atomicGroupId: '${j['atomicGroupId']}',
    type: _movType(j['type']),
    status: status,
    title: '${j['title']}',
    occurredAt: '${j['occurredAt']}',
    displayAmount: amt,
    inTransit: inTransit,
    description: j['description'] as String?,
    amountBreakdown: _breakdown(j['amountBreakdown']),
    entries: _entries(j['entries']),
    categoryId: j['categoryId'] as String?,
    counterpartyId: j['counterpartyId'] as String?,
    saleResult: _saleResult(j['saleResult']),
    costBasisFx: _fxBasis(j['costBasisFx']),
  );
}

/// 公开以便单测直接喂 Movement JSON（saleResult/costBasisFx 映射与缺失兼容）。
MovementVm parseMovementData(Map<String, dynamic> j) => _movement(j);

InstrumentType _instType(Object? s) => switch (s) {
  'cash' => InstrumentType.cash,
  'equity' => InstrumentType.equity,
  'fund' => InstrumentType.fund,
  'crypto' => InstrumentType.crypto,
  'fx_cash' => InstrumentType.fxCash,
  'receivable' => InstrumentType.receivable,
  _ => InstrumentType.other,
};

String _instTypeWire(InstrumentType t) => switch (t) {
  InstrumentType.cash => 'cash',
  InstrumentType.equity => 'equity',
  InstrumentType.fund => 'fund',
  InstrumentType.crypto => 'crypto',
  InstrumentType.fxCash => 'fx_cash',
  InstrumentType.receivable => 'receivable',
  InstrumentType.other => 'other',
};

InstrumentVm _instrumentVm(Map<String, dynamic> j) => InstrumentVm(
  id: '${j['id']}',
  type: _instType(j['type']),
  symbol: j['symbol'] as String?,
  displayName: '${j['displayName']}',
  quoteCurrency: '${j['quoteCurrency']}',
  market: j['market'] as String?,
);

DcaReminderVm _reminder(Map<String, dynamic> j) => DcaReminderVm(
  id: '${j['id']}',
  planId: '${j['planId']}',
  displayName: '${j['displayName'] ?? j['planId']}',
  plannedAmount:
      _moneyOrNull(j['plannedAmount']) ??
      const Money(amount: '0', currency: 'CNY'),
  dueDate: '${j['dueDate']}',
  status: _remStatus(j['status']),
);

DcaPlanVm _plan(Map<String, dynamic> j) => DcaPlanVm(
  id: '${j['id']}',
  displayName: '${j['displayName']}',
  targetInstrumentId: '${j['targetInstrumentId'] ?? ''}',
  fundingAccountId: j['fundingAccountId']?.toString(),
  plannedAmount:
      _moneyOrNull(j['plannedAmount']) ??
      const Money(amount: '0', currency: 'CNY'),
  frequency: _freq(j['frequency']),
  nextDueDate: '${j['nextDueDate']}',
  status: _planStatus(j['reminderStatus'] ?? j['status']),
  note: j['note']?.toString(),
);

AiFieldDiffVm _diff(Map<String, dynamic> j) {
  final oldV = j['oldValue']?.toString();
  final newV = j['newValue']?.toString();
  return AiFieldDiffVm(
    fieldPath: '${j['fieldPath']}',
    oldValue: oldV,
    newValue: newV,
    changed: oldV != newV,
    severity: _diffSev(j['severity']),
  );
}

AiAtomicGroupVm _group(Map<String, dynamic> j) {
  final proposed = _list(j['proposedMovements']);
  final validation = j['validation'] is Map
      ? _m(j['validation'])
      : const <String, dynamic>{};
  return AiAtomicGroupVm(
    id: '${j['id']}',
    title: '${j['title']}',
    operation: _aiOp(j['operation']),
    status: _aiGroupStatus(j['status']),
    diffs: [for (final d in _list(j['diffs'])) _diff(_m(d))],
    warnings: [
      for (final w in _list(j['warnings']))
        (w is Map ? '${w['message']}' : '$w'),
    ],
    proposedMovement: proposed.isEmpty ? null : _movement(_m(proposed.first)),
    isValid: _bool(validation['isValid'], fallback: true),
  );
}

/// 公开以便单测直接喂 AiProposal JSON（结构化/待补全候选映射）。
AiProposalVm parseAiProposalData(Map<String, dynamic> j) => _proposal(j);

AiProposalVm _proposal(Map<String, dynamic> j) {
  final src = j['source'] is Map ? _m(j['source']) : const <String, dynamic>{};
  final refs = src['evidenceRefs'];
  final ev = refs is List && refs.isNotEmpty
      ? _m(refs.first)
      : const <String, dynamic>{};
  return AiProposalVm(
    id: '${j['id']}',
    status: _aiPropStatus(j['status']),
    sourceLabel: '${ev['label'] ?? src['kind'] ?? '输入'}',
    summary: j['summary'] as String?,
    modelName: src['modelName'] as String?,
    groups: [for (final g in _list(j['atomicGroups'])) _group(_m(g))],
  );
}

ConfirmResultVm _confirmResult(Map<String, dynamic> j) {
  final confirmedMovementIds = [
    for (final id in _list(j['confirmedMovementIds'])) '$id',
  ];
  return ConfirmResultVm(
    atomicGroupId: '${j['atomicGroupId'] ?? ''}',
    confirmedMovementIds: confirmedMovementIds,
    snapshotInvalidated: _bool(j['snapshotInvalidated']),
    ledgerWrite: _bool(
      j['ledgerWrite'],
      fallback: confirmedMovementIds.isNotEmpty,
    ),
  );
}

AccountAnomalyVm _anomaly(Map<String, dynamic> j) => AccountAnomalyVm(
  id: '${j['id']}',
  accountName: '${j['accountName'] ?? j['accountId']}',
  kind: _anomKind(j['kind']),
  severity: _anomSev(j['severity']),
  detail: '${j['detail']}',
);

NetWorthSnapshotVm _snapshot(Map<String, dynamic> j) => NetWorthSnapshotVm(
  id: '${j['id']}',
  snapshotAt: '${j['snapshotAt']}',
  grossAssets: _money(j['grossAssets']),
  totalLiabilities: _money(j['totalLiabilities']),
  netWorth: _money(j['netWorth']),
  quality: _quality(j['quality']),
);

NetWorthSnapshotVm? _snapshotOrNull(Object? o) =>
    o == null ? null : _snapshot(_m(o));

QuoteStatusSummaryVm _quoteSummary(Map<String, dynamic> j) =>
    QuoteStatusSummaryVm(
      freshCount: _int(j['freshCount']),
      staleCount: _int(j['staleCount']),
      offlineCachedCount: _int(j['offlineCachedCount']),
      unpriceableCount: _int(j['unpriceableCount']),
      errorCount: _int(j['errorCount']),
    );

QuoteRefreshResultVm _quoteRefreshResult(Map<String, dynamic> j) =>
    QuoteRefreshResultVm(
      status: '${j['status'] ?? 'failed'}',
      completedAt:
          '${j['completedAt'] ?? DateTime.now().toUtc().toIso8601String()}',
      quoteCount: _list(j['quotes']).length,
      fxRateCount: _list(j['fxRates']).length,
      errors: [
        for (final e in _list(j['errors'])) e is Map ? '${e['message']}' : '$e',
      ],
    );

PendingSummaryVm _pending(Map<String, dynamic> j) => PendingSummaryVm(
  aiPendingCount: _int(j['aiPendingCount']),
  accountAnomalyCount: _int(j['accountAnomalyCount']),
  dcaDueCount: _int(j['dcaDueCount']),
  inTransitCount: _int(j['inTransitCount']),
  quoteProblemCount: _int(j['quoteProblemCount']),
  syncProblemCount: _int(j['syncProblemCount']),
);

AllocationSliceVm _allocationSlice(Map<String, dynamic> j) => AllocationSliceVm(
  category: '${j['category']}',
  percent: '${j['percent']}',
  value: _money(j['value']),
);

/// 公开以便单测直接喂 examples/*.json（无需起服务）。
PortfolioOverviewVm parseOverviewData(Map<String, dynamic> j) {
  final latest = _snapshotOrNull(j['latestSnapshot']);
  final previous = _snapshotOrNull(j['previousSnapshot']);
  var change = _moneyOrNull(j['changeSinceLastSnapshot']);
  // 服务器未给 delta 时，用快照净值精确相减（同币种）。
  if (change == null &&
      latest != null &&
      previous != null &&
      latest.netWorth.currency == previous.netWorth.currency) {
    change = Money(
      amount: subtractDecimal(latest.netWorth.amount, previous.netWorth.amount),
      currency: latest.netWorth.currency,
    );
  }
  return PortfolioOverviewVm(
    latestSnapshot: latest,
    previousSnapshot: previous,
    pendingSummary: j['pendingSummary'] is Map
        ? _pending(_m(j['pendingSummary']))
        : const PendingSummaryVm(),
    quoteStatusSummary: j['quoteStatusSummary'] is Map
        ? _quoteSummary(_m(j['quoteStatusSummary']))
        : const QuoteStatusSummaryVm(),
    primaryHoldings: [
      for (final h in _list(j['primaryHoldings'])) _holding(_m(h)),
    ],
    recentMovements: [
      for (final m in _list(j['recentMovements'])) _movement(_m(m)),
    ],
    changeSinceLastSnapshot: change,
  );
}

/// 公开以便单测直接喂 /v1/portfolio/allocation 的 data。
AssetAllocationVm parseAssetAllocationData(Map<String, dynamic> j) =>
    AssetAllocationVm(
      slices: [for (final s in _list(j['slices'])) _allocationSlice(_m(s))],
      totalAssets: _money(j['totalAssets']),
      totalLiabilities: _money(j['totalLiabilities']),
      netWorth: _money(j['netWorth']),
    );

/// 公开以便单测直接喂 /v1/ledger/bootstrap 的 data.capabilities。
LedgerCapabilitiesVm parseLedgerCapabilitiesData(Map<String, dynamic> j) =>
    LedgerCapabilitiesVm(
      dataSourceMode: '${j['dataSourceMode'] ?? 'unknown'}',
      canWriteConfirmedLedger: _bool(j['canWriteConfirmedLedger']),
      canCreateAccount: _bool(j['canCreateAccount']),
      canRecordMovement: _bool(j['canRecordMovement']),
      canConfirmProposal: _bool(j['canConfirmProposal']),
      canPersistPendingProposal: _bool(j['canPersistPendingProposal']),
      proposalPersistence: '${j['proposalPersistence'] ?? 'none'}',
      canManageSubscriptions: _bool(j['canManageSubscriptions']),
    );

// ———— 仓库实现 ————
class LocalServerLedgerRepository implements LedgerRepository {
  LocalServerLedgerRepository(this._c);
  final DevApiClient _c;

  /// 能力来自 /v1/ledger/bootstrap；请求失败或字段缺失一律 fail-closed 只读。
  @override
  Future<LedgerCapabilitiesVm> getCapabilities() async {
    final d = await _c.getData('/v1/ledger/bootstrap');
    final caps = d is Map ? d['capabilities'] : null;
    if (caps is! Map) return LedgerCapabilitiesVm.locked;
    return parseLedgerCapabilitiesData(caps.cast<String, dynamic>());
  }
}

class LocalServerAccountRepository implements AccountRepository {
  LocalServerAccountRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<AccountVm>> listAccounts() async => [
    for (final a in _list(await _c.getData('/v1/accounts'))) _account(_m(a)),
  ];
  @override
  Future<AccountVm?> getAccount(Id id) async {
    final d = await _c.getData('/v1/accounts/$id');
    return d == null ? null : _account(_m(d));
  }

  @override
  Future<List<AccountAnomalyVm>> listAnomalies() async => [
    for (final a in _list(await _c.getData('/v1/accounts/anomalies')))
      _anomaly(_m(a)),
  ];
  @override
  Future<AccountVm> createAccount(CreateAccountInput input) async {
    final opening = input.openingBalance;
    final d = await _c.postData(
      '/v1/accounts',
      body: {
        'displayName': input.displayName,
        'accountType': _acctTypeWire(input.accountType),
        'defaultCurrency': input.defaultCurrency,
        'supportedCurrencies': [input.defaultCurrency],
        'includeInNetWorth': input.includeInNetWorth,
        'balanceMode': input.balanceMode,
        if (input.institutionName != null)
          'institutionName': input.institutionName,
        'openingBalances': [
          if (opening != null)
            {
              'currency': opening.currency,
              'amount': opening.amount,
              'quality': 'exact',
            },
        ],
      },
    );
    return _account(_m(d));
  }

  @override
  Future<AccountVm> updateAccount(Id id, CreateAccountInput input) async {
    final d = await _c.patchData(
      '/v1/accounts/$id',
      body: {
        'displayName': input.displayName,
        'accountType': _acctTypeWire(input.accountType),
        'defaultCurrency': input.defaultCurrency,
        'supportedCurrencies': [input.defaultCurrency],
        'includeInNetWorth': input.includeInNetWorth,
        'balanceMode': input.balanceMode,
        if (input.institutionName != null)
          'institutionName': input.institutionName,
      },
    );
    return _account(_m(d));
  }

  @override
  Future<void> archiveAccount(Id id) async {
    await _c.postData('/v1/accounts/$id/archive');
  }
}

class LocalServerTaxonomyRepository implements TaxonomyRepository {
  LocalServerTaxonomyRepository(this._c);
  final DevApiClient _c;

  @override
  Future<List<CategoryVm>> listCategories() async => [
    for (final c in _list(await _c.getData('/v1/categories'))) _category(_m(c)),
  ];

  @override
  Future<CategoryVm> createCategory(CreateCategoryInput input) async {
    final d = await _c.postData(
      '/v1/categories',
      body: {
        'displayName': input.displayName,
        'kind': _categoryKindWire(input.kind),
        if (input.parentId != null && input.parentId!.isNotEmpty)
          'parentId': input.parentId,
        if (input.aiDescription != null && input.aiDescription!.isNotEmpty)
          'aiDescription': input.aiDescription,
      },
    );
    return _category(_m(d));
  }

  @override
  Future<CategoryVm> updateCategory(Id id, CreateCategoryInput input) async {
    final d = await _c.patchData(
      '/v1/categories/$id',
      body: {
        'displayName': input.displayName,
        'kind': _categoryKindWire(input.kind),
        if (input.parentId != null && input.parentId!.isNotEmpty)
          'parentId': input.parentId,
        if (input.aiDescription != null && input.aiDescription!.isNotEmpty)
          'aiDescription': input.aiDescription,
      },
    );
    return _category(_m(d));
  }

  @override
  Future<List<CounterpartyVm>> listCounterparties() async => [
    for (final c in _list(await _c.getData('/v1/counterparties')))
      _counterparty(_m(c)),
  ];

  @override
  Future<CounterpartyVm> createCounterparty(
    CreateCounterpartyInput input,
  ) async {
    final d = await _c.postData(
      '/v1/counterparties',
      body: {
        'displayName': input.displayName,
        'aliases': input.aliases,
        if (input.normalizedName != null && input.normalizedName!.isNotEmpty)
          'normalizedName': input.normalizedName,
        if (input.categoryHintId != null && input.categoryHintId!.isNotEmpty)
          'categoryHintId': input.categoryHintId,
      },
    );
    return _counterparty(_m(d));
  }

  @override
  Future<CounterpartyVm> updateCounterparty(
    Id id,
    CreateCounterpartyInput input,
  ) async {
    final d = await _c.patchData(
      '/v1/counterparties/$id',
      body: {
        'displayName': input.displayName,
        'aliases': input.aliases,
        if (input.normalizedName != null && input.normalizedName!.isNotEmpty)
          'normalizedName': input.normalizedName,
        if (input.categoryHintId != null && input.categoryHintId!.isNotEmpty)
          'categoryHintId': input.categoryHintId,
      },
    );
    return _counterparty(_m(d));
  }

  @override
  Future<void> createCounterpartyMergeProposal({
    required List<Id> sourceCounterpartyIds,
    required String targetDisplayName,
  }) async {
    await _c.postData(
      '/v1/counterparties/merge-proposal',
      body: {
        'sourceCounterpartyIds': sourceCounterpartyIds,
        'targetDisplayName': targetDisplayName,
      },
    );
  }
}

class LocalServerPortfolioRepository implements PortfolioRepository {
  LocalServerPortfolioRepository(this._c);
  final DevApiClient _c;
  @override
  Future<PortfolioOverviewVm> getOverview() async =>
      parseOverviewData(_m(await _c.getData('/v1/portfolio/overview')));
  @override
  Future<List<HoldingVm>> listHoldings() async => [
    for (final h in _list(await _c.getData('/v1/holdings'))) _holding(_m(h)),
  ];
  @override
  Future<List<HoldingVm>> listHoldingsByAccount(Id accountId) async => [
    for (final h in _list(await _c.getData('/v1/accounts/$accountId/holdings')))
      _holding(_m(h)),
  ];
  @override
  Future<AssetAllocationVm> getAssetAllocation() async =>
      parseAssetAllocationData(
        _m(await _c.getData('/v1/portfolio/allocation')),
      );

  @override
  Future<AiAtomicGroupVm> proposeHoldingAdjustment(
    Id accountId,
    HoldingAdjustmentInput input,
  ) async => _group(
    _m(
      await _c.postData(
        '/v1/accounts/$accountId/holding-adjustment-proposals',
        body: {
          'instrumentId': input.instrumentId,
          'targetQuantity': input.targetQuantity,
          if (input.asOf != null) 'asOf': input.asOf,
          if (input.note != null && input.note!.isNotEmpty) 'note': input.note,
        },
      ),
    ),
  );
}

class LocalServerMovementRepository implements MovementRepository {
  LocalServerMovementRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<MovementVm>> listRecentMovements({int limit = 20}) async => [
    for (final m in _list(
      await _c.getData('/v1/movements/recent?limit=$limit'),
    ))
      _movement(_m(m)),
  ];
  @override
  Future<MovementVm?> getMovement(Id id) async {
    final d = await _c.getData('/v1/movements/$id');
    return d == null ? null : _movement(_m(d));
  }

  @override
  Future<ConfirmResultVm> createManualRecord(ManualRecordInput input) async {
    final isIncome = input.type == MovementType.income;
    return _recordViaPipeline({
      'type': _movementTypeWire(input.type),
      'occurredAt':
          input.occurredAt ?? DateTime.now().toUtc().toIso8601String(),
      'title': input.title,
      if (input.description != null && input.description!.isNotEmpty)
        'description': input.description,
      if (input.categoryId != null) 'categoryId': input.categoryId,
      if (input.counterpartyId != null) 'counterpartyId': input.counterpartyId,
      'entries': [
        {
          'accountId': input.accountId,
          'amount': input.amount,
          'currency': input.currency,
          'direction': isIncome ? 'in' : 'out',
          'role': 'source',
        },
      ],
    });
  }

  @override
  Future<ConfirmResultVm> createTransfer(TransferInput input) async {
    return _recordViaPipeline({
      'type': 'transfer',
      'occurredAt':
          input.occurredAt ?? DateTime.now().toUtc().toIso8601String(),
      'title': input.title,
      if (input.note != null && input.note!.isNotEmpty)
        'description': input.note,
      'entries': [
        {
          'accountId': input.fromAccountId,
          'amount': input.amount,
          'currency': input.currency,
          'direction': 'out',
          'role': 'source',
        },
        {
          'accountId': input.toAccountId,
          'amount': input.amount,
          'currency': input.currency,
          'direction': 'in',
          'role': 'destination',
        },
      ],
      'transferMeta': {
        'fromAccountId': input.fromAccountId,
        'toAccountId': input.toAccountId,
        'fromAmount': {'amount': input.amount, 'currency': input.currency},
        'toAmount': {'amount': input.amount, 'currency': input.currency},
        if (input.note != null && input.note!.isNotEmpty) 'note': input.note,
      },
    });
  }

  @override
  Future<ConfirmResultVm> reconcileBalance(ReconcileInput input) async {
    final delta = subtractDecimal(input.observedBalance, input.currentBalance);
    final isOut = delta.startsWith('-');
    final amount = isOut ? delta.substring(1) : delta;
    final hasNote = input.note?.isNotEmpty ?? false;
    return _recordViaPipeline({
      'type': 'adjustment',
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      'title': hasNote ? input.note! : '余额校准',
      if (hasNote) 'description': input.note,
      'entries': [
        {
          'accountId': input.accountId,
          'amount': amount,
          'currency': input.currency,
          'direction': isOut ? 'out' : 'in',
          'role': 'adjustment',
        },
      ],
    });
  }

  @override
  Future<void> createCorrectionProposal(CreateCorrectionInput input) async {
    await _c.postData(
      '/v1/movements/corrections',
      body: {
        'targetMovementId': input.targetMovementId,
        'reason': input.reason,
        'proposedDiffs': [
          {
            'fieldPath': 'entries[0].amount',
            'oldValue': input.oldAmount,
            'newValue': input.newAmount,
            'severity': 'danger',
          },
        ],
      },
    );
  }

  @override
  Future<ConfirmResultVm> createInvestmentTrade(
    InvestmentTradeInput input,
  ) async {
    final isBuy = input.side == TradeSide.buy;
    // 空值或纯零 fee/tax 不发送对应腿（服务端禁止零金额腿）。
    bool hasValue(DecimalString? v) =>
        v != null && v.trim().isNotEmpty && decimalSign(v) > 0;
    Map<String, Object?> cashLeg(
      DecimalString amount,
      String direction,
      String role,
    ) => {
      'accountId': input.cashAccountId,
      'amount': amount,
      'currency': input.cashCurrency,
      'direction': direction,
      'role': role,
    };
    return _recordViaPipeline({
      'type': isBuy ? 'buy' : 'sell',
      'occurredAt':
          input.occurredAt ?? DateTime.now().toUtc().toIso8601String(),
      'title': input.title,
      if (input.note != null && input.note!.isNotEmpty)
        'description': input.note,
      'entries': [
        // 现金主腿：买入付款（out/source），卖出毛回款（in/destination）。
        cashLeg(
          input.principalAmount,
          isBuy ? 'out' : 'in',
          isBuy ? 'source' : 'destination',
        ),
        // 持仓数量腿：金额=数量、币种=标的报价币种、必须带 instrumentId。
        {
          'accountId': input.holdingAccountId,
          'instrumentId': input.instrumentId,
          'amount': input.quantity,
          'currency': input.holdingCurrency,
          'direction': isBuy ? 'in' : 'out',
          'role': isBuy ? 'destination' : 'source',
        },
        // 费用/税费：始终为现金流出，且与主腿同账户同币种。
        if (hasValue(input.feeAmount)) cashLeg(input.feeAmount!, 'out', 'fee'),
        if (hasValue(input.taxAmount)) cashLeg(input.taxAmount!, 'out', 'tax'),
      ],
    });
  }

  // 候选 → 确认：草稿 → 提交复核 → 确认入账（均为用户主动发起的合法写路径）。
  // 返回服务端 confirm 结果；是否"已入账"由 ledgerWrite 决定，前端不猜测。
  Future<ConfirmResultVm> _recordViaPipeline(Map<String, Object?> body) async {
    final draft = _m(await _c.postData('/v1/movements/drafts', body: body));
    final movementId = '${draft['id']}';
    final groupId = '${draft['atomicGroupId']}';
    await _c.postData('/v1/movements/$movementId/submit-review');
    return _confirmResult(
      _m(await _c.postData('/v1/atomic-groups/$groupId/confirm')),
    );
  }
}

class LocalServerInstrumentRepository implements InstrumentRepository {
  LocalServerInstrumentRepository(this._c);
  final DevApiClient _c;

  @override
  Future<List<InstrumentVm>> listInstruments() async => [
    for (final i in _list(await _c.getData('/v1/instruments')))
      _instrumentVm(_m(i)),
  ];

  @override
  Future<InstrumentVm> createInstrument(CreateInstrumentInput input) async {
    final d = await _c.postData(
      '/v1/instruments',
      body: {
        'type': _instTypeWire(input.type),
        'displayName': input.displayName,
        'quoteCurrency': input.quoteCurrency,
        if (input.symbol != null && input.symbol!.isNotEmpty)
          'symbol': input.symbol,
      },
    );
    return _instrumentVm(_m(d));
  }
}

class LocalServerDcaRepository implements DcaRepository {
  LocalServerDcaRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<DcaReminderVm>> listDueReminders() async => [
    for (final r in _list(await _c.getData('/v1/dca/reminders/due')))
      _reminder(_m(r)),
  ];
  @override
  Future<List<DcaPlanVm>> listPlans() async => [
    for (final p in _list(await _c.getData('/v1/dca/plans'))) _plan(_m(p)),
  ];
  @override
  Future<DcaPlanVm> createPlan(CreateDcaPlanInput input) async {
    final d = await _c.postData(
      '/v1/dca/plans',
      body: {
        'displayName': input.displayName,
        'targetInstrumentId': input.targetInstrumentId,
        'fundingAccountId': input.fundingAccountId,
        'plannedAmount': {
          'amount': input.plannedAmount.amount,
          'currency': input.plannedAmount.currency,
        },
        'frequency': _dcaFrequencyWire(input.frequency),
        'nextDueDate': input.nextDueDate,
        if (input.note != null && input.note!.isNotEmpty) 'note': input.note,
      },
    );
    return _plan(_m(d));
  }

  @override
  Future<DcaPlanVm> updatePlan(Id planId, UpdateDcaPlanPatch patch) async {
    final body = <String, Object?>{
      if (patch.displayName != null) 'displayName': patch.displayName,
      if (patch.targetInstrumentId != null)
        'targetInstrumentId': patch.targetInstrumentId,
      if (patch.fundingAccountId != null)
        'fundingAccountId': patch.fundingAccountId,
      if (patch.plannedAmount != null)
        'plannedAmount': {
          'amount': patch.plannedAmount!.amount,
          'currency': patch.plannedAmount!.currency,
        },
      if (patch.frequency != null)
        'frequency': _dcaFrequencyWire(patch.frequency!),
      if (patch.nextDueDate != null) 'nextDueDate': patch.nextDueDate,
      if (patch.reminderStatus != null)
        'reminderStatus': _dcaPlanStatusWire(patch.reminderStatus!),
      if (patch.clearNote)
        'note': null
      else if (patch.note != null)
        'note': patch.note,
    };
    final d = await _c.patchData('/v1/dca/plans/$planId', body: body);
    return _plan(_m(d));
  }

  @override
  Future<void> markExecutedAsProposal(
    Id reminderId,
    DcaExecutionInput input,
  ) async {
    await _c.postData(
      '/v1/dca/reminders/$reminderId/mark-executed-as-proposal',
      body: {
        'holdingAccountId': input.holdingAccountId,
        'quantity': input.quantity,
        'totalCost': _moneyJson(input.totalCost),
        'quoteCurrency': input.quoteCurrency,
        if (input.executedAt != null) 'executedAt': input.executedAt,
      },
    );
  }

  @override
  Future<void> skipReminder(Id reminderId) async {
    await _c.postData('/v1/dca/reminders/$reminderId/skip');
  }

  @override
  Future<void> snoozeReminder(Id reminderId, {required IsoDate until}) async {
    await _c.postData(
      '/v1/dca/reminders/$reminderId/snooze',
      body: {'until': until},
    );
  }
}

FxRateVm _fxRate(Map<String, dynamic> j) => FxRateVm(
  baseCurrency: '${j['baseCurrency']}',
  quoteCurrency: '${j['quoteCurrency']}',
  rate: '${j['rate']}',
  asOf: '${j['asOf']}',
  status: _quote(j['status']),
);

// ———— 贷款条款 / 头寸 / 还款计划映射 ————
LiabilityType _liabType(Object? s) => switch (s) {
  'student_loan' => LiabilityType.studentLoan,
  'mortgage' => LiabilityType.mortgage,
  'consumer_loan' => LiabilityType.consumerLoan,
  'credit_card' => LiabilityType.creditCard,
  _ => LiabilityType.other,
};

String _liabTypeWire(LiabilityType t) => switch (t) {
  LiabilityType.studentLoan => 'student_loan',
  LiabilityType.mortgage => 'mortgage',
  LiabilityType.consumerLoan => 'consumer_loan',
  LiabilityType.creditCard => 'credit_card',
  LiabilityType.other => 'other',
};

LiabilityTermsVm _liabilityTerms(Map<String, dynamic> j) => LiabilityTermsVm(
  liabilityType: _liabType(j['liabilityType']),
  annualRate: '${j['annualRate']}',
  rateType: j['rateType'] == 'floating'
      ? LiabilityRateType.floating
      : LiabilityRateType.fixed,
  dayCountBasis: _int(j['dayCountBasis']),
  interestStartDate: '${j['interestStartDate']}',
  maturityDate: '${j['maturityDate']}',
  repaymentStartDate: '${j['repaymentStartDate']}',
  nextDueDate: '${j['nextDueDate']}',
  scheduledPayment: _money(j['scheduledPayment']),
  paymentAccountId: '${j['paymentAccountId']}',
  lastInterestAccruedThrough: '${j['lastInterestAccruedThrough']}',
  pendingLoanInterestMovementId: j['pendingLoanInterestMovementId'] as String?,
  pendingLoanInterestThroughDate:
      j['pendingLoanInterestThroughDate'] as String?,
  lastLoanInterestMovementId: j['lastLoanInterestMovementId'] as String?,
);

LiabilityNextPaymentVm _liabilityNextPayment(Map<String, dynamic> j) =>
    LiabilityNextPaymentVm(
      dueDate: '${j['dueDate']}',
      scheduledAmount: _money(j['scheduledAmount']),
      projectedInterest: _money(j['projectedInterest']),
      projectedPrincipal: _money(j['projectedPrincipal']),
    );

/// 公开以便单测直接喂 LiabilityPosition JSON。
LiabilityPositionVm parseLiabilityPositionData(Map<String, dynamic> j) =>
    LiabilityPositionVm(
      accountId: '${j['accountId']}',
      accountName: '${j['accountName']}',
      currency: '${j['currency']}',
      terms: _liabilityTerms(_m(j['terms'])),
      outstandingPrincipal: _money(j['outstandingPrincipal']),
      accruedThrough: '${j['accruedThrough']}',
      accrualDays: _int(j['accrualDays']),
      accruedInterest: _money(j['accruedInterest']),
      nextPayment: _liabilityNextPayment(_m(j['nextPayment'])),
      status: '${j['status']}',
    );

LoanRepaymentScheduleItemVm _scheduleItem(Map<String, dynamic> j) =>
    LoanRepaymentScheduleItemVm(
      sequence: _int(j['sequence']),
      dueDate: '${j['dueDate']}',
      openingBalance: _money(j['openingBalance']),
      interest: _money(j['interest']),
      principal: _money(j['principal']),
      payment: _money(j['payment']),
      closingBalance: _money(j['closingBalance']),
      kind: '${j['kind']}',
    );

/// 公开以便单测直接喂 LoanRepaymentSchedule JSON。
LoanRepaymentScheduleVm parseRepaymentScheduleData(Map<String, dynamic> j) =>
    LoanRepaymentScheduleVm(
      accountId: '${j['accountId']}',
      currency: '${j['currency']}',
      maturityDate: '${j['maturityDate']}',
      items: [for (final i in _list(j['items'])) _scheduleItem(_m(i))],
      hasMore: _bool(j['hasMore']),
    );

class LocalServerLoanRepository implements LoanRepository {
  LocalServerLoanRepository(this._c);
  final DevApiClient _c;

  @override
  Future<List<LiabilityPositionVm>> listLiabilityPositions({
    IsoDate? throughDate,
  }) async => [
    for (final p in _list(
      await _c.getData(
        throughDate == null
            ? '/v1/liability-positions'
            : '/v1/liability-positions?throughDate=$throughDate',
      ),
    ))
      parseLiabilityPositionData(_m(p)),
  ];

  @override
  Future<LoanRepaymentScheduleVm> getRepaymentSchedule(
    Id accountId, {
    int limit = 24,
  }) async => parseRepaymentScheduleData(
    _m(
      await _c.getData(
        '/v1/accounts/$accountId/repayment-schedule?limit=${limit.clamp(1, 360)}',
      ),
    ),
  );

  @override
  Future<AccountVm> updateLiabilityTerms(
    Id accountId,
    LiabilityTermsInput input,
  ) async => _account(
    _m(
      await _c.patchData(
        '/v1/accounts/$accountId/liability-terms',
        body: {
          'liabilityType': _liabTypeWire(input.liabilityType),
          'annualRate': input.annualRate,
          'rateType': input.rateType == LiabilityRateType.floating
              ? 'floating'
              : 'fixed',
          'dayCountBasis': input.dayCountBasis,
          'interestStartDate': input.interestStartDate,
          'maturityDate': input.maturityDate,
          'repaymentStartDate': input.repaymentStartDate,
          'nextDueDate': input.nextDueDate,
          'repaymentFrequency': input.repaymentFrequency,
          'scheduledPayment': _moneyJson(input.scheduledPayment),
          'paymentAccountId': input.paymentAccountId,
        },
      ),
    ),
  );

  @override
  Future<AiAtomicGroupVm> proposeLoanInterest(
    Id accountId, {
    required IsoDate throughDate,
    String? note,
  }) async => _group(
    _m(
      await _c.postData(
        '/v1/accounts/$accountId/loan-interest-proposals',
        body: {
          'throughDate': throughDate,
          if (note != null && note.isNotEmpty) 'note': note,
        },
      ),
    ),
  );
}

// ———— Pi Agent 映射 ————
AgentStatusVm _agentStatus(Map<String, dynamic> j) => AgentStatusVm(
  configured: _bool(j['configured']),
  modelCount: _int(j['modelCount']),
  primaryConversationId: j['primaryConversationId'] as String?,
);

AgentModelVm _agentModel(Map<String, dynamic> j) => AgentModelVm(
  id: '${j['id']}',
  provider: '${j['provider']}',
  displayName: '${j['displayName']}',
  supportsImages: _bool(j['supportsImages']),
);

AgentConversationVm _agentConversation(Map<String, dynamic> j) =>
    AgentConversationVm(
      id: '${j['id']}',
      title: '${j['title']}',
      isPrimary: _bool(j['isPrimary']),
      status: j['status'] == 'archived'
          ? AgentConversationStatus.archived
          : AgentConversationStatus.active,
      createdAt: '${j['createdAt']}',
      updatedAt: '${j['updatedAt']}',
      selectedModelId: j['selectedModelId'] as String?,
    );

AgentMessageRole _agentRole(Object? s) => switch (s) {
  'assistant' => AgentMessageRole.assistant,
  'system' => AgentMessageRole.system,
  _ => AgentMessageRole.user,
};

AgentMessageStatus _agentMessageStatus(Object? s) => switch (s) {
  'queued' => AgentMessageStatus.queued,
  'streaming' => AgentMessageStatus.streaming,
  'failed' => AgentMessageStatus.failed,
  _ => AgentMessageStatus.completed,
};

AgentMessageVm _agentMessage(Map<String, dynamic> j) => AgentMessageVm(
  id: '${j['id']}',
  conversationId: '${j['conversationId']}',
  role: _agentRole(j['role']),
  text: '${j['text'] ?? ''}',
  status: _agentMessageStatus(j['status']),
  createdAt: '${j['createdAt']}',
  runId: j['runId'] as String?,
  completedAt: j['completedAt'] as String?,
  errorCode: j['errorCode'] as String?,
  attachmentIds: [for (final id in _list(j['attachmentIds'])) '$id'],
);

AgentAttachmentVm _agentAttachment(Map<String, dynamic> j) => AgentAttachmentVm(
  id: '${j['id']}',
  fileName: '${j['fileName']}',
  mimeType: '${j['mimeType']}',
  sizeBytes: _int(j['sizeBytes']),
  sha256: '${j['sha256']}',
  createdAt: '${j['createdAt']}',
);

AgentMemoryStatus _agentMemoryStatus(Object? s) => switch (s) {
  'active' => AgentMemoryStatus.active,
  'rejected' => AgentMemoryStatus.rejected,
  _ => AgentMemoryStatus.suggested,
};

AgentMemoryVm _agentMemory(Map<String, dynamic> j) => AgentMemoryVm(
  id: '${j['id']}',
  content: '${j['content']}',
  reason: '${j['reason'] ?? ''}',
  status: _agentMemoryStatus(j['status']),
  createdAt: '${j['createdAt']}',
  updatedAt: '${j['updatedAt']}',
);

AgentQuoteCandidateVm _agentQuoteCandidate(Map<String, dynamic> j) =>
    AgentQuoteCandidateVm(
      id: '${j['id']}',
      kind: j['kind'] == 'fx'
          ? AgentQuoteCandidateKind.fx
          : AgentQuoteCandidateKind.instrument,
      asOf: '${j['asOf']}',
      source: '${j['source']}',
      sourceUrl: '${j['sourceUrl']}',
      status: switch (j['status']) {
        'applied' => AgentQuoteCandidateStatus.applied,
        'rejected' => AgentQuoteCandidateStatus.rejected,
        _ => AgentQuoteCandidateStatus.suggested,
      },
      createdAt: '${j['createdAt']}',
      updatedAt: '${j['updatedAt']}',
      instrumentId: j['instrumentId'] as String?,
      price: j['price'] as String?,
      currency: j['currency'] as String?,
      baseCurrency: j['baseCurrency'] as String?,
      quoteCurrency: j['quoteCurrency'] as String?,
      rate: j['rate'] as String?,
      appliedAt: j['appliedAt'] as String?,
    );

/// 供测试直接校验 wire → VM 映射。
AgentQuoteCandidateVm parseAgentQuoteCandidateData(Map<String, dynamic> j) =>
    _agentQuoteCandidate(j);

AgentEventType _agentEventType(String s) => switch (s) {
  'run.queued' => AgentEventType.runQueued,
  'run.started' => AgentEventType.runStarted,
  'message.delta' => AgentEventType.messageDelta,
  'tool.started' => AgentEventType.toolStarted,
  'tool.completed' => AgentEventType.toolCompleted,
  'run.completed' => AgentEventType.runCompleted,
  'run.failed' => AgentEventType.runFailed,
  _ => AgentEventType.unknown,
};

AgentEventVm agentEventFrom(
  int cursor,
  String event,
  Map<String, dynamic> data,
) => AgentEventVm(
  cursor: cursor,
  type: _agentEventType(event),
  runId: data['runId'] as String?,
  userMessageId: data['userMessageId'] as String?,
  assistantMessageId: data['assistantMessageId'] as String?,
  delta: data['delta'] as String?,
  toolName: data['name'] as String?,
  isError: data['isError'] as bool?,
  code: data['code'] as String?,
);

/// 供测试直接校验 wire → VM 映射。
AgentMessageVm parseAgentMessageData(Map<String, dynamic> j) =>
    _agentMessage(j);
AgentConversationVm parseAgentConversationData(Map<String, dynamic> j) =>
    _agentConversation(j);

class LocalServerAgentRepository implements AgentRepository {
  LocalServerAgentRepository(this._c);
  final DevApiClient _c;

  @override
  Future<AgentStatusVm> getStatus() async =>
      _agentStatus(_m(await _c.getData('/v1/agent/status')));

  @override
  Future<List<AgentModelVm>> listModels() async => [
    for (final m in _list(await _c.getData('/v1/agent/models')))
      _agentModel(_m(m)),
  ];

  @override
  Future<AgentAttachmentVm> uploadAttachment({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async => _agentAttachment(
    _m(
      await _c.postMultipart(
        '/v1/agent/attachments',
        field: 'file',
        fileName: fileName,
        mimeType: mimeType,
        bytes: bytes,
      ),
    ),
  );

  @override
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) async =>
      _agentAttachment(
        _m(await _c.getData('/v1/agent/attachments/$attachmentId')),
      );

  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) async =>
      (await _c.getBytes('/v1/agent/attachments/$attachmentId/content')).bytes;

  @override
  Future<List<AgentMemoryVm>> listMemories() async => [
    for (final m in _list(await _c.getData('/v1/agent/memories')))
      _agentMemory(_m(m)),
  ];

  @override
  Future<AgentMemoryVm> reviewMemory(
    Id memoryId, {
    required AgentMemoryStatus decision,
  }) async => _agentMemory(
    _m(
      await _c.postData(
        '/v1/agent/memories/$memoryId/review',
        body: {
          'decision': decision == AgentMemoryStatus.active
              ? 'active'
              : 'rejected',
        },
      ),
    ),
  );

  @override
  Future<List<AgentConversationVm>> listConversations() async => [
    for (final c in _list(await _c.getData('/v1/agent/conversations')))
      _agentConversation(_m(c)),
  ];

  @override
  Future<AgentConversationVm> createConversation({String? title}) async =>
      _agentConversation(
        _m(
          await _c.postData(
            '/v1/agent/conversations',
            body: {if (title != null && title.isNotEmpty) 'title': title},
          ),
        ),
      );

  @override
  Future<AgentConversationVm> updateConversation(
    Id conversationId, {
    String? title,
    AgentConversationStatus? status,
    String? modelId,
  }) async => _agentConversation(
    _m(
      await _c.patchData(
        '/v1/agent/conversations/$conversationId',
        body: {
          'title': ?title,
          if (status != null)
            'status': status == AgentConversationStatus.archived
                ? 'archived'
                : 'active',
          'modelId': ?modelId,
        },
      ),
    ),
  );

  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async => [
    for (final m in _list(
      await _c.getData('/v1/agent/conversations/$conversationId/messages'),
    ))
      _agentMessage(_m(m)),
  ];

  @override
  Future<AgentRunAcceptedVm> sendMessage(
    Id conversationId, {
    required String text,
    List<Id> attachmentIds = const [],
  }) async {
    final d = _m(
      await _c.postData(
        '/v1/agent/conversations/$conversationId/messages',
        body: {
          'text': text,
          if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
        },
      ),
    );
    return AgentRunAcceptedVm(
      runId: '${d['runId']}',
      userMessageId: '${d['userMessageId']}',
      assistantMessageId: '${d['assistantMessageId']}',
    );
  }

  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async => [
    for (final c in _list(await _c.getData('/v1/agent/quote-candidates')))
      _agentQuoteCandidate(_m(c)),
  ];

  @override
  Future<AgentQuoteCandidateVm> reviewQuoteCandidate(
    Id candidateId, {
    required AgentQuoteCandidateStatus decision,
  }) async => _agentQuoteCandidate(
    _m(
      await _c.postData(
        '/v1/agent/quote-candidates/$candidateId/review',
        body: {
          'decision': decision == AgentQuoteCandidateStatus.applied
              ? 'apply'
              : 'reject',
        },
      ),
    ),
  );

  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) => _c
      .streamEvents(
        '/v1/agent/conversations/$conversationId/events',
        after: after,
      )
      .map((f) => agentEventFrom(f.cursor, f.event, f.data));

  @override
  Future<void> cancelRun(Id runId) async {
    await _c.postData('/v1/agent/runs/$runId/cancel');
  }
}

class LocalServerQuoteRepository implements QuoteRepository {
  LocalServerQuoteRepository(this._c);
  final DevApiClient _c;
  @override
  Future<QuoteStatusSummaryVm> getQuoteSummary() async =>
      _quoteSummary(_m(await _c.getData('/v1/quotes/summary')));

  @override
  Future<List<FxRateVm>> listFxRates() async => [
    for (final r in _list(await _c.getData('/v1/fx-rates'))) _fxRate(_m(r)),
  ];

  @override
  Future<QuoteRefreshResultVm> refreshQuotes({required String mode}) async =>
      _quoteRefreshResult(
        _m(await _c.postData('/v1/quotes/refresh', body: {'mode': mode})),
      );
}

class LocalServerAiProposalRepository implements AiProposalRepository {
  LocalServerAiProposalRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<AiProposalVm>> listPending() async => [
    for (final p in _list(await _c.getData('/v1/ai/proposals/pending')))
      _proposal(_m(p)),
  ];
  @override
  Future<AiProposalVm?> getProposal(Id id) async {
    final d = await _c.getData('/v1/ai/proposals/$id');
    return d == null ? null : _proposal(_m(d));
  }

  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) async =>
      _confirmResult(
        _m(await _c.postData('/v1/ai/atomic-groups/$groupId/approve')),
      );

  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) async {
    await _c.postData(
      '/v1/ai/atomic-groups/$groupId/reject',
      body: reason == null ? null : {'reason': reason},
    );
  }

  @override
  Future<void> createFromText(String text) async {
    await _c.postData('/v1/ai/proposals/from-text', body: {'text': text});
  }

  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) async {
    final body = <String, Object>{'csv': csv};
    if (defaultAccountId != null) {
      body['selectedAccountIds'] = [defaultAccountId];
    }
    if (defaultCurrency != null) {
      body['defaultCurrency'] = defaultCurrency;
    }
    await _c.postData('/v1/ai/proposals/from-csv', body: body);
  }

  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) async {
    final body = <String, Object>{
      'fileName': fileName,
      'imageBase64': imageBase64,
    };
    if (mimeType != null) {
      body['mimeType'] = mimeType;
    }
    await _c.postData('/v1/ai/proposals/from-image', body: body);
  }

  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) async {
    final isIncome = input.type == MovementType.income;
    await _c.postData(
      '/v1/ai/atomic-groups/$groupId/edit',
      body: {
        'proposedMovement': {
          'type': _movementTypeWire(input.type),
          'occurredAt':
              input.occurredAt ?? DateTime.now().toUtc().toIso8601String(),
          'title': input.title,
          if (input.description != null && input.description!.isNotEmpty)
            'description': input.description,
          if (input.categoryId != null) 'categoryId': input.categoryId,
          if (input.counterpartyId != null)
            'counterpartyId': input.counterpartyId,
          'entries': [
            {
              'accountId': input.accountId,
              'amount': input.amount,
              'currency': input.currency,
              'direction': isIncome ? 'in' : 'out',
              'role': 'source',
            },
          ],
        },
      },
    );
  }
}

class LocalServerSnapshotRepository implements SnapshotRepository {
  LocalServerSnapshotRepository(this._c);
  final DevApiClient _c;
  @override
  Future<List<NetWorthSnapshotVm>> listSnapshots() async => [
    for (final s in _list(await _c.getData('/v1/snapshots'))) _snapshot(_m(s)),
  ];
  @override
  Future<NetWorthSnapshotVm?> getLatest() async {
    final d = await _c.getData('/v1/snapshots/latest');
    return d == null ? null : _snapshot(_m(d));
  }

  @override
  Future<NetWorthSnapshotVm> createManualSnapshot({
    required String reason,
  }) async {
    final d = await _c.postData(
      '/v1/snapshots/manual',
      body: {'reason': reason},
    );
    return _snapshot(_m(d));
  }
}

// ———— 订阅解析 / 枚举映射 / 输入构建 ————
SubscriptionStatus _subStatus(Object? s) => switch (s) {
  'trial' => SubscriptionStatus.trial,
  'paused' => SubscriptionStatus.paused,
  'cancelled' => SubscriptionStatus.cancelled,
  'expired' => SubscriptionStatus.expired,
  _ => SubscriptionStatus.active,
};
String _subStatusWire(SubscriptionStatus s) => switch (s) {
  SubscriptionStatus.trial => 'trial',
  SubscriptionStatus.active => 'active',
  SubscriptionStatus.paused => 'paused',
  SubscriptionStatus.cancelled => 'cancelled',
  SubscriptionStatus.expired => 'expired',
};
BillingUnit _billingUnit(Object? s) => switch (s) {
  'day' => BillingUnit.day,
  'week' => BillingUnit.week,
  'year' => BillingUnit.year,
  _ => BillingUnit.month,
};
String _billingUnitWire(BillingUnit u) => switch (u) {
  BillingUnit.day => 'day',
  BillingUnit.week => 'week',
  BillingUnit.month => 'month',
  BillingUnit.year => 'year',
};
SubscriptionDurationUnit _durationUnit(Object? s) => switch (s) {
  'day' => SubscriptionDurationUnit.day,
  'year' => SubscriptionDurationUnit.year,
  _ => SubscriptionDurationUnit.month,
};
String _durationUnitWire(SubscriptionDurationUnit u) => switch (u) {
  SubscriptionDurationUnit.day => 'day',
  SubscriptionDurationUnit.month => 'month',
  SubscriptionDurationUnit.year => 'year',
};

SubscriptionBillingCycleVm _billingCycle(Map<String, dynamic> j) =>
    SubscriptionBillingCycleVm(
      unit: _billingUnit(j['unit']),
      interval: _int(j['interval']),
    );
SubscriptionDurationVm? _durationOrNull(Object? o) {
  if (o is! Map) return null;
  final j = _m(o);
  return SubscriptionDurationVm(
    unit: _durationUnit(j['unit']),
    count: _int(j['count']),
  );
}

/// 公开以便单测直接喂 subscription JSON。
SubscriptionVm parseSubscriptionData(Map<String, dynamic> j) => SubscriptionVm(
  id: '${j['id']}',
  displayName: '${j['displayName'] ?? ''}',
  provider: '${j['provider'] ?? ''}',
  planName: j['planName']?.toString(),
  amount: _money(j['amount']),
  paymentAccountId: '${j['paymentAccountId'] ?? ''}',
  billingCycle: _billingCycle(_m(j['billingCycle'])),
  billingAnchorDay: _int(j['billingAnchorDay']),
  startDate: '${j['startDate'] ?? ''}',
  duration: _durationOrNull(j['duration']),
  endDate: j['endDate']?.toString(),
  nextChargeDate: j['nextChargeDate']?.toString(),
  autoRenew: _bool(j['autoRenew'], fallback: true),
  reminderDaysBefore: _int(j['reminderDaysBefore']),
  status: _subStatus(j['status']),
  pendingChargeMovementId: j['pendingChargeMovementId']?.toString(),
  pendingChargeDate: j['pendingChargeDate']?.toString(),
  lastChargeMovementId: j['lastChargeMovementId']?.toString(),
  lastChargeDate: j['lastChargeDate']?.toString(),
  cancelledAt: j['cancelledAt']?.toString(),
  note: j['note']?.toString(),
);

SubscriptionDueScanSkipReason _dueScanSkipReason(Object? s) => switch (s) {
  'payment_account_unavailable' =>
    SubscriptionDueScanSkipReason.paymentAccountUnavailable,
  'payment_currency_unsupported' =>
    SubscriptionDueScanSkipReason.paymentCurrencyUnsupported,
  _ => SubscriptionDueScanSkipReason.alreadyPending,
};

SubscriptionDueScanSkipVm _dueScanSkip(Map<String, dynamic> j) =>
    SubscriptionDueScanSkipVm(
      subscriptionId: '${j['subscriptionId']}',
      scheduledChargeDate: '${j['scheduledChargeDate'] ?? ''}',
      reason: _dueScanSkipReason(j['reason']),
    );

// created 项是 AiAtomicGroup 本体附加 subscriptionId/scheduledChargeDate（allOf）。
SubscriptionDueScanCreatedVm _dueScanCreated(Map<String, dynamic> j) =>
    SubscriptionDueScanCreatedVm(
      group: _group(j),
      subscriptionId: '${j['subscriptionId']}',
      scheduledChargeDate: '${j['scheduledChargeDate'] ?? ''}',
    );

/// 公开以便单测直接喂 due-scan JSON。
SubscriptionDueScanResultVm parseDueScanData(Map<String, dynamic> j) =>
    SubscriptionDueScanResultVm(
      throughDate: '${j['throughDate'] ?? ''}',
      createdCount: _int(j['createdCount']),
      alreadyPendingCount: _int(j['alreadyPendingCount']),
      blockedCount: _int(j['blockedCount']),
      remainingEligibleCount: _int(j['remainingEligibleCount']),
      hasMore: _bool(j['hasMore'], fallback: false),
      created: [for (final c in _list(j['created'])) _dueScanCreated(_m(c))],
      skipped: [for (final s in _list(j['skipped'])) _dueScanSkip(_m(s))],
    );

Map<String, dynamic> _moneyJson(Money m) => {
  'amount': m.amount,
  'currency': m.currency,
};
Map<String, dynamic> _billingCycleJson(SubscriptionBillingCycleVm c) => {
  'unit': _billingUnitWire(c.unit),
  'interval': c.interval,
};
Map<String, dynamic> _durationJson(SubscriptionDurationVm d) => {
  'unit': _durationUnitWire(d.unit),
  'count': d.count,
};
Map<String, dynamic> _createSubBody(CreateSubscriptionInput i) => {
  'displayName': i.displayName,
  'provider': i.provider,
  if (i.planName != null && i.planName!.isNotEmpty) 'planName': i.planName,
  'amount': _moneyJson(i.amount),
  'paymentAccountId': i.paymentAccountId,
  'billingCycle': _billingCycleJson(i.billingCycle),
  'startDate': i.startDate,
  if (i.nextChargeDate != null && i.nextChargeDate!.isNotEmpty)
    'nextChargeDate': i.nextChargeDate,
  if (i.duration != null) 'duration': _durationJson(i.duration!),
  if (i.endDate != null && i.endDate!.isNotEmpty) 'endDate': i.endDate,
  'autoRenew': i.autoRenew,
  'reminderDaysBefore': i.reminderDaysBefore,
  if (i.note != null && i.note!.isNotEmpty) 'note': i.note,
};
// PATCH 走整表单替换语义：可空字段显式传 null 表示清除；duration/endDate 互斥。
Map<String, dynamic> _updateSubBody(UpdateSubscriptionInput i) => {
  'displayName': i.displayName,
  'provider': i.provider,
  'planName': (i.planName?.isNotEmpty ?? false) ? i.planName : null,
  'amount': _moneyJson(i.amount),
  'paymentAccountId': i.paymentAccountId,
  'billingCycle': _billingCycleJson(i.billingCycle),
  'startDate': i.startDate,
  if (i.nextChargeDate != null && i.nextChargeDate!.isNotEmpty)
    'nextChargeDate': i.nextChargeDate,
  'duration': i.duration != null ? _durationJson(i.duration!) : null,
  'endDate': (i.endDate?.isNotEmpty ?? false) ? i.endDate : null,
  'autoRenew': i.autoRenew,
  'reminderDaysBefore': i.reminderDaysBefore,
  'status': _subStatusWire(i.status),
  'note': (i.note?.isNotEmpty ?? false) ? i.note : null,
};

class LocalServerSubscriptionRepository implements SubscriptionRepository {
  LocalServerSubscriptionRepository(this._c);
  final DevApiClient _c;

  @override
  Future<List<SubscriptionVm>> listSubscriptions() async => [
    for (final s in _list(await _c.getData('/v1/subscriptions')))
      parseSubscriptionData(_m(s)),
  ];
  @override
  Future<List<SubscriptionVm>> listUpcomingSubscriptions({
    int days = 30,
  }) async {
    final d = days.clamp(1, 365);
    return [
      for (final s in _list(
        await _c.getData('/v1/subscriptions/upcoming?days=$d'),
      ))
        parseSubscriptionData(_m(s)),
    ];
  }

  @override
  Future<SubscriptionVm> getSubscription(Id id) async =>
      parseSubscriptionData(_m(await _c.getData('/v1/subscriptions/$id')));
  @override
  Future<SubscriptionVm> createSubscription(
    CreateSubscriptionInput input,
  ) async => parseSubscriptionData(
    _m(await _c.postData('/v1/subscriptions', body: _createSubBody(input))),
  );
  @override
  Future<SubscriptionVm> updateSubscription(
    Id id,
    UpdateSubscriptionInput input,
  ) async => parseSubscriptionData(
    _m(
      await _c.patchData('/v1/subscriptions/$id', body: _updateSubBody(input)),
    ),
  );
  @override
  Future<SubscriptionVm> cancelSubscription(Id id) async =>
      parseSubscriptionData(
        _m(await _c.postData('/v1/subscriptions/$id/cancel')),
      );
  @override
  Future<AiAtomicGroupVm> createChargeProposal(Id id) async =>
      _group(_m(await _c.postData('/v1/subscriptions/$id/charge-proposal')));
  @override
  Future<SubscriptionDueScanResultVm> scanDueChargeProposals({
    required IsoDate throughDate,
    int limit = 100,
  }) async => parseDueScanData(
    _m(
      await _c.postData(
        '/v1/subscriptions/charge-proposals/due-scan',
        body: {'throughDate': throughDate, 'limit': limit.clamp(1, 200)},
      ),
    ),
  );
}
