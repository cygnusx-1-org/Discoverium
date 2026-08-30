import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';

/// The conflict from #2: an APK downloaded by another app already occupies the
/// name Discoverium wants to use in the shared Download folder, so the finished
/// download is saved under a numbered variant instead of being discarded.
void main() {
  group('pathWithNumberSuffix', () {
    test('inserts the number before the extension', () {
      expect(
        pathWithNumberSuffix(
          '/storage/emulated/0/Download/continuum-arm64-v8a-7.5.1.1.apk',
          1,
        ),
        '/storage/emulated/0/Download/continuum-arm64-v8a-7.5.1.1 (1).apk',
      );
    });

    test('uses the last dot, so a double extension keeps its tail', () {
      expect(
        pathWithNumberSuffix('/dir/archive.tar.gz', 2),
        '/dir/archive.tar (2).gz',
      );
    });

    test('appends to a name with no extension', () {
      expect(pathWithNumberSuffix('/dir/release', 3), '/dir/release (3)');
    });

    test('treats a leading dot as a hidden file, not an extension', () {
      expect(pathWithNumberSuffix('/dir/.hidden', 1), '/dir/.hidden (1)');
    });

    test('handles a bare file name with no directory', () {
      expect(pathWithNumberSuffix('app.apk', 4), 'app (4).apk');
    });

    test('leaves a dot in a parent directory alone', () {
      expect(pathWithNumberSuffix('/dir.v2/app', 1), '/dir.v2/app (1)');
    });

    test('produces a name that is free when the original is taken', () async {
      final dir = await Directory.systemTemp.createTemp('dl_name_test');
      addTearDown(() => dir.delete(recursive: true));
      final taken = File('${dir.path}/app.apk')..writeAsStringSync('a');
      final free = File(pathWithNumberSuffix(taken.path, 1));
      expect(free.existsSync(), isFalse);
      expect(free.parent.path, taken.parent.path);
    });
  });
}
