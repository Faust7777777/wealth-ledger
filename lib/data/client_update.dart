// Wealth Ledger — 应用内更新（Android P0）。
// 更新接口公开可读：这里不复用 DevApiClient，不带 bearer、不参与 401 刷新，
// 因此更新失败绝不会影响账本登录态。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 更新包信息。
class ClientUpdateAssetVm {
  const ClientUpdateAssetVm({
    required this.url,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
  });
  final String url;
  final String fileName;
  final int sizeBytes;
  final String sha256;
}

/// 服务端 manifest。versionCode 是唯一的升级依据。
class ClientUpdateManifestVm {
  const ClientUpdateManifestVm({
    required this.platform,
    required this.channel,
    required this.versionName,
    required this.versionCode,
    required this.asset,
    this.notes = const [],
    this.mandatory = false,
  });
  final String platform;
  final String channel;
  final String versionName;
  final int versionCode;
  final ClientUpdateAssetVm asset;
  final List<String> notes;
  final bool mandatory;
}

/// 已安装版本（来自平台，不是 pubspec 常量）。
class InstalledVersionVm {
  const InstalledVersionVm({
    required this.versionName,
    required this.versionCode,
  });
  final String versionName;
  final int versionCode;
}

/// manifest 校验失败的原因（都只影响更新流程，不影响账本）。
class ClientUpdateRejected implements Exception {
  ClientUpdateRejected(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// 只接受与当前 API origin 同源的相对 URL。
/// 绝对 URL、协议相对、路径穿越一律拒绝。
Uri resolveUpdateAssetUrl(String apiBaseUrl, String assetUrl) {
  final raw = assetUrl.trim();
  if (raw.isEmpty || !raw.startsWith('/') || raw.startsWith('//')) {
    throw ClientUpdateRejected('更新包地址无效');
  }
  if (Uri.tryParse(raw)?.hasScheme ?? false) {
    throw ClientUpdateRejected('更新包地址无效');
  }
  final segments = raw.split('/');
  if (segments.contains('..') || segments.contains('.')) {
    throw ClientUpdateRejected('更新包地址无效');
  }
  final base = Uri.parse(apiBaseUrl);
  return base.replace(path: raw, query: null, fragment: null);
}

ClientUpdateManifestVm parseClientUpdateManifest(Map<String, dynamic> j) {
  final asset = (j['asset'] as Map).cast<String, dynamic>();
  return ClientUpdateManifestVm(
    platform: '${j['platform']}',
    channel: '${j['channel']}',
    versionName: '${j['versionName']}',
    versionCode: (j['versionCode'] as num).toInt(),
    mandatory: j['mandatory'] == true,
    notes: [for (final n in (j['notes'] as List? ?? const [])) '$n'],
    asset: ClientUpdateAssetVm(
      url: '${asset['url']}',
      fileName: '${asset['fileName']}',
      sizeBytes: (asset['sizeBytes'] as num).toInt(),
      sha256: '${asset['sha256']}'.toLowerCase(),
    ),
  );
}

/// 下载进度（0..1）。total 未知时为 null。
typedef UpdateProgress = void Function(int received, int? total);

class ClientUpdateService {
  ClientUpdateService({
    required this.apiBaseUrl,
    required this.platform,
    required this.cacheDirProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiBaseUrl;
  final String platform;
  final Future<String> Function() cacheDirProvider;
  final http.Client _client;
  static const String channel = 'stable';

  /// 检查最新版本。404 表示还没有发布，返回 null。
  Future<ClientUpdateManifestVm?> fetchLatest() async {
    final uri = Uri.parse(
      '$apiBaseUrl/v1/client-updates/$platform/$channel/latest',
    );
    final res = await _client.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw ClientUpdateRejected('检查更新失败，请稍后重试');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final data = decoded is Map && decoded['data'] is Map
        ? (decoded['data'] as Map).cast<String, dynamic>()
        : (decoded as Map).cast<String, dynamic>();
    final manifest = parseClientUpdateManifest(data);
    // 平台/channel 不一致的 manifest 一律拒绝。
    if (manifest.platform != platform || manifest.channel != channel) {
      throw ClientUpdateRejected('更新信息与当前客户端不匹配');
    }
    return manifest;
  }

  /// 流式下载到 App 私有 cache，并在写入过程中增量计算 SHA-256。
  /// 大小或摘要不符会删除临时文件并抛错；取消同样删除。
  Future<File> download(
    ClientUpdateManifestVm manifest, {
    UpdateProgress? onProgress,
    Future<void>? cancel,
  }) async {
    final uri = resolveUpdateAssetUrl(apiBaseUrl, manifest.asset.url);
    final dir = Directory(await cacheDirProvider());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      '${_safeFileName(manifest.asset.fileName)}',
    );
    if (file.existsSync()) file.deleteSync();

    final response = await _client.send(http.Request('GET', uri));
    if (response.statusCode != 200) {
      throw ClientUpdateRejected('下载失败，请重试');
    }
    final sink = file.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var received = 0;
    var cancelled = false;
    StreamSubscription<List<int>>? sub;
    final done = Completer<void>();

    unawaited(
      cancel?.then((_) {
        cancelled = true;
        sub?.cancel();
        if (!done.isCompleted) done.complete();
      }),
    );

    sub = response.stream.listen(
      (chunk) {
        received += chunk.length;
        sink.add(chunk);
        hasher.add(chunk);
        onProgress?.call(received, response.contentLength);
      },
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      await sink.close();
    }

    if (cancelled) {
      if (file.existsSync()) file.deleteSync();
      throw ClientUpdateRejected('已取消下载');
    }

    hasher.close();
    final actual = digest.value?.toString().toLowerCase() ?? '';
    final actualSize = file.existsSync() ? file.lengthSync() : 0;
    if (actualSize != manifest.asset.sizeBytes ||
        actual != manifest.asset.sha256) {
      if (file.existsSync()) file.deleteSync();
      throw ClientUpdateRejected('更新包校验未通过，请重试');
    }
    return file;
  }

  /// 清掉 cache 里除当前包外的旧更新文件。
  Future<void> cleanCache({String? keepFileName}) async {
    final dir = Directory(await cacheDirProvider());
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (keepFileName != null && name == keepFileName) continue;
      try {
        entity.deleteSync();
      } catch (_) {
        // 删不掉的旧文件不阻断更新流程。
      }
    }
  }

  /// 文件名只保留安全字符，杜绝目录穿越。
  static String _safeFileName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'update.apk' : cleaned;
  }
}

/// 增量摘要的接收端（避免为一个 sink 再引一个包）。
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// 有没有可安装的新版本：只比较整数 versionCode。
bool hasNewerVersion(ClientUpdateManifestVm manifest, int installedCode) =>
    manifest.versionCode > installedCode;
