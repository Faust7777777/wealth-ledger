import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/api_endpoint_store.dart';
import '../data/providers.dart';
import '../theme/app_dimens.dart';

typedef RemoteServerHealthProbe = Future<void> Function(String apiBase);

final remoteServerHealthProbeProvider = Provider<RemoteServerHealthProbe>(
  (ref) => _probeRemoteServer,
);

class RemoteServerSetupPage extends ConsumerStatefulWidget {
  const RemoteServerSetupPage({super.key});

  @override
  ConsumerState<RemoteServerSetupPage> createState() =>
      _RemoteServerSetupPageState();
}

class _RemoteServerSetupPageState extends ConsumerState<RemoteServerSetupPage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await configureRemoteServer(ref, _controller.text);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final endpoint = ref.watch(remoteApiEndpointProvider);
    if (endpoint.isLoading && _controller.text.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.cloud_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '连接服务器',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.xl),
                TextField(
                  controller: _controller,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS 地址',
                    hintText: 'https://api.example.com',
                  ),
                  onSubmitted: (_) => _busy ? null : _connect(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: _busy ? null : _connect,
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('连接'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> configureRemoteServer(WidgetRef ref, String input) async {
  final normalized = normalizeHttpsApiOrigin(input);
  await ref.read(remoteServerHealthProbeProvider)(normalized);

  final current = ref.read(effectiveAppEnvironmentProvider).apiBaseUrl;
  if (current != normalized) {
    await ref.read(authTokenStoreProvider).clear();
  }
  await ref.read(remoteApiEndpointProvider.notifier).configure(normalized);
  ref.invalidate(authControllerProvider);
  ref.invalidate(capabilitiesProvider);
}

Future<void> _probeRemoteServer(String normalized) async {
  final response = await http
      .get(Uri.parse('$normalized/v1/health'))
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) {
    throw StateError('服务器返回 HTTP ${response.statusCode}');
  }
  final body = jsonDecode(utf8.decode(response.bodyBytes));
  final healthy =
      body is Map<String, dynamic> &&
      body['ok'] == true &&
      body['data'] is Map &&
      (body['data'] as Map)['status'] == 'ok';
  if (!healthy) throw StateError('服务器健康检查未通过');
}

Future<void> showRemoteServerDialog(BuildContext context, WidgetRef ref) async {
  final initial = ref.read(effectiveAppEnvironmentProvider).apiBaseUrl;
  await showDialog<void>(
    context: context,
    builder: (_) => _RemoteServerDialog(initial: initial),
  );
}

class _RemoteServerDialog extends ConsumerStatefulWidget {
  const _RemoteServerDialog({required this.initial});

  final String initial;

  @override
  ConsumerState<_RemoteServerDialog> createState() =>
      _RemoteServerDialogState();
}

class _RemoteServerDialogState extends ConsumerState<_RemoteServerDialog> {
  late final TextEditingController _controller;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await configureRemoteServer(ref, _controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('服务器地址'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'HTTPS 地址',
              hintText: 'https://api.example.com',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('保存'),
      ),
    ],
  );
}

String _message(Object error) => switch (error) {
  FormatException(:final message) => message,
  _ => error.toString().replaceFirst('Bad state: ', ''),
};
