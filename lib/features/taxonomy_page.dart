// Wealth Ledger — 分类与对手方基础维护。
// 分类/对手方是 AI 可读取的词表，但不是封闭穷举目录；最终入账仍由用户确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';

String categoryKindLabel(CategoryKind k) => switch (k) {
  CategoryKind.income => '收入',
  CategoryKind.expense => '支出',
  CategoryKind.transfer => '转账',
  CategoryKind.investment => '投资',
  CategoryKind.liability => '负债',
  CategoryKind.system => '系统',
};

List<String> _splitAliases(String text) => text
    .split(RegExp(r'[,，;；\n]'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toSet()
    .toList();

class TaxonomyPage extends ConsumerWidget {
  const TaxonomyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final counterpartiesAsync = ref.watch(counterpartiesProvider);
    final categories = categoriesAsync.asData?.value ?? const <CategoryVm>[];
    final counterparties =
        counterpartiesAsync.asData?.value ?? const <CounterpartyVm>[];
    final loading = categoriesAsync.isLoading || counterpartiesAsync.isLoading;
    final error = categoriesAsync.hasError
        ? categoriesAsync.error
        : counterpartiesAsync.hasError
        ? counterpartiesAsync.error
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('分类与对手方')),
      body: ContentMaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            Text(
              '这些词表会暴露给 AI 用于填充分类和对手方；AI 只能生成候选，确认前不会写入账本。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (loading) ...[
              const SizedBox(height: AppSpacing.base),
              const LinearProgressIndicator(),
            ],
            if (error != null) ...[
              const SizedBox(height: AppSpacing.base),
              ErrorStateView(
                message: '$error',
                onRetry: () {
                  ref.invalidate(categoriesProvider);
                  ref.invalidate(counterpartiesProvider);
                },
              ),
            ],
            SectionHeader(title: '分类'),
            _CategoryCreateCard(categories: categories),
            const SizedBox(height: AppSpacing.sm),
            if (categories.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.label_outline),
                  title: Text('还没有分类'),
                  subtitle: Text('先创建常用分类，例如 工资收入、咖啡饮品、定投投入。'),
                ),
              )
            else
              for (final c in categories)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.label_outline),
                    title: Text(c.displayName),
                    subtitle: Text(
                      [
                        categoryKindLabel(c.kind),
                        if (c.aiDescription?.isNotEmpty ?? false)
                          c.aiDescription!,
                      ].join(' · '),
                    ),
                    trailing: c.isSystem ? const Chip(label: Text('系统')) : null,
                  ),
                ),
            SectionHeader(title: '对手方'),
            _CounterpartyCreateCard(categories: categories),
            const SizedBox(height: AppSpacing.sm),
            if (counterparties.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.storefront_outlined),
                  title: Text('还没有对手方'),
                  subtitle: Text('对手方可以是商户、平台、发薪方或转账对象。'),
                ),
              )
            else
              for (final p in counterparties)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: Text(p.displayName),
                    subtitle: Text(
                      [
                        if (p.aliases.isNotEmpty) '别名：${p.aliases.join('、')}',
                        if (p.categoryHintId != null)
                          '默认分类：${_categoryName(categories, p.categoryHintId!)}',
                      ].join(' · '),
                    ),
                    trailing: p.isUserMerged
                        ? const Chip(label: Text('已合并'))
                        : null,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

String _categoryName(List<CategoryVm> categories, String id) =>
    categories
        .where((c) => c.id == id)
        .map((c) => c.displayName)
        .fold<String?>(null, (previous, name) => previous ?? name) ??
    id;

class _CategoryCreateCard extends ConsumerStatefulWidget {
  const _CategoryCreateCard({required this.categories});
  final List<CategoryVm> categories;

  @override
  ConsumerState<_CategoryCreateCard> createState() =>
      _CategoryCreateCardState();
}

class _CategoryCreateCardState extends ConsumerState<_CategoryCreateCard> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  CategoryKind _kind = CategoryKind.expense;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .createCategory(
            CreateCategoryInput(
              displayName: name,
              kind: _kind,
              aiDescription: _desc.text.trim().isEmpty
                  ? null
                  : _desc.text.trim(),
            ),
          );
      _name.clear();
      _desc.clear();
      ref.invalidate(categoriesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('已创建分类')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '新增分类',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<CategoryKind>(
              initialValue: _kind,
              decoration: const InputDecoration(
                labelText: '分类类型',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final k in CategoryKind.values)
                  DropdownMenuItem(value: k, child: Text(categoryKindLabel(k))),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _desc,
              decoration: const InputDecoration(
                labelText: 'AI 识别说明（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _name.text.trim().isEmpty || _busy ? null : _save,
                child: Text(_busy ? '创建中…' : '创建分类'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CounterpartyCreateCard extends ConsumerStatefulWidget {
  const _CounterpartyCreateCard({required this.categories});
  final List<CategoryVm> categories;

  @override
  ConsumerState<_CounterpartyCreateCard> createState() =>
      _CounterpartyCreateCardState();
}

class _CounterpartyCreateCardState
    extends ConsumerState<_CounterpartyCreateCard> {
  final _name = TextEditingController();
  final _aliases = TextEditingController();
  String _categoryHintId = '';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _aliases.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(taxonomyRepositoryProvider)
          .createCounterparty(
            CreateCounterpartyInput(
              displayName: name,
              aliases: _splitAliases(_aliases.text),
              categoryHintId: _categoryHintId.isEmpty ? null : _categoryHintId,
            ),
          );
      _name.clear();
      _aliases.clear();
      setState(() => _categoryHintId = '');
      ref.invalidate(counterpartiesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('已创建对手方')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      const DropdownMenuItem(value: '', child: Text('不设默认分类')),
      for (final c in widget.categories)
        DropdownMenuItem(
          value: c.id,
          child: Text('${c.displayName} · ${categoryKindLabel(c.kind)}'),
        ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '新增对手方',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _aliases,
              decoration: const InputDecoration(
                labelText: '别名（可选，用逗号/分号分隔）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: _categoryHintId,
              decoration: const InputDecoration(
                labelText: '默认分类提示（可选）',
                border: OutlineInputBorder(),
              ),
              items: items,
              onChanged: (v) => setState(() => _categoryHintId = v ?? ''),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _name.text.trim().isEmpty || _busy ? null : _save,
                child: Text(_busy ? '创建中…' : '创建对手方'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
