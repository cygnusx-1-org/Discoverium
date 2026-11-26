import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/installer.dart';
import 'package:obtainium/installers/root_installer.dart';
import 'package:obtainium/providers/apps_provider.dart';

/// #69: a download is kept when its install fails or is cancelled, so the
/// retry does not fetch it again. It is only thrown away once it is installed,
/// shown to be unusable, or left unused for a week.
void main() {
  group('InstallResult.fileIsInvalid', () {
    test('is set by the status that rejects the APK itself', () {
      expect(InstallResult.fromPlatformCode(4).fileIsInvalid, isTrue);
    });

    test('is not set by failures that leave a good file behind', () {
      // failure, blocked, conflict (signature), storage, incompatible
      for (final code in [1, 2, 5, 6, 7]) {
        final result = InstallResult.fromPlatformCode(code);
        expect(result.isError, isTrue, reason: 'code $code');
        expect(result.fileIsInvalid, isFalse, reason: 'code $code');
      }
    });

    test('is not set by a success or a cancellation', () {
      expect(InstallResult.success().fileIsInvalid, isFalse);
      expect(InstallResult.cancelled().fileIsInvalid, isFalse);
      expect(InstallResult.fromPlatformCode(3).fileIsInvalid, isFalse);
      expect(InstallResult.fromPlatformCode(null).fileIsInvalid, isFalse);
    });

    test('can be stated by an installer whose code is not a status', () {
      expect(InstallResult.error(1, fileIsInvalid: true).fileIsInvalid, isTrue);
      expect(
        InstallResult.error(4, fileIsInvalid: false).fileIsInvalid,
        isFalse,
      );
    });
  });

  group('pmOutputSaysApkIsInvalid', () {
    test('recognises an APK pm could not parse or verify', () {
      expect(
        pmOutputSaysApkIsInvalid(
          'Failure [INSTALL_PARSE_FAILED_NOT_APK: Failed to parse /data/local/tmp/obt0.apk]',
        ),
        isTrue,
      );
      expect(
        pmOutputSaysApkIsInvalid(
          'Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES: no signatures]',
        ),
        isTrue,
      );
      expect(
        pmOutputSaysApkIsInvalid('Failure [INSTALL_FAILED_INVALID_APK]'),
        isTrue,
      );
    });

    test('recognises a downgrade', () {
      expect(
        pmOutputSaysApkIsInvalid(
          'Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected]',
        ),
        isTrue,
      );
    });

    test('leaves failures that say nothing against the file', () {
      expect(
        pmOutputSaysApkIsInvalid(
          'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]',
        ),
        isFalse,
      );
      expect(
        pmOutputSaysApkIsInvalid(
          'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]',
        ),
        isFalse,
      );
      expect(pmOutputSaysApkIsInvalid(''), isFalse);
    });
  });

  test('SigningCertMismatchError says whether it can be overridden', () {
    expect(
      SigningCertMismatchError(
        hardBlock: true,
        expected: {'a'},
        actual: {'b'},
      ).hardBlock,
      isTrue,
    );
    expect(
      SigningCertMismatchError(
        hardBlock: false,
        expected: {'a'},
        actual: {'b'},
      ).hardBlock,
      isFalse,
    );
  });

  test('DownloadedDir lists the base and its splits as cached files', () {
    final base = File('/cache/com.example-1.apk');
    final split = File('/cache/com.example-1-1.apk');
    final extracted = Directory('/cache/com.example-1.apk-dir');
    expect(
      DownloadedDir(
        'com.example',
        base,
        extracted,
        DownloadedDirType.xapk,
      ).cachedFiles.map((f) => f.path),
      [base.path],
    );
    expect(
      DownloadedDir(
        'com.example',
        base,
        extracted,
        DownloadedDirType.splitApks,
        splits: [split],
      ).cachedFiles.map((f) => f.path),
      [base.path, split.path],
    );
  });

  group('isDownloadCacheEntryName', () {
    test('matches the names downloads are saved under', () {
      for (final name in [
        'com.example.app-312293186.apk',
        'com.example.app-312293186.xapk',
        'com.example.app-312293186.apk.part',
        'com.example.app-312293186.xapk-dir',
        'com.example.app-312293186-1.apk',
        'com.example.app-312293186.xapk-2.apk',
        'com.example.app-312293186 (1).apk',
        'com.example.app-312293186',
        // A placeholder id, used until the real package name is known.
        '1700000000000-42.apk',
      ]) {
        expect(isDownloadCacheEntryName(name), isTrue, reason: name);
      }
    });

    test('does not match what else lives in the cache directory', () {
      for (final name in ['icons', 'com.example.app.png', 'notes.txt', '']) {
        expect(isDownloadCacheEntryName(name), isFalse, reason: name);
      }
    });
  });

  group('sweepStaleDownloads', () {
    late Directory dir;
    // A directory's modification time cannot be set, so the cutoff sits in
    // the future and the entries meant to survive are dated beyond it.
    final cutoff = DateTime.now().add(const Duration(hours: 1));
    final fresh = cutoff.add(const Duration(hours: 1));

    setUp(() {
      dir = Directory.systemTemp.createTempSync('download_cache_test');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    File file(String name, {bool isFresh = false}) {
      final f = File('${dir.path}/$name')..writeAsStringSync('x');
      if (isFresh) f.setLastModifiedSync(fresh);
      return f;
    }

    test(
      'removes stale downloads, partial downloads and bundle dirs',
      () async {
        final apk = file('com.example-1.apk');
        final part = file('com.example-2.apk.part');
        final bundleDir = Directory('${dir.path}/com.example-3.xapk-dir')
          ..createSync();
        File('${bundleDir.path}/base.apk').writeAsStringSync('x');

        await sweepStaleDownloads(dir, cutoff);

        expect(apk.existsSync(), isFalse);
        expect(part.existsSync(), isFalse);
        expect(bundleDir.existsSync(), isFalse);
      },
    );

    test('keeps a download that is not stale yet', () async {
      final apk = file('com.example-1.apk', isFresh: true);

      await sweepStaleDownloads(dir, cutoff);

      expect(apk.existsSync(), isTrue);
    });

    test('keeps everything that is not a download', () async {
      final icons = Directory('${dir.path}/icons')..createSync();
      final icon = File('${icons.path}/com.example.png')
        ..writeAsStringSync('x');
      final other = file('notes.txt');
      // Named like a download, but not a directory downloads create.
      final otherDir = Directory('${dir.path}/com.example-4')..createSync();

      await sweepStaleDownloads(dir, cutoff);

      expect(icon.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
      expect(otherDir.existsSync(), isTrue);
    });

    test('removes nothing while a download is under way', () async {
      final apk = file('com.example-1.apk');

      await sweepStaleDownloads(dir, cutoff, isBusy: () => true);

      expect(apk.existsSync(), isTrue);
    });
  });
}
