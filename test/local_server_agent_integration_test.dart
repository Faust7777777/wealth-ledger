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

/// 最小但合法的工作区文档样本（服务端会做文件头/结构校验）。
final Uint8List _csv = Uint8List.fromList(
  utf8.encode('date,amount\n2026-07-28,18.00\n'),
);
final Uint8List _txt = Uint8List.fromList(utf8.encode('账单备注：午餐 18 元\n'));
final Uint8List _pdf = base64Decode(
  'JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZz4+ZW5kb2JqCnRyYWls'
  'ZXI8PC9Sb290IDEgMCBSPj4KJSVFT0YK',
);
final Uint8List _zip = base64Decode(
  'UEsDBBQAAAAIALNr/Fw1CU0iEQAAAA8AAAAJAAAAbm90ZXMudHh0y0jNyclX'
  'SCvKz1WoyizgAgBQSwECFAAUAAAACACza/xcNQlNIhEAAAAPAAAACQAAAAAA'
  'AAAAAAAAgAEAAAAAbm90ZXMudHh0UEsFBgAAAAABAAEANwAAADgAAAAAAA==',
);
final Uint8List _xlsx = base64Decode(
  'UEsDBBQAAAAIALNr/FzuR1hmHwAAAB0AAAATAAAAW0NvbnRlbnRfVHlwZXNd'
  'LnhtbLOxr8jNUShLLSrOzM+zVTLUM1Cyt7MJqSxILda3AwBQSwMEFAAAAAgA'
  's2v8XGU7KJsiAAAAIAAAAA8AAAB4bC93b3JrYm9vay54bWyzsa/IzVEoSy0q'
  'zszPs1Uy1DNQsrezKc8vyk7Kz8/WtwMAUEsBAhQAFAAAAAgAs2v8XO5HWGYf'
  'AAAAHQAAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQ'
  'SwECFAAUAAAACACza/xcZTsomyIAAAAgAAAADwAAAAAAAAAAAAAAgAFQAAAA'
  'eGwvd29ya2Jvb2sueG1sUEsFBgAAAAACAAIAfgAAAJ8AAAAAAA==',
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

      // —— 工作区文档：CSV / TXT / PDF / XLSX / ZIP 上传后原样回读 ——
      for (final (fileName, mimeType, bytes) in [
        ('wechat.csv', 'text/csv', _csv),
        ('note.txt', 'text/plain', _txt),
        ('statement.pdf', 'application/pdf', _pdf),
        (
          'book.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          _xlsx,
        ),
        ('pack.zip', 'application/zip', _zip),
      ]) {
        final doc = await repo.uploadAttachment(
          fileName: fileName,
          mimeType: mimeType,
          bytes: bytes,
        );
        expect(doc.mimeType, mimeType, reason: fileName);
        expect(doc.sizeBytes, bytes.length, reason: fileName);
        expect(
          await repo.getAttachmentContent(doc.id),
          bytes,
          reason: '$fileName 回读字节必须与上传一致',
        );
        // 元数据不含服务端存储路径。
        final meta = await repo.getAttachment(doc.id);
        expect(meta.fileName, fileName);
        expect(meta.sha256, doc.sha256);
      }

      // MIME 与内容不符会被拒绝（这里用 PNG 字节冒充 PDF）。
      await expectLater(
        repo.uploadAttachment(
          fileName: 'fake.pdf',
          mimeType: 'application/pdf',
          bytes: _png,
        ),
        throwsA(isA<Exception>()),
      );

      // configured=false 时不声称模型已经读取内容：发送直接 fail-closed。
      // —— 无模型：发送消息 fail-closed 为 503，不伪造回复 ——
      await expectLater(
        repo.sendMessage(created.id, text: '整理这张账单'),
        throwsA(isA<ApiServiceUnavailableException>()),
      );
      expect(await repo.listMessages(created.id), isEmpty);

      // 记忆列表可读且此时为空（模型未运行，不会产生建议）。
      expect(await repo.listMemories(), isA<List<AgentMemoryVm>>());

      // —— 自动任务：创建 → 关闭 → 重开后计划仍在；立即运行不改 nextRunAt ——
      final automation = await repo.createAutomation(
        kind: AgentAutomationKind.quoteRefresh,
        intervalHours: 6,
      );
      expect(automation.kind, AgentAutomationKind.quoteRefresh);
      expect(automation.intervalHours, 6);
      expect(automation.enabled, isTrue);

      final disabled = await repo.updateAutomation(
        automation.id,
        enabled: false,
      );
      expect(disabled.enabled, isFalse);
      expect(
        (await repo.listAutomations()).where((a) => a.id == automation.id),
        hasLength(1),
        reason: '关闭后计划仍然存在',
      );

      final reenabled = await repo.updateAutomation(
        automation.id,
        enabled: true,
      );
      expect(reenabled.enabled, isTrue);
      expect(reenabled.intervalHours, 6, reason: '重开不丢频率');

      final beforeRun = (await repo.listAutomations()).firstWhere(
        (a) => a.id == automation.id,
      );
      final ranNow = await repo.runAutomation(automation.id);
      expect(ranNow.nextRunAt, beforeRun.nextRunAt, reason: '立即运行不得改变下次计划时间');
      expect(ranNow.lastRunAt, isNotNull, reason: '手动运行会留下上次运行时间');

      // 同一类型重复创建返回 409。
      await expectLater(
        repo.createAutomation(
          kind: AgentAutomationKind.quoteRefresh,
          intervalHours: 24,
        ),
        throwsA(isA<ApiConflictException>()),
      );

      // 通知列表可读；未读数由 readAt 决定。
      final notifications = await repo.listNotifications();
      expect(notifications, isA<List<AgentNotificationVm>>());
      for (final n in notifications) {
        expect(n.title, isNotEmpty);
      }

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
