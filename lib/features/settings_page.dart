// Wealth Ledger — 设置（主题 / 数据源状态 / 关于）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../data/providers.dart';
import '../theme/app_dimens.dart';

String _modeLabel(DataSourceMode m) => switch (m) {
      DataSourceMode.realLocal => '真实本地账本（默认；当前为空账本）',
      DataSourceMode.debugFixture => 'DEMO 演示数据（隔离；不写真实账本、不同步）',
      DataSourceMode.localServer => '本地 Rust 服务（dev/local server；可连 --ledger-path 真实账本）',
      DataSourceMode.apiRemote => '远端 API（未接入）',
    };

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final env = ref.watch(appEnvironmentProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.base),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text('主题', style: Theme.of(context).textTheme.titleMedium),
          ),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
            ],
            selected: {mode},
            onSelectionChanged: (s) =>
                ref.read(themeModeProvider.notifier).set(s.first),
          ),
          const Divider(height: AppSpacing.xxl),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('数据源'),
            subtitle: Text(_modeLabel(env.dataSourceMode)),
            trailing: env.devBannerLabel == null ? null : Chip(label: Text(env.devBannerLabel!)),
          ),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('关于'),
            subtitle: Text(
              'Wealth Ledger · 前端骨架\n'
              '本地账本 / 同步 / 行情 / AI 由后端线实现（开发中）',
            ),
          ),
        ],
      ),
    );
  }
}
