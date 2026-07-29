// Wealth Ledger — AI 文本导入：输入一句话，整理成待确认记录。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/api_mock_repositories.dart' show ApiServiceUnavailableException;
import '../data/providers.dart';
import '../theme/app_dimens.dart';

class AiImportTextPage extends ConsumerStatefulWidget {
  const AiImportTextPage({super.key});
  @override
  ConsumerState<AiImportTextPage> createState() => _AiImportTextPageState();
}

class _AiImportTextPageState extends ConsumerState<AiImportTextPage> {
  final _controller = TextEditingController();
  bool _busy = false;

  /// 整理服务暂不可用：保留原文本，就地提供重试。
  bool _unavailable = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _unavailable = false;
    });
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(aiProposalRepositoryProvider).createFromText(text);
      ref.invalidate(aiPendingProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(const SnackBar(content: Text('已加入待确认')));
      router.go('/ai-review');
    } on ApiServiceUnavailableException {
      // 不展示 provider 名或上游状态码；文本原样保留。
      if (mounted) setState(() => _unavailable = true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 导入 · 文本')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '例如：午餐 18 元',
              ),
            ),
            if (_unavailable) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '整理失败，请稍后重试。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.base),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? '导入中…' : '导入'),
            ),
          ],
        ),
      ),
    );
  }
}
