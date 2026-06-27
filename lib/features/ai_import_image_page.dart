// Wealth Ledger — 图片导入：粘贴图片 Base64 / data URL → 生成候选 proposal → AI 待确认复核。
// 当前无原生文件选择依赖；图片只作为 evidence，确认前不写账本。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class AiImportImagePage extends ConsumerStatefulWidget {
  const AiImportImagePage({super.key});

  @override
  ConsumerState<AiImportImagePage> createState() => _AiImportImagePageState();
}

class _AiImportImagePageState extends ConsumerState<AiImportImagePage> {
  final _fileName = TextEditingController(text: 'screenshot.png');
  final _imageData = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _fileName.dispose();
    _imageData.dispose();
    super.dispose();
  }

  String get _normalizedBase64 {
    final raw = _imageData.text.trim();
    final comma = raw.indexOf(',');
    final value = raw.startsWith('data:image/') && comma >= 0
        ? raw.substring(comma + 1)
        : raw;
    return value.replaceAll(RegExp(r'\s+'), '');
  }

  String? get _mimeType {
    final raw = _imageData.text.trim();
    final match = RegExp(r'^data:(image/[^;]+);base64,').firstMatch(raw);
    if (match != null) return match.group(1);
    final name = _fileName.text.trim().toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.heic')) return 'image/heic';
    return 'image/png';
  }

  bool get _canSubmit =>
      !_busy &&
      _fileName.text.trim().isNotEmpty &&
      _normalizedBase64.isNotEmpty;

  String? _validateBase64() {
    final data = _normalizedBase64;
    if (data.isEmpty) return '请粘贴图片 Base64 或 data URL。';
    try {
      final bytes = base64Decode(data);
      if (bytes.isEmpty) return '图片数据为空。';
      if (bytes.length > 10 * 1024 * 1024) return '图片超过 10MB，先压缩后再导入。';
      return null;
    } catch (_) {
      return '图片数据不是有效 Base64。';
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final error = _validateBase64();
    setState(() => _error = error);
    if (error != null) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref
          .read(aiProposalRepositoryProvider)
          .createFromImage(
            fileName: _fileName.text.trim(),
            imageBase64: _normalizedBase64,
            mimeType: _mimeType,
          );
      ref.invalidate(aiPendingProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('已生成图片候选；请在「AI 待确认」复核')),
      );
      router.go('/ai-review');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 导入 · 图片')),
      body: ContentMaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            Text(
              '当前先支持粘贴图片 Base64 或 data URL。图片只生成候选 evidence；确认前不会进入余额、流水或净值。'
              '真正多模态识别接入后，这里会升级为直接选择图片。',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _fileName,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '图片文件名',
                hintText: 'screenshot.png',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _imageData,
              minLines: 8,
              maxLines: 14,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: '图片 Base64 / data URL',
                hintText: 'data:image/png;base64,iVBORw0KGgo...',
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'MIME：${_mimeType ?? 'image/png'}。建议图片小于 10MB。',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpacing.base),
            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: Text(_busy ? '生成中…' : '生成候选'),
            ),
          ],
        ),
      ),
    );
  }
}
