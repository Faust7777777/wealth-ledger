// Wealth Ledger — persistent auth token store for desktop/local development.
//
// Windows uses DPAPI (current user) through pure Dart FFI, avoiding Flutter
// secure-storage plugins that require extra Visual Studio ATL components.
// Non-Windows platforms currently use in-memory tokens: no plaintext persistence,
// but also no cross-restart "instant login" until Android secure storage is wired.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'auth_store.dart';

class PlatformAuthTokenStore implements AuthTokenStore {
  PlatformAuthTokenStore({File? file}) : _file = file ?? _defaultTokenFile();

  final File _file;
  final AuthTokenStore _memoryFallback = MemoryAuthTokenStore();

  @override
  Future<StoredAuthSession?> read() async {
    if (!Platform.isWindows) {
      return _memoryFallback.read();
    }
    if (!await _file.exists()) return null;
    final encrypted = await _file.readAsBytes();
    if (encrypted.isEmpty) return null;
    final raw = utf8.decode(_dpapiUnprotect(encrypted));
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final session = StoredAuthSession(
      accessToken: (json['accessToken'] ?? '').toString(),
      refreshToken: (json['refreshToken'] ?? '').toString(),
      expiresAt: (json['expiresAt'] ?? '').toString(),
      deviceId: (json['deviceId'] ?? '').toString(),
    );
    return session.isComplete ? session : null;
  }

  @override
  Future<String?> readAccessToken() async => (await read())?.accessToken;

  @override
  Future<void> write(StoredAuthSession session) async {
    if (!Platform.isWindows) {
      await _memoryFallback.write(session);
      return;
    }
    await _file.parent.create(recursive: true);
    final raw = utf8.encode(
      jsonEncode({
        'accessToken': session.accessToken,
        'refreshToken': session.refreshToken,
        'expiresAt': session.expiresAt,
        'deviceId': session.deviceId,
      }),
    );
    await _file.writeAsBytes(
      _dpapiProtect(Uint8List.fromList(raw)),
      flush: true,
    );
  }

  @override
  Future<void> clear() async {
    if (!Platform.isWindows) {
      await _memoryFallback.clear();
      return;
    }
    if (await _file.exists()) {
      await _file.delete();
    }
  }
}

File _defaultTokenFile() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    return File('.finwealth_auth_tokens.dpapi');
  }
  return File('$appData\\Finwealth\\auth_tokens.dpapi');
}

Uint8List _dpapiProtect(Uint8List data) {
  final inBlob = calloc<CRYPT_INTEGER_BLOB>();
  final outBlob = calloc<CRYPT_INTEGER_BLOB>();
  final dataPtr = calloc<Uint8>(data.length);
  try {
    dataPtr.asTypedList(data.length).setAll(0, data);
    inBlob.ref
      ..cbData = data.length
      ..pbData = dataPtr;

    final result = CryptProtectData(inBlob, null, nullptr, nullptr, 0, outBlob);
    if (!result.value) {
      throw StateError('DPAPI encrypt failed: ${result.error}');
    }
    return Uint8List.fromList(
      outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
    );
  } finally {
    _zero(dataPtr, data.length);
    calloc.free(dataPtr);
    if (!outBlob.ref.pbData.isNull) {
      LocalFree(HLOCAL(outBlob.ref.pbData));
    }
    calloc.free(inBlob);
    calloc.free(outBlob);
  }
}

Uint8List _dpapiUnprotect(Uint8List encrypted) {
  final inBlob = calloc<CRYPT_INTEGER_BLOB>();
  final outBlob = calloc<CRYPT_INTEGER_BLOB>();
  final dataPtr = calloc<Uint8>(encrypted.length);
  try {
    dataPtr.asTypedList(encrypted.length).setAll(0, encrypted);
    inBlob.ref
      ..cbData = encrypted.length
      ..pbData = dataPtr;

    final result = CryptUnprotectData(
      inBlob,
      nullptr,
      nullptr,
      nullptr,
      0,
      outBlob,
    );
    if (!result.value) {
      throw StateError('DPAPI decrypt failed: ${result.error}');
    }
    return Uint8List.fromList(
      outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
    );
  } finally {
    _zero(dataPtr, encrypted.length);
    calloc.free(dataPtr);
    if (!outBlob.ref.pbData.isNull) {
      LocalFree(HLOCAL(outBlob.ref.pbData));
    }
    calloc.free(inBlob);
    calloc.free(outBlob);
  }
}

void _zero(Pointer<Uint8> ptr, int length) {
  final bytes = ptr.asTypedList(length);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = 0;
  }
}
