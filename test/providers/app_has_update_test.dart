import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/source_provider.dart';

App _app({
  String? installed,
  int? installedCode,
  String? latest,
  int? latestCode,
  String release = '1450',
  bool trackOnly = false,
}) => App(
  id: 'fork.risin42.nagramx',
  url: 'https://github.com/Keeperorowner/NagramXF',
  author: 'Keeperorowner',
  name: 'Nagram XF',
  installedVersion: installed,
  installedVersionCode: installedCode,
  // The release's tag, which says nothing about the APK (#59).
  latestVersion: release,
  latestVersionCode: latestCode,
  latestVersionName: latest,
  preferredApkIndex: 0,
  additionalSettings: {'trackOnly': trackOnly},
);

bool _newer((int, String) installed, (int, String) latest) => apkVersionIsNewer(
  installedCode: installed.$1,
  installedName: installed.$2,
  latestCode: latest.$1,
  latestName: latest.$2,
);

void main() {
  group('apkVersionIsNewer', () {
    test('a higher versionCode is newer, whatever the versionName says', () {
      expect(_newer((1249, '12.9.2-bd9adbc'), (1250, '12.10.1-dec46b0')), true);
      expect(_newer((5, '2.0'), (6, '1.0')), true);
    });

    test('a lower versionCode is not newer, whatever the versionName says', () {
      expect(
        _newer((1250, '12.10.1-dec46b0'), (1249, '12.9.2-bd9adbc')),
        false,
      );
      expect(_newer((6, '1.0'), (5, '2.0')), false);
    });

    test('an equal versionCode leaves it to the versionName', () {
      // continuum 8.3.0.4 and 8.3.1.1 both ship versionCode 228.
      expect(_newer((228, '8.3.0.4'), (228, '8.3.1.1')), true);
      expect(_newer((228, '8.3.1.1'), (228, '8.3.0.4')), false);
    });

    test('the same versionCode and versionName is not newer', () {
      expect(
        _newer((1250, '12.10.1-dec46b0'), (1250, '12.10.1-dec46b0')),
        false,
      );
    });

    test('a different git hash on the same version is not newer', () {
      expect(
        _newer((1250, '12.10.1-dec46b0'), (1250, '12.10.1-bd9adbc')),
        false,
      );
      expect(_newer((1250, '12.10.1'), (1250, '12.10.1-dec46b0')), false);
    });

    test('versionNames that cannot be ordered are not newer', () {
      expect(_newer((3, 'alpha'), (3, 'beta')), false);
    });
  });

  group('withoutGitHash', () {
    test('drops a dash and seven lowercase hex digits at the end', () {
      expect(withoutGitHash('12.10.1-dec46b0'), '12.10.1');
      expect(withoutGitHash('12.9.2-bd9adbc'), '12.9.2');
      expect(withoutGitHash('1.0-1234567'), '1.0');
    });

    test('keeps every other suffix', () {
      for (final version in [
        '1.0-abcdefg', // not hex
        '1.0-dec46b01', // eight digits
        '1.0-dec46b', // six digits
        '1.0-DEC46B0', // uppercase
        '1.0.dec46b0', // no dash
        '1.0:Eclipse',
        '2.1.0-rc1',
        'dec46b0-1.0', // not at the end
      ]) {
        expect(withoutGitHash(version), version, reason: version);
      }
    });
  });

  group('appHasUpdate', () {
    test('NagramXF tagged 1450 is not an update over the same APK (#59)', () {
      final app = _app(
        installed: '12.10.1-dec46b0',
        installedCode: 1250,
        latest: '12.10.1-dec46b0',
        latestCode: 1250,
      );
      expect(appHasUpdate(app), false);
    });

    test('an older installed build has an update', () {
      final app = _app(
        installed: '12.9.2-bd9adbc',
        installedCode: 1249,
        latest: '12.10.1-dec46b0',
        latestCode: 1250,
      );
      expect(appHasUpdate(app), true);
    });

    test('nothing is offered before the APK has been read', () {
      final app = _app(installed: '12.9.2-bd9adbc', installedCode: 1249);
      expect(appHasUpdate(app), false);
    });

    test('an app that is not installed has no update', () {
      final app = _app(latest: '12.10.1-dec46b0', latestCode: 1250);
      expect(appHasUpdate(app), false);
    });

    test('a track-only app has no APK, so its release version decides', () {
      final app = _app(installed: '1449', release: '1450', trackOnly: true);
      expect(appHasUpdate(app), true);
      expect(
        appHasUpdate(
          _app(installed: 'v1450', release: '1450', trackOnly: true),
        ),
        false,
        reason: 'the same release spelled with a leading v',
      );
    });
  });

  group('versionNameOrCode', () {
    test('uses the versionName when there is one', () {
      expect(versionNameOrCode('1.0', 3), '1.0');
    });

    test('falls back to the versionCode', () {
      expect(versionNameOrCode(null, 3), '3');
    });
  });
}
