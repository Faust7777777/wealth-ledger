// Wealth Ledger — 设置（主题 / 数据源状态 / 关于）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/env.dart';
import '../data/auth_store.dart';
import '../data/providers.dart';
import '../theme/app_dimens.dart';

String _modeLabel(DataSourceMode m) => switch (m) {
  DataSourceMode.realLocal => '真实本地账本（默认；当前为空账本）',
  DataSourceMode.debugFixture => 'DEMO 演示数据（隔离；不写真实账本、不同步）',
  DataSourceMode.localServer =>
    '本地 Rust 服务（dev/local server；可连 --ledger-path 真实账本）',
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
            trailing: env.devBannerLabel == null
                ? null
                : Chip(label: Text(env.devBannerLabel!)),
          ),
          if (env.isLocalServer) ...[
            const Divider(),
            const _LocalServerAuthSection(),
          ],
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.label_outline),
            title: const Text('分类与对手方'),
            subtitle: const Text('维护 AI 可读取的分类词表、商户/平台/发薪方等对手方'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/taxonomy'),
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

class _LocalServerAuthSection extends ConsumerStatefulWidget {
  const _LocalServerAuthSection();

  @override
  ConsumerState<_LocalServerAuthSection> createState() =>
      _LocalServerAuthSectionState();
}

class _LocalServerAuthSectionState
    extends ConsumerState<_LocalServerAuthSection> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _deviceName = TextEditingController(text: _defaultDeviceName());
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final session = auth.asData?.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text('本地服务登录', style: Theme.of(context).textTheme.titleMedium),
        ),
        auth.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => _AuthError(error: error),
          data: (_) => const SizedBox.shrink(),
        ),
        if (session == null) _loginForm(context) else _sessionPanel(session),
      ],
    );
  }

  Widget _loginForm(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: _username,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: '用户名'),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _password,
          obscureText: true,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: '密码'),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _deviceName,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: '设备名'),
        ),
        const SizedBox(height: AppSpacing.base),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _login,
            icon: const Icon(Icons.login),
            label: const Text('登录并保存 token'),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '不保存密码。Windows 会用 DPAPI 持久保存 token；其他平台本轮仅会话内保存。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _sessionPanel(StoredAuthSession session) {
    final devices = ref.watch(authDevicesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('已登录'),
          subtitle: Text(
            '设备 ${session.deviceId}\naccess 过期：${session.expiresAt}',
          ),
          isThreeLine: true,
        ),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.sync),
              label: const Text('刷新登录态'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _logout,
              icon: const Icon(Icons.logout),
              label: const Text('退出本机'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.base),
        devices.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text('设备列表读取失败：$error'),
          data: (items) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已授权设备', style: Theme.of(context).textTheme.titleSmall),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text('暂无设备记录'),
                )
              else
                for (final device in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.devices_other_outlined),
                    title: Text(device.name),
                    subtitle: Text(
                      '创建：${device.createdAt}'
                      '${device.lastSeenAt == null ? '' : '\n最近：${device.lastSeenAt}'}',
                    ),
                    isThreeLine: device.lastSeenAt != null,
                    trailing: device.id == session.deviceId
                        ? const Chip(label: Text('本机'))
                        : IconButton(
                            tooltip: '撤销设备',
                            icon: const Icon(Icons.block),
                            onPressed: _busy ? null : () => _revoke(device.id),
                          ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _login() async {
    final username = _username.text.trim();
    final password = _password.text;
    final deviceName = _deviceName.text.trim();
    if (username.isEmpty || password.isEmpty || deviceName.isEmpty) {
      _show('用户名、密码、设备名都不能为空');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(
            username: username,
            password: password,
            deviceName: deviceName,
          );
      _password.clear();
      _show('已登录');
    } catch (error) {
      _show('登录失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).refresh();
      _show('登录态已刷新');
    } catch (error) {
      _show('刷新失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).logout();
      _show('已退出本机');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(String deviceId) async {
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).revokeDevice(deviceId);
      _show('已撤销设备');
    } catch (error) {
      _show('撤销失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Text(
      '登录状态读取失败：$error',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

String _defaultDeviceName() {
  final platform = defaultTargetPlatform.name;
  return '${platform[0].toUpperCase()}${platform.substring(1)} device';
}
