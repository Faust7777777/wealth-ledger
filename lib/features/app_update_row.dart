// Wealth Ledger — 设置里的「应用更新」紧凑行。
// 只显示状态与动作；长更新说明放可滚动 sheet，不挤压设置页。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import '../data/client_update.dart';
import 'app_update_controller.dart';

class AppUpdateRow extends ConsumerStatefulWidget {
  const AppUpdateRow({super.key});

  @override
  ConsumerState<AppUpdateRow> createState() => _AppUpdateRowState();
}

class _AppUpdateRowState extends ConsumerState<AppUpdateRow> {
  @override
  void initState() {
    super.initState();
    // 打开设置时顺带静默检查一次（受 24 小时节流约束）。
    Future.microtask(
      () => ref.read(appUpdateControllerProvider.notifier).checkSilently(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 非 Android 不提供应用内更新，这一行整体不显示。
    if (ref.watch(clientUpdatePlatformProvider) == null) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(appUpdateControllerProvider);
    final notifier = ref.read(appUpdateControllerProvider.notifier);
    final manifest = state.manifest;
    final status = appUpdateStatusText(state);
    final busy =
        state.phase == AppUpdatePhase.checking ||
        state.phase == AppUpdatePhase.downloading ||
        state.phase == AppUpdatePhase.verifying;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt, size: 20),
              const SizedBox(width: AppSpacing.base),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('应用更新'),
                    Text(
                      state.installed == null
                          ? '当前版本 —'
                          : '当前版本 ${state.installed!.versionName}',
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              if (status.isNotEmpty)
                Flexible(
                  child: Text(
                    status,
                    style: AppType.caption.copyWith(
                      color: state.phase == AppUpdatePhase.failed
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
            ],
          ),
          if (state.phase == AppUpdatePhase.downloading)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: LinearProgressIndicator(value: state.progress),
            ),
          if (manifest != null &&
              state.phase != AppUpdatePhase.downloading &&
              state.phase != AppUpdatePhase.verifying)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: Text(
                _summary(manifest),
                style: AppType.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: AppSpacing.xs,
              children: [
                if (manifest != null && manifest.notes.length > 1)
                  TextButton(
                    onPressed: () => showAppUpdateNotesSheet(context, manifest),
                    child: const Text('更新内容'),
                  ),
                if (state.phase == AppUpdatePhase.downloading)
                  TextButton(
                    onPressed: notifier.cancelDownload,
                    child: const Text('取消'),
                  ),
                if (state.phase == AppUpdatePhase.readyToInstall) ...[
                  TextButton(
                    onPressed: notifier.discardDownload,
                    child: const Text('删除下载'),
                  ),
                  FilledButton(
                    onPressed: notifier.install,
                    child: const Text('安装更新'),
                  ),
                ] else if (state.phase == AppUpdatePhase.needsPermission)
                  FilledButton(
                    onPressed: notifier.install,
                    child: const Text('去授权'),
                  )
                else if (manifest != null)
                  FilledButton(
                    onPressed: busy ? null : notifier.download,
                    child: const Text('下载更新'),
                  )
                else
                  OutlinedButton(
                    onPressed: busy ? null : notifier.check,
                    child: Text(
                      state.phase == AppUpdatePhase.failed ? '重试' : '检查更新',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _summary(ClientUpdateManifestVm manifest) {
    final size = formatUpdateSize(manifest.asset.sizeBytes);
    return manifest.notes.isEmpty ? size : '${manifest.notes.first} · $size';
  }
}

Future<void> showAppUpdateNotesSheet(
  BuildContext context,
  ClientUpdateManifestVm manifest,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) {
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      200.0,
      480.0,
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            Text('更新内容', style: AppType.bodyStrong),
            const SizedBox(height: AppSpacing.sm),
            for (final note in manifest.notes)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text('· $note'),
              ),
          ],
        ),
      ),
    );
  },
);
