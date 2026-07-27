// Wealth Ledger — 图片整理：选图 → 缩略预览 → 「整理」→ AI 审核。
// 主路径是文件选择；粘贴数据收进低强调折叠项。
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/api_mock_repositories.dart'
    show ApiServiceUnavailableException, ApiValidationException;
import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// 支持的图片扩展名 → MIME。HEIC 不在支持范围。
const Map<String, String> kSupportedImageMimeTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
};

String? mimeTypeForFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0) return null;
  return kSupportedImageMimeTypes[fileName.substring(dot + 1).toLowerCase()];
}

/// 服务端 400 的 error.code → 一句中文原因（不外露英文 message 与技术细节）。
String imageValidationMessage(String? code) => switch (code) {
  'ai_image_input_mime_invalid' => '只支持 PNG、JPEG、WEBP 图片。',
  'ai_image_input_too_large' => '图片超过 10 MiB，请压缩后再试。',
  'ai_image_input_file_name_invalid' => '文件名无效，请重新选择图片。',
  'ai_image_input_data_invalid' => '图片内容与格式不一致，请重新选择。',
  _ => '图片未通过校验，请重新选择。',
};

class AiImportImagePage extends ConsumerStatefulWidget {
  const AiImportImagePage({super.key});

  @override
  ConsumerState<AiImportImagePage> createState() => _AiImportImagePageState();
}

class _AiImportImagePageState extends ConsumerState<AiImportImagePage> {
  final _pasted = TextEditingController();

  Uint8List? _bytes;
  String _fileName = '';
  String _mimeType = 'image/png';
  bool _busy = false;
  bool _picking = false;
  bool _unavailable = false;
  String? _error;

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  bool get _canSubmit => !_busy && !_picking && _bytes != null;

  Future<void> _pickImage() async {
    if (_busy || _picking) return;
    setState(() {
      _picking = true;
      _error = null;
      _unavailable = false;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      const typeGroup = XTypeGroup(
        label: 'images',
        extensions: ['png', 'jpg', 'jpeg', 'webp'],
        mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
      );
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;
      final mime = mimeTypeForFileName(file.name);
      if (mime == null) {
        setState(() => _error = '只支持 PNG、JPEG、WEBP 图片。');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        setState(() => _error = '图片数据为空，请重新选择。');
        return;
      }
      setState(() {
        _bytes = bytes;
        _fileName = file.name;
        _mimeType = mime;
        _error = null;
      });
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('选择图片失败，请重试')));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 兜底路径：把折叠项里粘贴的 Base64 / data URL 变成同一份预览与提交数据。
  void _applyPasted() {
    final raw = _pasted.text.trim();
    final dataUrl = RegExp(r'^data:(image/[a-zA-Z]+);base64,').firstMatch(raw);
    final encoded = (dataUrl == null ? raw : raw.substring(dataUrl.end))
        .replaceAll(RegExp(r'\s+'), '');
    if (encoded.isEmpty) {
      setState(() => _error = '请先粘贴图片数据。');
      return;
    }
    final declared = dataUrl?.group(1);
    if (declared != null && !kSupportedImageMimeTypes.containsValue(declared)) {
      setState(() => _error = '只支持 PNG、JPEG、WEBP 图片。');
      return;
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty) {
        setState(() => _error = '图片数据为空，请重新粘贴。');
        return;
      }
      setState(() {
        _bytes = bytes;
        _mimeType = declared ?? 'image/png';
        _fileName = _fileName.isEmpty
            ? 'pasted.${_mimeType == 'image/jpeg' ? 'jpg' : _mimeType.split('/').last}'
            : _fileName;
        _error = null;
        _unavailable = false;
      });
    } catch (_) {
      setState(() => _error = '图片数据无法识别，请重新粘贴。');
    }
  }

  void _reset() {
    setState(() {
      _bytes = null;
      _fileName = '';
      _pasted.clear();
      _error = null;
      _unavailable = false;
    });
  }

  Future<void> _submit() async {
    if (_busy || _bytes == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _unavailable = false;
    });
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(aiProposalRepositoryProvider)
          .createFromImage(
            fileName: _fileName,
            imageBase64: base64Encode(_bytes!),
            mimeType: _mimeType,
          );
      ref.invalidate(aiPendingProvider);
      ref.invalidate(overviewProvider);
      router.go('/ai-review');
    } on ApiValidationException catch (e) {
      // 400：一句中文原因，所选图片保留，可直接重新选择或重试。
      setState(() => _error = imageValidationMessage(e.code));
    } on ApiServiceUnavailableException {
      // 503：保留页面状态，只给一句失败与重试。
      setState(() => _unavailable = true);
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('整理失败，请稍后重试。')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 导入 · 图片')),
      body: ContentMaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            if (bytes == null)
              OutlinedButton.icon(
                onPressed: _picking ? null : _pickImage,
                icon: const Icon(Icons.image_outlined),
                label: Text(_picking ? '选择中…' : '选择图片'),
              )
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.memory(
                  bytes,
                  height: 160,
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 160,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _fileName,
                      style: AppType.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _reset,
                    child: const Text('重新选择'),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _error!,
                style: AppType.caption.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            if (_unavailable) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(child: Text('整理失败，请稍后重试。', style: AppType.caption)),
                  TextButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.base),
            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: Text(_busy ? '整理中…' : '整理'),
            ),
            const SizedBox(height: AppSpacing.sm),
            // 兜底：极少数场景直接粘贴图片数据，默认收起。
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('粘贴图片数据', style: AppType.caption),
              children: [
                TextField(
                  controller: _pasted,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '图片数据',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _applyPasted,
                    child: const Text('使用这张图片'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
