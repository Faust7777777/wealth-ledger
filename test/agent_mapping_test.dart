// Agent 仓库映射（2026-07-28 任务单 §回归 3）：
// 覆盖全部 /v1/agent 接口的请求形状与 wire → VM 映射、multipart 上传、
// 原图回读、SSE 帧解析与续接参数、401 复用同一 Idempotency-Key。
import 'dart:convert';
import 'dart:typed_data';

import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/auth_store.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 用 UTF-8 字节构造响应：中文正文不能走 http.Response 的 latin1 默认编码。
http.Response _json(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _ok(Object data, {int status = 200}) =>
    _json({'ok': true, 'data': data}, status);

http.Response _err(int status, String code, {String? message}) => _json({
  'ok': false,
  'error': {'code': code, 'message': ?message},
}, status);

Map<String, dynamic> get _conversationJson => {
  'id': 'conv_1',
  'userId': 'u_1',
  'ledgerId': 'l_1',
  'title': '主会话',
  'isPrimary': true,
  'status': 'active',
  'selectedModelId': 'openai/gpt-x',
  'createdAt': '2026-07-28T00:00:00Z',
  'updatedAt': '2026-07-28T01:00:00Z',
};

Map<String, dynamic> get _attachmentJson => {
  'id': 'att_1',
  'userId': 'u_1',
  'ledgerId': 'l_1',
  'fileName': 'receipt.png',
  'mimeType': 'image/png',
  'sizeBytes': 12,
  'sha256': 'a' * 64,
  'createdAt': '2026-07-28T00:00:00Z',
};

/// 一个真实可解码的 1x1 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
  'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('读路径映射', () {
    test('status / models / conversations / messages / memories', () async {
      final paths = <String>[];
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            paths.add(request.url.path);
            return switch (request.url.path) {
              '/v1/agent/status' => _ok({
                'service': 'finwealth-agent',
                'configured': true,
                'userId': 'u_1',
                'ledgerId': 'l_1',
                'modelCount': 2,
                'primaryConversationId': 'conv_1',
              }),
              '/v1/agent/models' => _ok([
                {
                  'id': 'openai/gpt-x',
                  'provider': 'openai',
                  'displayName': 'GPT-X',
                  'supportsImages': true,
                },
              ]),
              '/v1/agent/conversations' => _ok([_conversationJson]),
              '/v1/agent/conversations/conv_1/messages' => _ok([
                {
                  'id': 'msg_1',
                  'conversationId': 'conv_1',
                  'role': 'assistant',
                  'text': '你好',
                  'status': 'completed',
                  'runId': 'run_1',
                  'createdAt': '2026-07-28T00:00:00Z',
                  'completedAt': '2026-07-28T00:00:01Z',
                  'attachmentIds': ['att_1'],
                },
              ]),
              '/v1/agent/memories' => _ok([
                {
                  'id': 'mem_1',
                  'userId': 'u_1',
                  'ledgerId': 'l_1',
                  'content': '记账时按笔数拆分',
                  'reason': '用户多次纠正',
                  'status': 'suggested',
                  'createdAt': '2026-07-28T00:00:00Z',
                  'updatedAt': '2026-07-28T00:00:00Z',
                },
              ]),
              _ => _err(404, 'not_found'),
            };
          }),
        ),
      );

      final status = await repo.getStatus();
      expect(status.configured, isTrue);
      expect(status.modelCount, 2);
      expect(status.primaryConversationId, 'conv_1');

      final models = await repo.listModels();
      expect(models.single.displayName, 'GPT-X');
      expect(models.single.supportsImages, isTrue);

      final conversations = await repo.listConversations();
      expect(conversations.single.isPrimary, isTrue);
      expect(conversations.single.status, AgentConversationStatus.active);
      expect(conversations.single.selectedModelId, 'openai/gpt-x');

      final messages = await repo.listMessages('conv_1');
      expect(messages.single.role, AgentMessageRole.assistant);
      expect(messages.single.status, AgentMessageStatus.completed);
      expect(messages.single.attachmentIds, ['att_1']);

      final memories = await repo.listMemories();
      expect(memories.single.status, AgentMemoryStatus.suggested);
      expect(memories.single.reason, '用户多次纠正');

      expect(paths, hasLength(5));
    });
  });

  group('写路径与幂等', () {
    test('发送消息带 Idempotency-Key 并映射受理结果', () async {
      String? key;
      Map<String, dynamic>? body;
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            key = request.headers['idempotency-key'];
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return _ok({
              'runId': 'run_9',
              'userMessageId': 'msg_u',
              'assistantMessageId': 'msg_a',
            }, status: 202);
          }),
        ),
      );
      final accepted = await repo.sendMessage(
        'conv_1',
        text: '整理这张账单',
        attachmentIds: ['att_1'],
      );
      expect(accepted.runId, 'run_9');
      expect(accepted.assistantMessageId, 'msg_a');
      expect(body!['text'], '整理这张账单');
      expect(body!['attachmentIds'], ['att_1']);
      expect(key, isNotNull);
      expect(key!.length, 32);
    });

    test('401 刷新后重放复用同一个 Idempotency-Key，不重复发送', () async {
      final store = MemoryAuthTokenStore();
      await store.write(
        const StoredAuthSession(
          accessToken: 'old',
          refreshToken: 'r1',
          expiresAt: '2026-07-28T12:00:00+08:00',
          deviceId: 'd1',
        ),
      );
      final keys = <String>[];
      var sends = 0;
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          tokenStore: store,
          client: MockClient((request) async {
            if (request.url.path == '/v1/auth/refresh') {
              return _ok({
                'accessToken': 'new',
                'refreshToken': 'r2',
                'expiresAt': '2026-07-28T13:00:00+08:00',
                'deviceId': 'd1',
              });
            }
            keys.add(request.headers['idempotency-key']!);
            sends += 1;
            if (sends == 1) return _err(401, 'auth_required');
            return _ok({
              'runId': 'run_1',
              'userMessageId': 'msg_u',
              'assistantMessageId': 'msg_a',
            }, status: 202);
          }),
        ),
      );
      await repo.sendMessage('conv_1', text: '你好');
      expect(sends, 2);
      expect(keys, hasLength(2));
      expect(keys[0], keys[1], reason: '重放必须复用同一个 key');
    });

    test('会话改名/归档/换模型只发变化字段', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _ok(_conversationJson);
          }),
        ),
      );
      await repo.updateConversation('conv_1', title: '账单');
      await repo.updateConversation(
        'conv_1',
        status: AgentConversationStatus.archived,
      );
      await repo.updateConversation('conv_1', modelId: 'openai/gpt-y');
      expect(bodies[0], {'title': '账单'});
      expect(bodies[1], {'status': 'archived'});
      expect(bodies[2], {'modelId': 'openai/gpt-y'});
    });

    test('记忆审批发送 decision', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _ok({
              'id': 'mem_1',
              'userId': 'u_1',
              'ledgerId': 'l_1',
              'content': 'c',
              'reason': 'r',
              'status': 'active',
              'createdAt': '2026-07-28T00:00:00Z',
              'updatedAt': '2026-07-28T00:00:00Z',
            });
          }),
        ),
      );
      final reviewed = await repo.reviewMemory(
        'mem_1',
        decision: AgentMemoryStatus.active,
      );
      expect(bodies.single, {'decision': 'active'});
      expect(reviewed.status, AgentMemoryStatus.active);
    });

    test('取消运行只发一次 POST', () async {
      var calls = 0;
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            calls += 1;
            expect(request.url.path, '/v1/agent/runs/run_1/cancel');
            return _ok({'cancelled': true});
          }),
        ),
      );
      await repo.cancelRun('run_1');
      expect(calls, 1);
    });
  });

  group('附件', () {
    test('multipart 携带真实 MIME、文件名与幂等键', () async {
      String? contentType;
      String? rawBody;
      String? key;
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            contentType = request.headers['content-type'];
            key = request.headers['idempotency-key'];
            rawBody = latin1.decode(request.bodyBytes);
            return _ok(_attachmentJson, status: 201);
          }),
        ),
      );
      final meta = await repo.uploadAttachment(
        fileName: 'receipt.png',
        mimeType: 'image/png',
        bytes: _png,
      );
      expect(meta.id, 'att_1');
      expect(meta.sizeBytes, 12);
      expect(contentType, startsWith('multipart/form-data; boundary='));
      expect(key, isNotNull);
      expect(rawBody, contains('name="file"; filename="receipt.png"'));
      expect(rawBody, contains('content-type: image/png'));
    });

    test('413 映射为可重试的校验失败并带 code', () async {
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((_) async => _err(413, 'invalid_attachment_size')),
        ),
      );
      await expectLater(
        repo.uploadAttachment(
          fileName: 'big.png',
          mimeType: 'image/png',
          bytes: _png,
        ),
        throwsA(
          isA<ApiValidationException>().having(
            (e) => e.code,
            'code',
            'invalid_attachment_size',
          ),
        ),
      );
    });

    test('原图回读返回字节', () async {
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            expect(request.url.path, '/v1/agent/attachments/att_1/content');
            return http.Response.bytes(
              _png,
              200,
              headers: {'content-type': 'image/png'},
            );
          }),
        ),
      );
      expect(await repo.getAttachmentContent('att_1'), _png);
    });
  });

  group('报价候选', () {
    test('列表映射：标的与汇率两种形态', () async {
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient(
            (request) async => _ok([
              {
                'id': 'qc_1',
                'userId': 'u_1',
                'ledgerId': 'l_1',
                'kind': 'instrument',
                'instrumentId': 'inst_btc',
                'price': '61234.50',
                'currency': 'USDT',
                'asOf': '2026-07-28T09:30:00Z',
                'source': 'CoinGecko',
                'sourceUrl': 'https://www.coingecko.com/en/coins/bitcoin',
                'status': 'suggested',
                'createdAt': '2026-07-28T09:31:00Z',
                'updatedAt': '2026-07-28T09:31:00Z',
              },
              {
                'id': 'qc_2',
                'userId': 'u_1',
                'ledgerId': 'l_1',
                'kind': 'fx',
                'baseCurrency': 'USD',
                'quoteCurrency': 'CNY',
                'rate': '7.1832',
                'asOf': '2026-07-28T09:30:00Z',
                'source': '中国外汇交易中心',
                'sourceUrl': 'https://www.chinamoney.com.cn/rate',
                'status': 'applied',
                'createdAt': '2026-07-28T09:31:00Z',
                'updatedAt': '2026-07-28T09:32:00Z',
                'appliedAt': '2026-07-28T09:32:00Z',
              },
            ]),
          ),
        ),
      );
      final list = await repo.listQuoteCandidates();
      expect(list, hasLength(2));
      expect(list[0].kind, AgentQuoteCandidateKind.instrument);
      expect(list[0].instrumentId, 'inst_btc');
      expect(list[0].price, '61234.50');
      expect(list[0].currency, 'USDT');
      expect(list[0].status, AgentQuoteCandidateStatus.suggested);
      expect(list[1].kind, AgentQuoteCandidateKind.fx);
      expect(list[1].rate, '7.1832');
      expect(list[1].baseCurrency, 'USD');
      expect(list[1].status, AgentQuoteCandidateStatus.applied);
      expect(list[1].appliedAt, '2026-07-28T09:32:00Z');
    });

    test('审核发送 apply / reject 并带 Idempotency-Key', () async {
      final bodies = <Map<String, dynamic>>[];
      final keys = <String>[];
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient((request) async {
            expect(request.url.path, '/v1/agent/quote-candidates/qc_1/review');
            keys.add(request.headers['idempotency-key']!);
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _ok({
              'id': 'qc_1',
              'userId': 'u_1',
              'ledgerId': 'l_1',
              'kind': 'instrument',
              'instrumentId': 'inst_btc',
              'price': '61234.50',
              'currency': 'USDT',
              'asOf': '2026-07-28T09:30:00Z',
              'source': 'CoinGecko',
              'sourceUrl': 'https://www.coingecko.com/en/coins/bitcoin',
              'status': 'applied',
              'createdAt': '2026-07-28T09:31:00Z',
              'updatedAt': '2026-07-28T09:32:00Z',
            });
          }),
        ),
      );
      await repo.reviewQuoteCandidate(
        'qc_1',
        decision: AgentQuoteCandidateStatus.applied,
      );
      await repo.reviewQuoteCandidate(
        'qc_1',
        decision: AgentQuoteCandidateStatus.rejected,
      );
      expect(bodies[0], {'decision': 'apply'});
      expect(bodies[1], {'decision': 'reject'});
      expect(keys, hasLength(2));
      expect(keys[0], isNot(keys[1]), reason: '两次独立写入用不同 key');
    });

    test('409 已处理映射为冲突异常', () async {
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient(
            (_) async => _err(409, 'agent_quote_candidate_already_reviewed'),
          ),
        ),
      );
      await expectLater(
        repo.reviewQuoteCandidate(
          'qc_1',
          decision: AgentQuoteCandidateStatus.applied,
        ),
        throwsA(isA<ApiConflictException>()),
      );
    });
  });

  group('SSE', () {
    test('解析 id/event/data 帧，跳过 keep-alive', () async {
      final frames = <AgentEventVm>[];
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient.streaming((request, _) async {
            expect(request.headers['accept'], 'text/event-stream');
            const payload =
                ': keep-alive\n\n'
                'id: 1\nevent: run.queued\n'
                'data: {"runId":"r1","userMessageId":"mu","assistantMessageId":"ma"}\n\n'
                'id: 2\nevent: message.delta\n'
                'data: {"assistantMessageId":"ma","delta":"你"}\n\n'
                'id: 3\nevent: tool.started\n'
                'data: {"runId":"r1","name":"finwealth_query"}\n\n'
                'id: 4\nevent: run.failed\n'
                'data: {"runId":"r1","assistantMessageId":"ma","code":"agent_run_failed"}\n\n';
            return http.StreamedResponse(
              Stream.value(utf8.encode(payload)),
              200,
            );
          }),
        ),
      );
      await for (final e in repo.events('conv_1')) {
        frames.add(e);
      }
      expect(frames.map((e) => e.type).toList(), [
        AgentEventType.runQueued,
        AgentEventType.messageDelta,
        AgentEventType.toolStarted,
        AgentEventType.runFailed,
      ]);
      expect(frames[0].userMessageId, 'mu');
      expect(frames[1].delta, '你');
      expect(frames[2].toolName, 'finwealth_query');
      expect(frames[3].code, 'agent_run_failed');
      expect(frames.last.cursor, 4);
    });

    test('续接同时带 after 查询与 Last-Event-ID', () async {
      Uri? uri;
      String? lastEventId;
      final repo = LocalServerAgentRepository(
        DevApiClient(
          'http://127.0.0.1:8790',
          client: MockClient.streaming((request, _) async {
            uri = request.url;
            lastEventId = request.headers['last-event-id'];
            return http.StreamedResponse(const Stream.empty(), 200);
          }),
        ),
      );
      await repo.events('conv_1', after: 7).drain<void>();
      expect(uri!.queryParameters['after'], '7');
      expect(lastEventId, '7');
    });
  });
}
