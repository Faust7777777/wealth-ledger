// Agent 面板与全局入口（2026-07-28 任务单 §P0/§P1/§回归 1-2）：
// 全局低强调入口在窄屏进全屏页、宽屏开右栏且不遮挡导航；
// 无模型时不可发送；断线可重连；记忆建议批准前不表现为已生效；
// 历史图片从附件接口恢复；360/1200/1440 宽无 overflow。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:finwealth/app/app.dart';
import 'package:finwealth/app/home_shell.dart';
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart'
    show ApiConflictException, ApiValidationException;
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
  'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _conversation = AgentConversationVm(
  id: 'conv_1',
  title: '主会话',
  isPrimary: true,
  status: AgentConversationStatus.active,
  createdAt: '2026-07-28T00:00:00Z',
  updatedAt: '2026-07-28T00:00:00Z',
);

AgentMessageVm _message({
  String id = 'msg_1',
  AgentMessageRole role = AgentMessageRole.assistant,
  String text = '已经看过这张账单了',
  List<String> attachmentIds = const [],
}) => AgentMessageVm(
  id: id,
  conversationId: 'conv_1',
  role: role,
  text: text,
  status: AgentMessageStatus.completed,
  createdAt: '2026-07-28T00:00:00Z',
  attachmentIds: attachmentIds,
);

class _FakeAgentRepo implements AgentRepository {
  _FakeAgentRepo({
    this.configured = true,
    this.messages = const [],
    this.memories = const [],
    this.attachmentFails = false,
    this.uploadFailure,
    this.candidates = const [],
    this.reviewFailure,
    this.reviewGate,
  });

  final bool configured;
  final List<AgentMessageVm> messages;
  List<AgentMemoryVm> memories;
  final bool attachmentFails;
  final Object? uploadFailure;
  List<AgentQuoteCandidateVm> candidates;
  final Object? reviewFailure;
  final Completer<void>? reviewGate;
  final List<({String id, AgentQuoteCandidateStatus decision})> quoteReviews =
      [];
  final List<({String id, AgentMemoryStatus decision})> reviews = [];
  final List<({String fileName, String mimeType, int size})> uploads = [];
  int attachmentReads = 0;
  int metaReads = 0;
  AgentAttachmentVm? attachmentMeta;

  @override
  Future<AgentStatusVm> getStatus() async =>
      AgentStatusVm(configured: configured, modelCount: configured ? 1 : 0);
  @override
  Future<List<AgentModelVm>> listModels() async => const [
    AgentModelVm(
      id: 'openai/gpt-x',
      provider: 'openai',
      displayName: 'GPT-X',
      supportsImages: true,
    ),
  ];
  @override
  Future<List<AgentConversationVm>> listConversations() async => const [
    _conversation,
  ];
  @override
  Future<List<AgentMessageVm>> listMessages(Id conversationId) async =>
      messages;
  @override
  Stream<AgentEventVm> events(Id conversationId, {int? after}) =>
      const Stream.empty();
  @override
  Future<List<AgentMemoryVm>> listMemories() async => memories;
  @override
  Future<AgentMemoryVm> reviewMemory(
    Id memoryId, {
    required AgentMemoryStatus decision,
  }) async {
    reviews.add((id: memoryId, decision: decision));
    final updated = [
      for (final m in memories)
        if (m.id == memoryId)
          AgentMemoryVm(
            id: m.id,
            content: m.content,
            reason: m.reason,
            status: decision,
            createdAt: m.createdAt,
            updatedAt: m.updatedAt,
          )
        else
          m,
    ];
    memories = updated;
    return updated.firstWhere((m) => m.id == memoryId);
  }

  @override
  Future<Uint8List> getAttachmentContent(Id attachmentId) async {
    attachmentReads += 1;
    if (attachmentFails) throw Exception('offline');
    return _png;
  }

  @override
  Future<AgentAttachmentVm> getAttachment(Id attachmentId) async {
    metaReads += 1;
    if (attachmentFails) throw Exception('offline');
    return attachmentMeta ??
        AgentAttachmentVm(
          id: attachmentId,
          fileName: 'bill.png',
          mimeType: 'image/png',
          sizeBytes: _png.length,
          sha256: 'b' * 64,
          createdAt: '2026-07-28T00:00:00Z',
        );
  }

  @override
  Future<AgentAttachmentVm> uploadAttachment({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    uploads.add((fileName: fileName, mimeType: mimeType, size: bytes.length));
    if (uploadFailure != null) throw uploadFailure!;
    return AgentAttachmentVm(
      id: 'att_${uploads.length}',
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      sha256: 'b' * 64,
      createdAt: '2026-07-28T00:00:00Z',
    );
  }

  @override
  Future<AgentRunAcceptedVm> sendMessage(
    Id conversationId, {
    required String text,
    List<Id> attachmentIds = const [],
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentConversationVm> createConversation({String? title}) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentConversationVm> updateConversation(
    Id conversationId, {
    String? title,
    AgentConversationStatus? status,
    String? modelId,
  }) => throw UnsupportedError('unused');
  @override
  Future<List<AgentQuoteCandidateVm>> listQuoteCandidates() async => candidates;

  @override
  Future<AgentQuoteCandidateVm> reviewQuoteCandidate(
    Id candidateId, {
    required AgentQuoteCandidateStatus decision,
  }) async {
    quoteReviews.add((id: candidateId, decision: decision));
    if (reviewGate != null) await reviewGate!.future;
    if (reviewFailure != null) throw reviewFailure!;
    final reviewed = [
      for (final c in candidates)
        if (c.id == candidateId)
          AgentQuoteCandidateVm(
            id: c.id,
            kind: c.kind,
            asOf: c.asOf,
            source: c.source,
            sourceUrl: c.sourceUrl,
            status: decision,
            createdAt: c.createdAt,
            updatedAt: c.updatedAt,
            instrumentId: c.instrumentId,
            price: c.price,
            currency: c.currency,
            baseCurrency: c.baseCurrency,
            quoteCurrency: c.quoteCurrency,
            rate: c.rate,
          )
        else
          c,
    ];
    candidates = reviewed;
    return reviewed.firstWhere((c) => c.id == candidateId);
  }

  @override
  Future<List<AgentAutomationVm>> listAutomations() async => const [];
  @override
  Future<List<AgentNotificationVm>> listNotifications() async => const [];
  @override
  Future<AgentAutomationVm> createAutomation({
    required AgentAutomationKind kind,
    required int intervalHours,
    bool enabled = true,
    IsoDateTime? startAt,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentAutomationVm> updateAutomation(
    Id automationId, {
    int? intervalHours,
    bool? enabled,
    IsoDateTime? nextRunAt,
  }) => throw UnsupportedError('unused');
  @override
  Future<AgentAutomationVm> runAutomation(Id automationId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentNotificationVm> markNotificationRead(Id notificationId) =>
      throw UnsupportedError('unused');
  @override
  Future<void> cancelRun(Id runId) => throw UnsupportedError('unused');

  @override
  Future<List<AgentProviderVm>> listProviders() async => const [];
  @override
  Future<AgentProviderOAuthAttemptVm> startProviderOAuth(String providerId) =>
      throw UnsupportedError('unused');
  @override
  Future<AgentProviderOAuthAttemptVm> getProviderOAuthAttempt(Id attemptId) =>
      throw UnsupportedError('unused');
  @override
  Future<void> disconnectProvider(String providerId) =>
      throw UnsupportedError('unused');
}

/// Riverpod 未导出 Override 类型，覆盖列表只能就地写在 ProviderScope 里。
Widget _scope(
  _FakeAgentRepo repo, {
  List<AiProposalVm> pending = const [],
  AgentFilePicker? picker,
  VoidCallback? onHoldings,
  required Widget child,
}) => ProviderScope(
  overrides: [
    agentRepositoryProvider.overrideWithValue(repo),
    if (picker != null) agentAttachmentPickerProvider.overrideWithValue(picker),
    aiPendingProvider.overrideWith((ref) async => pending),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
    accountsProvider.overrideWith((ref) async => const <AccountVm>[]),
    holdingsProvider.overrideWith((ref) async {
      onHoldings?.call();
      return const <HoldingVm>[];
    }),
    allocationProvider.overrideWith(
      (ref) async => const AssetAllocationVm(
        slices: [],
        totalAssets: Money(amount: '0', currency: 'CNY'),
        totalLiabilities: Money(amount: '0', currency: 'CNY'),
        netWorth: Money(amount: '0', currency: 'CNY'),
      ),
    ),
    instrumentsProvider.overrideWith(
      (ref) async => const [
        InstrumentVm(
          id: 'inst_btc',
          type: InstrumentType.crypto,
          displayName: 'Bitcoin',
          symbol: 'BTC',
          quoteCurrency: 'USDT',
        ),
      ],
    ),
  ],
  child: child,
);

Widget _panelHost(
  _FakeAgentRepo repo, {
  List<AiProposalVm> pending = const [],
  AgentFilePicker? picker,
  VoidCallback? onHoldings,
}) => _scope(
  repo,
  pending: pending,
  picker: picker,
  onHoldings: onHoldings,
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Column(
              children: [
                // 让 holdingsProvider 保持存活，才能观察到 invalidate 的效果。
                if (onHoldings != null) const _HoldingsWatcher(),
                const Expanded(child: AgentPanel()),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/ai-review',
          builder: (_, _) => const Scaffold(body: Text('review-page')),
        ),
      ],
    ),
  ),
);

class _HoldingsWatcher extends ConsumerWidget {
  const _HoldingsWatcher();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(holdingsProvider);
    return const SizedBox.shrink();
  }
}

void main() {
  group('面板', () {
    testWidgets('无模型：输入区不可发送并给出简短说明', (tester) async {
      await tester.pumpWidget(_panelHost(_FakeAgentRepo(configured: false)));
      await tester.pumpAndSettle();
      expect(find.text('服务器尚未配置模型'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      // 不伪造回复。
      expect(find.textContaining('助手'), findsNothing);
    });

    testWidgets('有模型：可输入并展示历史消息', (tester) async {
      await tester.pumpWidget(
        _panelHost(_FakeAgentRepo(messages: [_message()])),
      );
      await tester.pumpAndSettle();
      expect(find.text('已经看过这张账单了'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('服务器尚未配置模型'), findsNothing);
    });

    testWidgets('SSE 结束后显示断线提示并可重连', (tester) async {
      await tester.pumpWidget(_panelHost(_FakeAgentRepo()));
      await tester.pumpAndSettle();
      expect(find.text('连接已断开'), findsOneWidget);
      expect(find.text('重连'), findsOneWidget);
      await tester.tap(find.text('重连'));
      await tester.pumpAndSettle();
      expect(find.text('连接已断开'), findsOneWidget);
    });

    testWidgets('待审核存在时提供低强调「前往审核」', (tester) async {
      await tester.pumpWidget(
        _panelHost(
          _FakeAgentRepo(messages: [_message()]),
          pending: const [
            AiProposalVm(
              id: 'prop_1',
              status: AiProposalStatus.pending,
              sourceLabel: '助手',
              groups: [],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final action = find.text('前往审核');
      expect(action, findsOneWidget);
      expect(
        find.ancestor(of: action, matching: find.byType(TextButton)),
        findsOneWidget,
      );
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('review-page'), findsOneWidget);
    });
  });

  group('记忆审批', () {
    testWidgets('建议卡片显示内容与原因，批准前不表现为已生效', (tester) async {
      final repo = _FakeAgentRepo(
        memories: const [
          AgentMemoryVm(
            id: 'mem_1',
            content: '按笔数拆分记账',
            reason: '用户多次纠正',
            status: AgentMemoryStatus.suggested,
            createdAt: '2026-07-28T00:00:00Z',
            updatedAt: '2026-07-28T00:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(find.text('记忆建议'), findsOneWidget);
      expect(find.text('按笔数拆分记账'), findsOneWidget);
      expect(find.text('用户多次纠正'), findsOneWidget);
      expect(find.text('批准'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.textContaining('已生效'), findsNothing);

      await tester.tap(find.text('批准'));
      await tester.pumpAndSettle();
      expect(repo.reviews.single.decision, AgentMemoryStatus.active);
      // 批准后不再出现在建议列表。
      expect(find.text('记忆建议'), findsNothing);
    });

    testWidgets('拒绝后同样从建议列表移除', (tester) async {
      final repo = _FakeAgentRepo(
        memories: const [
          AgentMemoryVm(
            id: 'mem_1',
            content: '按笔数拆分记账',
            reason: '',
            status: AgentMemoryStatus.suggested,
            createdAt: '2026-07-28T00:00:00Z',
            updatedAt: '2026-07-28T00:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(repo.reviews.single.decision, AgentMemoryStatus.rejected);
      expect(find.text('记忆建议'), findsNothing);
    });
  });

  group('全局入口', () {
    testWidgets('窄屏：入口进全屏页，返回可退回', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _scope(_FakeAgentRepo(), child: const WealthLedgerApp()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kAgentEntryKey), findsOneWidget);
      await tester.tap(find.byKey(kAgentEntryKey));
      await tester.pumpAndSettle();
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.text('助手'), findsWidgets);

      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(find.byType(AgentPanel), findsNothing);
    });

    testWidgets('宽屏：入口开右栏，导航仍完整可见', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _scope(_FakeAgentRepo(), child: const WealthLedgerApp()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      final railBefore = tester.getRect(find.byType(NavigationRail));

      await tester.tap(find.byKey(kAgentEntryKey));
      await tester.pumpAndSettle();
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(
        tester.getRect(find.byType(NavigationRail)),
        railBefore,
        reason: '右栏不得遮挡或挤压主导航',
      );

      final panel = tester.getRect(find.byType(AgentPanel));
      expect(panel.left, greaterThan(railBefore.right));
      expect(panel.width, kAgentRailWidth);
      expect(tester.takeException(), isNull);
    });
  });

  group('待发送附件草稿区', () {
    Future<void> pick(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
    }

    test('扩展名 → 准确 MIME；白名单外返回 null', () {
      expect(agentAttachmentMimeType('a.png'), 'image/png');
      expect(agentAttachmentMimeType('a.JPG'), 'image/jpeg');
      expect(agentAttachmentMimeType('a.webp'), 'image/webp');
      expect(agentAttachmentMimeType('a.txt'), 'text/plain');
      expect(agentAttachmentMimeType('a.csv'), 'text/csv');
      expect(agentAttachmentMimeType('a.pdf'), 'application/pdf');
      expect(
        agentAttachmentMimeType('a.xlsx'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      expect(agentAttachmentMimeType('a.zip'), 'application/zip');
      expect(agentAttachmentMimeType('a.heic'), isNull);
      expect(agentAttachmentMimeType('a.docx'), isNull);
      expect(agentAttachmentMimeType('a'), isNull);
      expect(agentMimeIsImage('image/png'), isTrue);
      expect(agentMimeIsImage('application/pdf'), isFalse);
    });

    test('失败文案：413 / 格式不符 / UTF-8 不合法各一句，不外露内部标识', () {
      expect(
        agentAttachmentErrorMessage('invalid_attachment_size'),
        '文件超过 15 MiB，请压缩后再试。',
      );
      expect(
        agentAttachmentErrorMessage('unsupported_attachment_type'),
        '只支持图片、TXT、CSV、PDF、XLSX 与 ZIP。',
      );
      expect(
        agentAttachmentErrorMessage(
          'attachment_mime_mismatch',
          fileName: 'bill.pdf',
        ),
        '文件内容与扩展名不一致，请重新选择。',
      );
      expect(
        agentAttachmentErrorMessage(
          'attachment_mime_mismatch',
          fileName: 'bill.csv',
        ),
        '文本内容不是有效的 UTF-8，请另存后再试。',
      );
      for (final code in [
        'invalid_attachment_size',
        'attachment_mime_mismatch',
        null,
      ]) {
        expect(
          RegExp(r'[a-z_]{6,}').hasMatch(agentAttachmentErrorMessage(code)),
          isFalse,
        );
      }
    });

    testWidgets('图片：缩略图 chip，可移除，不显示实现细节', (tester) async {
      final repo = _FakeAgentRepo();
      await tester.pumpWidget(
        _panelHost(
          repo,
          picker: () async => (fileName: 'bill.png', bytes: _png),
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);

      expect(repo.uploads.single.fileName, 'bill.png');
      expect(repo.uploads.single.mimeType, 'image/png');
      expect(find.widgetWithText(Chip, 'bill.png'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('image/png'), findsNothing);
      expect(find.textContaining('base64'), findsNothing);
      expect(find.textContaining('bbbb'), findsNothing);

      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Chip, 'bill.png'), findsNothing);
    });

    testWidgets('文档：类型图标 + 文件名 + 大小的紧凑 chip，不读正文', (tester) async {
      final repo = _FakeAgentRepo();
      final csv = Uint8List.fromList(
        utf8.encode('date,amount\n2026-07-28,18.00\n'),
      );
      await tester.pumpWidget(
        _panelHost(
          repo,
          picker: () async => (fileName: 'wechat.csv', bytes: csv),
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);

      expect(repo.uploads.single.mimeType, 'text/csv');
      expect(find.byIcon(Icons.grid_on_outlined), findsOneWidget);
      // 文件名与大小分成两段：大小完整可见，只有文件名会省略。
      expect(find.text('wechat.csv'), findsOneWidget);
      expect(find.text(' · ${agentFileSize(csv.length)}'), findsOneWidget);
      // 不把文件正文读出来展示，也不宣称已解析。
      expect(find.textContaining('date,amount'), findsNothing);
      expect(find.textContaining('已解析'), findsNothing);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('PDF / XLSX / ZIP 各自的类型图标', (tester) async {
      for (final (name, icon) in [
        ('bill.pdf', Icons.picture_as_pdf_outlined),
        ('book.xlsx', Icons.table_chart_outlined),
        ('pack.zip', Icons.folder_zip_outlined),
      ]) {
        await tester.pumpWidget(
          _panelHost(
            _FakeAgentRepo(),
            picker: () async => (fileName: name, bytes: _png),
          ),
        );
        await tester.pumpAndSettle();
        await pick(tester);
        expect(find.byIcon(icon), findsOneWidget, reason: name);
      }
    });

    testWidgets('不支持的扩展名：不上传并给一句中文', (tester) async {
      final repo = _FakeAgentRepo();
      await tester.pumpWidget(
        _panelHost(
          repo,
          picker: () async => (fileName: 'bill.heic', bytes: _png),
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      expect(repo.uploads, isEmpty);
      expect(find.text('只支持图片、TXT、CSV、PDF、XLSX 与 ZIP。'), findsOneWidget);
    });

    testWidgets('413：不加入草稿区，显示可重试的短提示', (tester) async {
      final repo = _FakeAgentRepo(
        uploadFailure: ApiValidationException(
          '/v1/agent/attachments',
          code: 'invalid_attachment_size',
        ),
      );
      await tester.pumpWidget(
        _panelHost(
          repo,
          picker: () async => (fileName: 'big.pdf', bytes: _png),
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      expect(find.text('文件超过 15 MiB，请压缩后再试。'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'big.pdf'), findsNothing);
      expect(find.textContaining('413'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.attach_file),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('UTF-8 不合法：按所选文本文件给出对应提示', (tester) async {
      final repo = _FakeAgentRepo(
        uploadFailure: ApiValidationException(
          '/v1/agent/attachments',
          code: 'attachment_mime_mismatch',
        ),
      );
      await tester.pumpWidget(
        _panelHost(
          repo,
          picker: () async => (fileName: 'broken.csv', bytes: _png),
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      expect(find.text('文本内容不是有效的 UTF-8，请另存后再试。'), findsOneWidget);
    });

    testWidgets('取消选择：什么都不发生', (tester) async {
      final repo = _FakeAgentRepo();
      await tester.pumpWidget(_panelHost(repo, picker: () async => null));
      await tester.pumpAndSettle();
      await pick(tester);
      expect(repo.uploads, isEmpty);
      expect(find.byType(Chip), findsNothing);
    });
  });

  group('历史附件', () {
    testWidgets('图片：先读元数据再解码字节', (tester) async {
      final repo = _FakeAgentRepo(
        messages: [
          _message(attachmentIds: const ['att_1']),
        ],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(repo.metaReads, 1);
      expect(repo.attachmentReads, 1);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('文档：只显示文件 chip，绝不去取字节', (tester) async {
      final repo =
          _FakeAgentRepo(
              messages: [
                _message(attachmentIds: const ['att_1']),
              ],
            )
            ..attachmentMeta = const AgentAttachmentVm(
              id: 'att_1',
              fileName: 'statement.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 240000,
              sha256: 'c',
              createdAt: '2026-07-28T00:00:00Z',
            );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(repo.metaReads, 1);
      expect(repo.attachmentReads, 0, reason: 'PDF 字节不该交给图片解码器');
      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
      expect(find.textContaining('statement.pdf'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('元数据失败：给重试而不是空白', (tester) async {
      final repo = _FakeAgentRepo(
        messages: [
          _message(attachmentIds: const ['att_1']),
        ],
        attachmentFails: true,
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(repo.metaReads, 2);
    });
  });

  group('报价候选', () {
    AgentQuoteCandidateVm instrumentCandidate({
      String id = 'qc_1',
      AgentQuoteCandidateStatus status = AgentQuoteCandidateStatus.suggested,
    }) => AgentQuoteCandidateVm(
      id: id,
      kind: AgentQuoteCandidateKind.instrument,
      instrumentId: 'inst_btc',
      price: '61234.50',
      currency: 'USDT',
      asOf: '2026-07-28T09:30:00Z',
      source: 'CoinGecko',
      sourceUrl: 'https://www.coingecko.com/en/coins/bitcoin',
      status: status,
      createdAt: '2026-07-28T09:31:00Z',
      updatedAt: '2026-07-28T09:31:00Z',
    );

    const fxCandidate = AgentQuoteCandidateVm(
      id: 'qc_fx',
      kind: AgentQuoteCandidateKind.fx,
      baseCurrency: 'USD',
      quoteCurrency: 'CNY',
      rate: '7.1832',
      asOf: '2026-07-28T09:30:00Z',
      source: '中国外汇交易中心',
      sourceUrl: 'https://www.chinamoney.com.cn/rate',
      status: AgentQuoteCandidateStatus.suggested,
      createdAt: '2026-07-28T09:31:00Z',
      updatedAt: '2026-07-28T09:31:00Z',
    );

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.textContaining('报价建议'));
      await tester.pumpAndSettle();
    }

    test('主体、数值与来源域名的纯函数映射', () {
      const instruments = [
        InstrumentVm(
          id: 'inst_btc',
          type: InstrumentType.crypto,
          displayName: 'Bitcoin',
          symbol: 'BTC',
          quoteCurrency: 'USDT',
        ),
      ];
      expect(
        agentQuoteSubject(instrumentCandidate(), instruments),
        'Bitcoin · BTC',
      );
      expect(agentQuoteSubject(fxCandidate, instruments), 'USD / CNY');
      expect(agentQuoteValue(instrumentCandidate()), '61234.50 USDT');
      expect(agentQuoteValue(fxCandidate), '7.1832 CNY');
      expect(
        agentSourceHost('https://www.coingecko.com/en/coins/bitcoin'),
        'www.coingecko.com',
      );
      expect(
        agentQuoteSubject(instrumentCandidate(), const []),
        isNot(contains('inst_')),
      );
    });

    testWidgets('外层只有一条紧凑入口；卡片在可滚动 sheet 里', (tester) async {
      final repo = _FakeAgentRepo(
        candidates: [instrumentCandidate(), fxCandidate],
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      // 外层不直接展开候选。
      expect(find.text('报价建议 2'), findsOneWidget);
      expect(find.text('Bitcoin · BTC'), findsNothing);
      expect(find.byType(Card), findsNothing);

      await openSheet(tester);
      expect(find.text('Bitcoin · BTC'), findsOneWidget);
      expect(find.text('61234.50 USDT'), findsOneWidget);
      expect(find.text('USD / CNY'), findsOneWidget);
      expect(find.text('7.1832 CNY'), findsOneWidget);
      expect(find.textContaining('CoinGecko'), findsOneWidget);
      expect(find.text('www.coingecko.com'), findsOneWidget);
      // 不显示内部 ID、哈希、tool 名或存储字段。
      expect(find.textContaining('inst_btc'), findsNothing);
      expect(find.textContaining('qc_1'), findsNothing);
      expect(find.textContaining('finwealth_'), findsNothing);
      // 不出现常驻防御性文案。
      expect(find.textContaining('仅供参考'), findsNothing);
      expect(find.textContaining('自行核'), findsNothing);
      expect(find.textContaining('可能不准'), findsNothing);
    });

    testWidgets('已处理的候选不进入入口计数', (tester) async {
      await tester.pumpWidget(
        _panelHost(
          _FakeAgentRepo(
            candidates: [
              instrumentCandidate(status: AgentQuoteCandidateStatus.applied),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('报价建议'), findsNothing);
    });

    testWidgets('采用：发 apply、刷新估值视图、候选消失', (tester) async {
      var holdingBuilds = 0;
      final repo = _FakeAgentRepo(candidates: [instrumentCandidate()]);
      await tester.pumpWidget(
        _panelHost(repo, onHoldings: () => holdingBuilds += 1),
      );
      await tester.pumpAndSettle();
      final before = holdingBuilds;
      await openSheet(tester);
      await tester.tap(find.text('采用'));
      await tester.pumpAndSettle();
      expect(
        repo.quoteReviews.single.decision,
        AgentQuoteCandidateStatus.applied,
      );
      expect(find.text('已采用这条报价'), findsOneWidget);
      expect(find.textContaining('报价建议'), findsNothing);
      expect(holdingBuilds, greaterThan(before), reason: '采用后须刷新报价派生视图');
    });

    testWidgets('忽略：发 reject 且不刷新估值视图', (tester) async {
      var holdingBuilds = 0;
      final repo = _FakeAgentRepo(candidates: [instrumentCandidate()]);
      await tester.pumpWidget(
        _panelHost(repo, onHoldings: () => holdingBuilds += 1),
      );
      await tester.pumpAndSettle();
      final before = holdingBuilds;
      await openSheet(tester);
      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();
      expect(
        repo.quoteReviews.single.decision,
        AgentQuoteCandidateStatus.rejected,
      );
      expect(find.textContaining('报价建议'), findsNothing);
      expect(holdingBuilds, before, reason: '忽略永不写入，不该刷新估值');
      expect(find.text('已采用这条报价'), findsNothing);
    });

    testWidgets('采用失败：保留候选并显示简短错误', (tester) async {
      final repo = _FakeAgentRepo(
        candidates: [instrumentCandidate()],
        reviewFailure: Exception('boom'),
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(find.text('采用'));
      await tester.pumpAndSettle();
      expect(find.text('操作失败，请重试'), findsOneWidget);
      expect(find.text('Bitcoin · BTC'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
    });

    testWidgets('409：提示已处理并重新拉取列表', (tester) async {
      final repo = _FakeAgentRepo(
        candidates: [instrumentCandidate()],
        reviewFailure: ApiConflictException(
          '/v1/agent/quote-candidates/qc_1/review',
          code: 'agent_quote_candidate_already_reviewed',
        ),
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(find.text('采用'));
      await tester.pumpAndSettle();
      expect(find.text('这条建议已被处理，已重新加载'), findsOneWidget);
      expect(find.textContaining('agent_quote'), findsNothing);
    });

    testWidgets('重复点击只产生一次请求', (tester) async {
      final gate = Completer<void>();
      final repo = _FakeAgentRepo(
        candidates: [instrumentCandidate()],
        reviewGate: gate,
      );
      await tester.pumpWidget(_panelHost(repo));
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(find.text('采用'));
      await tester.pump();
      await tester.tap(find.text('采用'), warnIfMissed: false);
      await tester.pump();
      expect(repo.quoteReviews, hasLength(1));
      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.quoteReviews, hasLength(1));
    });

    testWidgets('10 条候选在窄屏与桌面矮窗口下都不挤掉聊天区', (tester) async {
      final many = [
        for (var i = 0; i < 10; i += 1) instrumentCandidate(id: 'qc_$i'),
      ];
      for (final size in const [Size(360, 560), Size(1200, 520)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _panelHost(
            _FakeAgentRepo(
              candidates: many,
              messages: [_message(text: '这是会话里的一条历史消息')],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '入口态 ${size.width}');

        // 外层只有一条入口，聊天消息仍然可见且有可用高度。
        expect(find.text('报价建议 10'), findsOneWidget);
        expect(find.text('这是会话里的一条历史消息'), findsOneWidget);
        final list = tester.getRect(find.byType(ListView).first);
        expect(
          list.height,
          greaterThan(120),
          reason: '聊天区高度被挤压：${list.height} @ ${size.width}',
        );

        await openSheet(tester);
        expect(tester.takeException(), isNull, reason: 'sheet ${size.width}');
        // sheet 有高度上限且可滚动，不会一路铺开 10 张卡。
        final sheet = tester.getRect(find.byType(AgentQuoteCandidateSheet));
        expect(sheet.height, lessThanOrEqualTo(size.height));
        await tester.drag(find.byType(ListView).last, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '滚动 ${size.width}');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    });
  });

  testWidgets('360 / 1200 / 1440 宽面板无 overflow', (tester) async {
    for (final width in [360.0, 1200.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _panelHost(
          _FakeAgentRepo(
            messages: [
              _message(
                role: AgentMessageRole.user,
                id: 'msg_u',
                text: '帮我整理这张微信账单里的所有支出，并按商户归类。',
              ),
              _message(attachmentIds: const ['att_1']),
            ],
            memories: const [
              AgentMemoryVm(
                id: 'mem_1',
                content: '按笔数拆分记账，不要合并同一天的多笔支出',
                reason: '用户多次纠正',
                status: AgentMemoryStatus.suggested,
                createdAt: '2026-07-28T00:00:00Z',
                updatedAt: '2026-07-28T00:00:00Z',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
  });
}
