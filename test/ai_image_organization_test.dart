// AI 图片整理（2026-07-19 任务单）：只接受 PNG/JPEG/WEBP（无 HEIC）、
// 默认页面只有选图/预览/文件名/重新选择/整理（无常驻 Base64 与技术说明）、
// 400 一句中文原因且保留图片、503 保留状态可重试、360/1200 宽无 overflow。
import 'package:finwealth/core/types.dart';
import 'package:finwealth/data/api_mock_repositories.dart';
import 'package:finwealth/data/providers.dart';
import 'package:finwealth/data/repositories.dart';
import 'package:finwealth/data/view_models.dart';
import 'package:finwealth/features/ai_import_image_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 1x1 透明 PNG（真实可解码，magic 与 IHDR 合法）。
const kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
    'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

const _caps = LedgerCapabilitiesVm(
  dataSourceMode: 'local_server',
  canWriteConfirmedLedger: true,
  canCreateAccount: true,
  canRecordMovement: true,
  canConfirmProposal: true,
  canPersistPendingProposal: true,
  proposalPersistence: 'file',
);

class _FakeAiRepo implements AiProposalRepository {
  _FakeAiRepo({this.failures = const []});
  final List<Object> failures;
  int calls = 0;
  final List<(String, String, String?)> images = [];

  @override
  Future<void> createFromImage({
    required String fileName,
    required String imageBase64,
    String? mimeType,
  }) async {
    images.add((fileName, imageBase64, mimeType));
    final index = calls;
    calls += 1;
    if (index < failures.length) throw failures[index];
  }

  @override
  Future<List<AiProposalVm>> listPending() async => const [];
  @override
  Future<AiProposalVm?> getProposal(Id id) async => null;
  @override
  Future<ConfirmResultVm> approveAtomicGroup(Id groupId) =>
      throw UnsupportedError('unused');
  @override
  Future<void> rejectAtomicGroup(Id groupId, {String? reason}) =>
      throw UnsupportedError('unused');
  @override
  Future<void> createFromText(String text) => throw UnsupportedError('unused');
  @override
  Future<void> createFromCsv(
    String csv, {
    Id? defaultAccountId,
    String? defaultCurrency,
  }) => throw UnsupportedError('unused');
  @override
  Future<void> editAtomicGroup(Id groupId, ManualRecordInput input) =>
      throw UnsupportedError('unused');
}

Widget _host(_FakeAiRepo repo) => ProviderScope(
  overrides: [
    capabilitiesProvider.overrideWith((ref) async => _caps),
    aiProposalRepositoryProvider.overrideWithValue(repo),
    aiPendingProvider.overrideWith((ref) async => const <AiProposalVm>[]),
    overviewProvider.overrideWith(
      (ref) async => const PortfolioOverviewVm(
        pendingSummary: PendingSummaryVm(),
        quoteStatusSummary: QuoteStatusSummaryVm(),
        primaryHoldings: [],
        recentMovements: [],
      ),
    ),
  ],
  child: MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const AiImportImagePage()),
        GoRoute(
          path: '/ai-review',
          builder: (_, _) => const Scaffold(body: Text('review-page')),
        ),
      ],
    ),
  ),
);

/// 通过兜底折叠项载入一张真实 PNG（组件测试里不能弹系统文件选择器）。
Future<void> _loadPastedPng(WidgetTester tester) async {
  await tester.tap(find.text('粘贴图片数据'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), kTinyPngBase64);
  await tester.tap(find.text('使用这张图片'));
  await tester.pumpAndSettle();
}

void main() {
  group('格式与错误映射', () {
    test('只接受 PNG/JPEG/WEBP，HEIC 不可选', () {
      expect(mimeTypeForFileName('receipt.png'), 'image/png');
      expect(mimeTypeForFileName('receipt.PNG'), 'image/png');
      expect(mimeTypeForFileName('receipt.jpg'), 'image/jpeg');
      expect(mimeTypeForFileName('receipt.jpeg'), 'image/jpeg');
      expect(mimeTypeForFileName('receipt.webp'), 'image/webp');
      expect(mimeTypeForFileName('receipt.heic'), isNull);
      expect(mimeTypeForFileName('receipt.gif'), isNull);
      expect(mimeTypeForFileName('receipt'), isNull);
      expect(kSupportedImageMimeTypes.containsValue('image/heic'), isFalse);
    });

    test('400 error.code → 一句中文原因，不外露英文与技术细节', () {
      expect(
        imageValidationMessage('ai_image_input_mime_invalid'),
        '只支持 PNG、JPEG、WEBP 图片。',
      );
      expect(
        imageValidationMessage('ai_image_input_data_invalid'),
        '图片内容与格式不一致，请重新选择。',
      );
      expect(
        imageValidationMessage('ai_image_input_too_large'),
        '图片超过 10 MiB，请压缩后再试。',
      );
      expect(
        imageValidationMessage('ai_image_input_file_name_invalid'),
        '文件名无效，请重新选择图片。',
      );
      expect(imageValidationMessage(null), '图片未通过校验，请重新选择。');
      for (final code in [
        'ai_image_input_mime_invalid',
        'ai_image_input_data_invalid',
        null,
      ]) {
        final text = imageValidationMessage(code);
        expect(RegExp(r'[a-z_]{6,}').hasMatch(text), isFalse, reason: text);
      }
    });
  });

  group('默认页面', () {
    testWidgets('只有选图与整理；无常驻 Base64 输入框与技术说明', (tester) async {
      await tester.pumpWidget(_host(_FakeAiRepo()));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '选择图片'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '整理'), findsOneWidget);
      // 兜底项默认收起：输入框未建，页面上没有 Base64/data URL/MIME/大小说明。
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Base64'), findsNothing);
      expect(find.textContaining('data:image'), findsNothing);
      expect(find.textContaining('MIME'), findsNothing);
      expect(find.textContaining('10MB'), findsNothing);
      expect(find.textContaining('10 MiB'), findsNothing);
      // 未选图时不能提交。
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '整理'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('选好图后：缩略预览 + 文件名 + 重新选择', (tester) async {
      await tester.pumpWidget(_host(_FakeAiRepo()));
      await tester.pumpAndSettle();
      await _loadPastedPng(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('pasted.png'), findsOneWidget);
      expect(find.text('重新选择'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '整理'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('重新选择'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '选择图片'), findsOneWidget);
    });
  });

  group('提交与失败处理', () {
    testWidgets('成功：按 fileName/mimeType/base64 提交并进入复核', (tester) async {
      final repo = _FakeAiRepo();
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await _loadPastedPng(tester);
      await tester.tap(find.widgetWithText(FilledButton, '整理'));
      await tester.pumpAndSettle();
      expect(repo.images, hasLength(1));
      expect(repo.images.single.$1, 'pasted.png');
      expect(repo.images.single.$2, kTinyPngBase64.replaceAll('\n', ''));
      expect(repo.images.single.$3, 'image/png');
      expect(find.text('review-page'), findsOneWidget);
    });

    testWidgets('400：一句中文原因，图片保留可重新选择', (tester) async {
      final repo = _FakeAiRepo(
        failures: [
          ApiValidationException(
            '/v1/ai/proposals/from-image',
            code: 'ai_image_input_data_invalid',
            message: 'Image data does not match its declared format.',
          ),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await _loadPastedPng(tester);
      await tester.tap(find.widgetWithText(FilledButton, '整理'));
      await tester.pumpAndSettle();
      expect(find.text('图片内容与格式不一致，请重新选择。'), findsOneWidget);
      // 图片保留；不外露英文 message、provider、状态码。
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('pasted.png'), findsOneWidget);
      expect(find.textContaining('does not match'), findsNothing);
      expect(find.textContaining('400'), findsNothing);
      expect(find.textContaining('openai'), findsNothing);
      expect(find.text('review-page'), findsNothing);
    });

    testWidgets('503：保留页面状态并提供重试；重试成功进入复核', (tester) async {
      final repo = _FakeAiRepo(
        failures: [
          ApiServiceUnavailableException(
            '/v1/ai/proposals/from-image',
            code: 'ai_provider_unavailable',
            message: 'openai_responses upstream 503',
          ),
        ],
      );
      await tester.pumpWidget(_host(repo));
      await tester.pumpAndSettle();
      await _loadPastedPng(tester);
      await tester.tap(find.widgetWithText(FilledButton, '整理'));
      await tester.pumpAndSettle();
      expect(find.text('整理失败，请稍后重试。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('pasted.png'), findsOneWidget);
      expect(find.textContaining('openai'), findsNothing);
      expect(find.textContaining('503'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(repo.calls, 2);
      expect(find.text('review-page'), findsOneWidget);
    });
  });

  testWidgets('360 与 1200 宽无 overflow', (tester) async {
    for (final width in [360.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(_FakeAiRepo()));
      await tester.pumpAndSettle();
      await _loadPastedPng(tester);
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
  });
}
