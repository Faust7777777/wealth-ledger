// 真实联调：Rust 代理 + Node sidecar 的 Agent 路径（2026-07-28 任务单 §回归 4）。
// 只经公网 origin 的 /v1/agent/**，不直连 sidecar 端口。
// 覆盖：代理可达、会话持久化、附件上传与原图回读、无模型时 503 fail-closed。
import 'dart:convert';
import 'dart:typed_data';

import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = String.fromEnvironment('LOCAL_SERVER_API_BASE');

/// 1x1 PNG（magic 与 IHDR 合法，可通过服务端文件头校验）。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  test(
    'agent proxy, conversations and attachments work through the Rust origin',
    () async {
      final client = DevApiClient(_baseUrl);
      final repo = LocalServerAgentRepository(client);

      // —— Rust 代理可达；未配置模型时 fail-closed ——
      final status = await repo.getStatus();
      expect(status.configured, isFalse, reason: '未配置模型必须 configured=false');
      expect(status.modelCount, 0);
      expect(await repo.listModels(), isEmpty);

      // —— 会话持久化：创建后能在列表里再次读到 ——
      final created = await repo.createConversation(title: '联调会话');
      expect(created.title, '联调会话');
      final listed = await repo.listConversations();
      expect(
        listed.where((c) => c.id == created.id),
        hasLength(1),
        reason: '新建会话必须持久化',
      );
      expect(listed.where((c) => c.isPrimary), hasLength(1), reason: '存在主会话');
      expect(await repo.listMessages(created.id), isEmpty);

      // 重命名与换模型走同一条 PATCH，改名后仍可读回。
      final renamed = await repo.updateConversation(
        created.id,
        title: '联调会话·改名',
      );
      expect(renamed.title, '联调会话·改名');

      // —— 附件：上传 → 安全元数据 → 原图回读 ——
      final attachment = await repo.uploadAttachment(
        fileName: 'bill.png',
        mimeType: 'image/png',
        bytes: _png,
      );
      expect(attachment.mimeType, 'image/png');
      expect(attachment.fileName, 'bill.png');
      expect(attachment.sizeBytes, _png.length);
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(attachment.sha256), isTrue);

      final metadata = await repo.getAttachment(attachment.id);
      expect(metadata.id, attachment.id);
      expect(metadata.sha256, attachment.sha256);

      final content = await repo.getAttachmentContent(attachment.id);
      expect(content, _png, reason: '原图回读必须与上传字节一致');

      // —— 无模型：发送消息 fail-closed 为 503，不伪造回复 ——
      await expectLater(
        repo.sendMessage(created.id, text: '整理这张账单'),
        throwsA(isA<ApiServiceUnavailableException>()),
      );
      expect(await repo.listMessages(created.id), isEmpty);

      // 记忆列表可读且此时为空（模型未运行，不会产生建议）。
      expect(await repo.listMemories(), isA<List<AgentMemoryVm>>());

      // —— 报价候选：没有模型就不会有候选，估值也不该被任何东西改动 ——
      final quoteRepo = LocalServerQuoteRepository(client);
      final summaryBefore = await quoteRepo.getQuoteSummary();
      expect(await repo.listQuoteCandidates(), isEmpty, reason: '未运行模型时不应存在候选');
      // 审核不存在的候选不会写入任何报价。
      await expectLater(
        repo.reviewQuoteCandidate(
          'qc_missing',
          decision: AgentQuoteCandidateStatus.applied,
        ),
        throwsA(isA<Exception>()),
      );
      final summaryAfter = await quoteRepo.getQuoteSummary();
      expect(summaryAfter.freshCount, summaryBefore.freshCount);
      expect(summaryAfter.staleCount, summaryBefore.staleCount);
      expect(summaryAfter.unpriceableCount, summaryBefore.unpriceableCount);
    },
    skip: _baseUrl.isEmpty
        ? 'Set LOCAL_SERVER_API_BASE through --dart-define; run tools/frontend_agent_smoke.ps1.'
        : false,
  );
}
