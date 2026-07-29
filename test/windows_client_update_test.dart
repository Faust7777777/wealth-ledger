import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:finwealth/data/client_update.dart';
import 'package:finwealth/features/app_update_controller.dart';

void main() {
  test('Windows manifest only accepts a safe ZIP name', () {
    Map<String, dynamic> manifest(String fileName) => {
      'platform': 'windows',
      'channel': 'stable',
      'versionName': '1.2.0',
      'versionCode': 4,
      'asset': {
        'url': '/v1/client-updates/windows/stable/assets/$fileName',
        'fileName': fileName,
        'sizeBytes': 4,
        'sha256': List.filled(64, 'a').join(),
      },
    };

    expect(
      parseClientUpdateManifest(
        manifest('finwealth-1.2.0+4-windows.zip'),
      ).platform,
      'windows',
    );
    for (final bad in ['../evil.zip', '.hidden.zip', 'evil.exe', 'a b.zip']) {
      expect(
        () => parseClientUpdateManifest(manifest(bad)),
        throwsA(isA<ClientUpdateRejected>()),
        reason: bad,
      );
    }
  });

  test('packaged Windows version is read from build config', () {
    final parsed = parsePackagedClientVersion(
      jsonEncode({'clientVersion': '1.2.0+4'}),
    );
    expect(parsed.versionName, '1.2.0');
    expect(parsed.versionCode, 4);
    expect(
      () => parsePackagedClientVersion(jsonEncode({'clientVersion': '1.2'})),
      throwsFormatException,
    );
  });

  test(
    'Windows platform launches helper with argument array then exits',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'finwealth-win-platform-',
      );
      addTearDown(() => root.delete(recursive: true));
      final install = Directory('${root.path}\\Finwealth')..createSync();
      final local = Directory('${root.path}\\Local')..createSync();
      final executable = File('${install.path}\\finwealth.exe')
        ..writeAsBytesSync([1]);
      File(
        '${install.path}\\finwealth.build-config.json',
      ).writeAsStringSync(jsonEncode({'clientVersion': '1.2.0+4'}));
      File(
        '${install.path}\\Finwealth-Updater.ps1',
      ).writeAsStringSync('exit 0');
      final cache = Directory('${local.path}\\Finwealth\\updates')
        ..createSync(recursive: true);
      final archive = File('${cache.path}\\update.zip')
        ..writeAsBytesSync([1, 2]);

      String? launchedExecutable;
      List<String>? launchedArguments;
      String? launchedWorkingDirectory;
      ProcessStartMode? launchedMode;
      var exitCode = -1;
      final platform = WindowsClientUpdatePlatform(
        resolvedExecutable: executable.path,
        environment: {'LOCALAPPDATA': local.path},
        processStarter: (program, arguments, workingDirectory, mode) async {
          launchedExecutable = program;
          launchedArguments = arguments;
          launchedWorkingDirectory = workingDirectory;
          launchedMode = mode;
          return Process.start('cmd.exe', ['/c', 'exit', '0']);
        },
        exitApplication: (value) => exitCode = value,
      );

      expect((await platform.installedVersion()).versionCode, 4);
      final digest = List.filled(64, 'b').join();
      await platform.openVerifiedInstaller(archive.path, digest);
      expect(launchedExecutable, 'powershell.exe');
      expect(
        launchedArguments,
        containsAllInOrder(['-File', isA<String>(), '-Archive']),
      );
      expect(launchedArguments, contains(archive.absolute.path));
      expect(launchedArguments, contains(install.absolute.path));
      expect(launchedArguments, contains(digest));
      expect(launchedWorkingDirectory, cache.absolute.path);
      expect(launchedMode, ProcessStartMode.detached);
      expect(exitCode, 0);
    },
  );
}
