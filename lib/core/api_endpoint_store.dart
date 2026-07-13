import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

String normalizeHttpsApiOrigin(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请输入 HTTPS 服务器地址，例如 https://api.example.com');
  }
  return uri.hasPort
      ? 'https://${uri.host}:${uri.port}'
      : 'https://${uri.host}';
}

abstract interface class ApiEndpointStore {
  Future<String?> read();
  Future<void> write(String apiBase);
  Future<void> clear();
}

class PlatformApiEndpointStore implements ApiEndpointStore {
  PlatformApiEndpointStore({File? file})
    : _file = file ?? _defaultEndpointFile();

  static const _androidChannel = MethodChannel('finwealth.app_config');

  final File _file;
  String? _memoryValue;

  @override
  Future<String?> read() async {
    String? raw;
    if (Platform.isAndroid) {
      raw = await _androidChannel.invokeMethod<String>('readApiBase');
    } else if (Platform.isWindows) {
      if (!await _file.exists()) return null;
      raw = await _file.readAsString();
    } else {
      return _memoryValue;
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['version'] != 1) return null;
      return normalizeHttpsApiOrigin(decoded['apiBase']?.toString() ?? '');
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  Future<void> write(String apiBase) async {
    final normalized = normalizeHttpsApiOrigin(apiBase);
    final raw = jsonEncode({'version': 1, 'apiBase': normalized});
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('writeApiBase', {'value': raw});
      return;
    }
    if (Platform.isWindows) {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(raw, flush: true);
      return;
    }
    _memoryValue = raw;
  }

  @override
  Future<void> clear() async {
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>('clearApiBase');
      return;
    }
    if (Platform.isWindows) {
      if (await _file.exists()) await _file.delete();
      return;
    }
    _memoryValue = null;
  }
}

class MemoryApiEndpointStore implements ApiEndpointStore {
  MemoryApiEndpointStore([String? initial]) : _value = initial;

  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String apiBase) async {
    _value = normalizeHttpsApiOrigin(apiBase);
  }

  @override
  Future<void> clear() async => _value = null;
}

File _defaultEndpointFile() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    return File('.finwealth_server.json');
  }
  return File('$appData\\Finwealth\\server.json');
}
