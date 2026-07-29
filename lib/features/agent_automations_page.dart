// Wealth Ledger — Agent 自动任务设置：四类任务各一行。
// 调度与执行都在服务端；这里只有开关、频率、下次时间、上次结果和「立即运行」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_mock_repositories.dart'
    show ApiConflictException, ApiValidationException;
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'agent_notifications.dart'
    show agentAutomationKindLabel, formatLocalDateTime;

/// 频率预设；自定义走 1–720 小时输入。
const List<int> kAgentIntervalPresets = [1, 6, 24, 168];

String agentIntervalLabel(int hours) => switch (hours) {
  1 => '每小时',
  6 => '每 6 小时',
  24 => '每天',
  168 => '每周',
  _ => '每 $hours 小时',
};

/// 1–720 之外不接受。
String? agentIntervalError(String raw) {
  final value = int.tryParse(raw.trim());
  if (value == null) return '请填写 1–720 之间的小时数';
  if (value < 1 || value > 720) return '请填写 1–720 之间的小时数';
  return null;
}

class AgentAutomationsPage extends ConsumerWidget {
  const AgentAutomationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(agentAutomationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Agent 自动任务')),
      body: ContentMaxWidth(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: '$e',
            onRetry: () => ref.invalidate(agentAutomationsProvider),
          ),
          data: (automations) => ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [
              for (final kind in AgentAutomationKind.values)
                AgentAutomationRow(
                  kind: kind,
                  automation: automations
                      .where((a) => a.kind == kind)
                      .cast<AgentAutomationVm?>()
                      .firstWhere((a) => true, orElse: () => null),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AgentAutomationRow extends ConsumerStatefulWidget {
  const AgentAutomationRow({
    super.key,
    required this.kind,
    required this.automation,
  });
  final AgentAutomationKind kind;
  final AgentAutomationVm? automation;

  @override
  ConsumerState<AgentAutomationRow> createState() => _AgentAutomationRowState();
}

class _AgentAutomationRowState extends ConsumerState<AgentAutomationRow> {
  bool _busy = false;
  String? _error;

  Future<void> _guard(Future<void> Function() action) async {
    // 同一次点击只发一个请求。
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      ref.invalidate(agentAutomationsProvider);
    } on ApiConflictException {
      ref.invalidate(agentAutomationsProvider);
      if (mounted) setState(() => _error = '这项任务正在运行，请稍后再试');
    } on ApiValidationException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (_) {
      if (mounted) setState(() => _error = '操作失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool enabled) async {
    final current = widget.automation;
    await _guard(() async {
      final repo = ref.read(agentRepositoryProvider);
      if (current == null) {
        await repo.createAutomation(kind: widget.kind, intervalHours: 24);
      } else {
        await repo.updateAutomation(current.id, enabled: enabled);
      }
    });
  }

  Future<void> _pickInterval() async {
    final current = widget.automation;
    if (current == null) return;
    final hours = await showDialog<int>(
      context: context,
      builder: (_) => _IntervalDialog(initial: current.intervalHours),
    );
    if (hours == null) return;
    await _guard(
      () => ref
          .read(agentRepositoryProvider)
          .updateAutomation(current.id, intervalHours: hours),
    );
  }

  Future<void> _pickNextRun() async {
    final current = widget.automation;
    if (current == null) return;
    final base =
        DateTime.tryParse(current.nextRunAt)?.toLocal() ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    final next = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await _guard(
      () => ref
          .read(agentRepositoryProvider)
          .updateAutomation(
            current.id,
            nextRunAt: next.toUtc().toIso8601String(),
          ),
    );
  }

  Future<void> _runNow() async {
    final current = widget.automation;
    if (current == null) return;
    await _guard(
      () => ref.read(agentRepositoryProvider).runAutomation(current.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final automation = widget.automation;
    final enabled = automation?.enabled ?? false;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    agentAutomationKindLabel(widget.kind),
                    style: AppType.bodyStrong,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(value: enabled, onChanged: _busy ? null : _toggle),
              ],
            ),
            if (automation != null) ...[
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xxs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _pickInterval,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      textStyle: AppType.caption,
                    ),
                    child: Text(agentIntervalLabel(automation.intervalHours)),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _pickNextRun,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      textStyle: AppType.caption,
                    ),
                    child: Text(
                      '下次 ${formatLocalDateTime(automation.nextRunAt)}',
                    ),
                  ),
                ],
              ),
              Text(_lastRunText(automation), style: AppType.caption),
            ],
            if (_error != null)
              Text(
                _error!,
                style: AppType.caption.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            if (automation != null)
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: _busy ? null : _runNow,
                  child: Text(_busy ? '运行中…' : '立即运行'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 失败只说"上次未完成"与重试时间，不外露内部错误码。
  String _lastRunText(AgentAutomationVm automation) {
    if (automation.lastRunFailed) {
      return '上次未完成 · 将在 ${formatLocalDateTime(automation.nextRunAt)} 重试';
    }
    if (automation.lastRunAt == null) return '尚未运行';
    return '上次完成 ${formatLocalDateTime(automation.lastRunAt!)}';
  }
}

class _IntervalDialog extends StatefulWidget {
  const _IntervalDialog({required this.initial});
  final int initial;

  @override
  State<_IntervalDialog> createState() => _IntervalDialogState();
}

class _IntervalDialogState extends State<_IntervalDialog> {
  late final _custom = TextEditingController(text: '${widget.initial}');

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = agentIntervalError(_custom.text);
    return AlertDialog(
      title: const Text('运行频率'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                for (final hours in kAgentIntervalPresets)
                  ChoiceChip(
                    label: Text(agentIntervalLabel(hours)),
                    selected: int.tryParse(_custom.text) == hours,
                    onSelected: (_) => setState(() => _custom.text = '$hours'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _custom,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '自定义间隔',
                suffixText: '小时',
                border: const OutlineInputBorder(),
                errorText: _custom.text.isEmpty ? null : error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: error != null
              ? null
              : () => Navigator.pop(context, int.parse(_custom.text.trim())),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
