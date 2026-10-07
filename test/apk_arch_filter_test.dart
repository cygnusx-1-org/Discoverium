import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/apk_filter_service.dart';

/// A phone that also runs 32-bit apps, a 64-bit-only one (Pixel 7 onwards),
/// a 32-bit one, and an x86_64 emulator that translates ARM.
const _arm64And32 = ['arm64-v8a', 'armeabi-v7a', 'armeabi'];
const _arm64Only = ['arm64-v8a'];
const _arm32 = ['armeabi-v7a', 'armeabi'];
const _emulator = ['x86_64', 'arm64-v8a'];

List<MapEntry<String, String>> _apks(List<String> names) => [
  for (final name in names) MapEntry(name, 'https://ex.com/$name'),
];

Future<List<String>> _pick(List<String> names, List<String> deviceAbis) async =>
    (await ApkFilterService().filterApksByArch(
      _apks(names),
      deviceAbis,
    )).map((e) => e.key).toList();

void main() {
  group('abisFromName', () {
    test('reads the ABI spellings real releases use', () {
      const names = {
        'termux-app_v0.118.3+github-debug_arm64-v8a.apk': 'arm64-v8a',
        'termux-app_v0.118.3+github-debug_armeabi-v7a.apk': 'armeabi-v7a',
        'rustdesk-1.5.0-aarch64-signed.apk': 'arm64-v8a',
        'rustdesk-1.5.0-armv7-signed.apk': 'armeabi-v7a',
        'rustdesk-1.5.0-x86_64-signed.apk': 'x86_64',
        'LocalSend-1.18.2-android-arm64v8.apk': 'arm64-v8a',
        'LocalSend-1.18.2-android-arm32v7.apk': 'armeabi-v7a',
        'LocalSend-1.18.2-android-x64.apk': 'x86_64',
        'Hiddify-Android-arm64.apk': 'arm64-v8a',
        'Hiddify-Android-arm7.apk': 'armeabi-v7a',
        'v2rayNG_2.2.6_x86.apk': 'x86',
        'pgs1.269.2_0.425.1_DvbwE(arm64).apk': 'arm64-v8a',
        'app-arm.apk': 'armeabi-v7a',
        'app-armhf.apk': 'armeabi-v7a',
        'app-arm_v8a.apk': 'arm64-v8a',
        'app-amd64.apk': 'x86_64',
        'app-x86-64.apk': 'x86_64',
        'app-i686.apk': 'x86',
        'app-armeabi.apk': 'armeabi',
        'appArm64.apk': 'arm64-v8a',
      };
      for (final name in names.entries) {
        expect(ApkFilterService.abisFromName(name.key), {
          name.value,
        }, reason: name.key);
      }
    });

    test('does not find one ABI inside the name of another', () {
      for (final name in [
        'app-x86_64.apk',
        'app-arm64.apk',
        'app-armeabi-v7a.apk',
        'app-arm-v8a.apk',
        'app-arm-64.apk',
      ]) {
        expect(ApkFilterService.abisFromName(name), hasLength(1), reason: name);
      }
    });

    test('reads every ABI a name lists', () {
      // APKPure names a build for several ABIs this way.
      expect(
        ApkFilterService.abisFromName(
          'org.example-120-arm64-v8a,armeabi-v7a.apk',
        ),
        {'arm64-v8a', 'armeabi-v7a'},
      );
    });

    test('takes a universal APK for one that runs on any ABI', () {
      expect(
        ApkFilterService.abisFromName('Hiddify-Android-universal.apk'),
        <String>{},
      );
    });

    test('knows nothing from a name that names no ABI', () {
      for (final name in [
        'app-release.apk',
        'com.x8bit.bitwarden-fdroid.apk',
        'org.jitsi.meet_26000002.apk',
        'Armory-1.2.apk',
        'v2rayNG_2.2.6-fdroid.apk',
        'app-armv8l.apk',
      ]) {
        expect(ApkFilterService.abisFromName(name), isNull, reason: name);
      }
    });
  });

  group('filterApksByArch', () {
    const localSend = [
      'LocalSend-1.18.2-android-arm32v7.apk',
      'LocalSend-1.18.2-android-arm64v8.apk',
      'LocalSend-1.18.2-android-google-play.apk',
      'LocalSend-1.18.2-android-x64.apk',
    ];
    const hiddify = [
      'Hiddify-Android-arm64.apk',
      'Hiddify-Android-arm7.apk',
      'Hiddify-Android-universal.apk',
      'Hiddify-Android-x86_64.apk',
    ];

    test('picks the build for the device ABI', () async {
      expect(await _pick(localSend, _arm64And32), [
        'LocalSend-1.18.2-android-arm64v8.apk',
      ]);
      expect(await _pick(hiddify, _arm64Only), ['Hiddify-Android-arm64.apk']);
      expect(await _pick(hiddify, _emulator), ['Hiddify-Android-x86_64.apk']);
    });

    test('picks the 32-bit build on a 32-bit phone', () async {
      expect(await _pick(localSend, _arm32), [
        'LocalSend-1.18.2-android-arm32v7.apk',
      ]);
      expect(await _pick(hiddify, _arm32), ['Hiddify-Android-arm7.apk']);
    });

    test('prefers a build that may be 64-bit to a 32-bit one', () async {
      // The arm64 build is the unlabelled one; the old filter went on to the
      // phone's second ABI and picked the 32-bit build.
      expect(await _pick(['app.apk', 'app-armv7.apk'], _arm64And32), [
        'app.apk',
      ]);
      expect(
        await _pick(['app-universal.apk', 'app-armeabi-v7a.apk'], _arm64And32),
        ['app-universal.apk'],
      );
    });

    test('prefers the build for the device ABI to a universal one', () async {
      expect(
        await _pick(['app-universal.apk', 'app-arm64-v8a.apk'], _arm64And32),
        ['app-arm64-v8a.apk'],
      );
    });

    test('drops builds the device cannot run', () async {
      expect(
        await _pick(['app.apk', 'app-arm64.apk', 'app-x86_64.apk'], _arm32),
        ['app.apk'],
      );
      expect(await _pick(['app-armv7.apk', 'app-x86.apk'], _arm64And32), [
        'app-armv7.apk',
      ]);
    });

    test('picks the most specific of several builds for the ABI', () async {
      expect(
        await _pick([
          'org.example-120-arm64-v8a,armeabi-v7a.apk',
          'org.example-120-arm64-v8a.apk',
        ], _arm64And32),
        ['org.example-120-arm64-v8a.apk'],
      );
    });

    test('leaves flavours of the same ABI to the user', () async {
      const obtainium = [
        'app-arm64-v8a-fdroid-release.apk',
        'app-arm64-v8a-release.apk',
        'app-armeabi-v7a-fdroid-release.apk',
        'app-armeabi-v7a-release.apk',
      ];
      expect(await _pick(obtainium, _arm64And32), [
        'app-arm64-v8a-fdroid-release.apk',
        'app-arm64-v8a-release.apk',
      ]);
    });

    test('keeps everything when it cannot tell', () async {
      const bitwarden = [
        'com.x8bit.bitwarden-fdroid.apk',
        'com.x8bit.bitwarden.apk',
      ];
      expect(await _pick(bitwarden, _arm64And32), bitwarden);
      // Nothing here runs on this phone, so it is left to the user.
      const foreign = ['app-x86.apk', 'app-x86_64.apk'];
      expect(await _pick(foreign, _arm64Only), foreign);
      expect(await _pick(foreign, const []), foreign);
    });
  });

  group('runnableSuggestion', () {
    // Jitsi Meet's builds of 26.0.0, F-Droid suggesting the x86_64 one.
    const builds = [
      (code: 26000004, version: '26.0.0', abi: 'x86_64'),
      (code: 26000003, version: '26.0.0', abi: 'x86'),
      (code: 26000002, version: '26.0.0', abi: 'arm64-v8a'),
      (code: 26000001, version: '26.0.0', abi: 'armeabi-v7a'),
      (code: 25060102, version: '25.6.1', abi: 'arm64-v8a'),
    ];
    List<int> suggest(List<String> deviceAbis) {
      final runnable = ApkFilterService.runnableByAbi(
        builds,
        (b) => {b.abi},
        deviceAbis,
      );
      return ApkFilterService.runnableSuggestion(
        [builds.first],
        runnable,
        (b) => b.version,
      ).map((b) => b.code).toList();
    }

    test('keeps a suggested build the device can run', () {
      expect(suggest(_emulator), [26000004]);
    });

    test('stands in the runnable builds of the same version', () {
      expect(suggest(_arm64And32), [26000002, 26000001]);
      expect(suggest(_arm64Only), [26000002]);
    });

    test('keeps the suggestion when nothing else runs either', () {
      expect(suggest(const ['riscv64']), [26000004]);
    });
  });

  group('selectApksByAbi', () {
    Future<Set<String>?> Function(MapEntry<String, String>) reader(
      Map<String, Set<String>?> contents,
      List<String> read,
    ) => (apk) async {
      read.add(apk.key);
      return contents[apk.key];
    };

    test('reads nothing when names settle it', () async {
      final read = <String>[];
      final selection = await ApkFilterService.selectApksByAbi(
        _apks(['app-arm64-v8a.apk', 'app-armeabi-v7a.apk', 'app.apk']),
        _arm64And32,
        readAbis: reader({}, read),
      );
      expect(selection.apkUrls.map((e) => e.key), ['app-arm64-v8a.apk']);
      expect(selection.apkAbis, isEmpty);
      expect(read, isEmpty);
    });

    test('reads APKs whose names do not say', () async {
      final read = <String>[];
      final selection = await ApkFilterService.selectApksByAbi(
        _apks(['fennec-1.apk', 'fennec-2.apk', 'fennec-3.apk']),
        _arm64And32,
        readAbis: reader({
          'fennec-1.apk': {'armeabi-v7a'},
          'fennec-2.apk': {'x86_64'},
          'fennec-3.apk': {'arm64-v8a'},
        }, read),
      );
      expect(selection.apkUrls.map((e) => e.key), ['fennec-3.apk']);
      expect(
        read,
        unorderedEquals(['fennec-1.apk', 'fennec-2.apk', 'fennec-3.apk']),
      );
      expect(selection.apkAbis, {
        'https://ex.com/fennec-1.apk': ['armeabi-v7a'],
        'https://ex.com/fennec-2.apk': ['x86_64'],
        'https://ex.com/fennec-3.apk': ['arm64-v8a'],
      });
    });

    test(
      'checks an unlabelled APK before preferring it to a 32-bit one',
      () async {
        final read = <String>[];
        final selection = await ApkFilterService.selectApksByAbi(
          _apks(['app.apk', 'app-armv7.apk']),
          _arm64And32,
          readAbis: reader({
            'app.apk': {'x86', 'x86_64'},
          }, read),
        );
        expect(selection.apkUrls.map((e) => e.key), ['app-armv7.apk']);
        expect(read, ['app.apk']);
      },
    );

    test('reuses what an earlier check read', () async {
      final read = <String>[];
      final selection = await ApkFilterService.selectApksByAbi(
        _apks(['a.apk', 'b.apk']),
        _arm64Only,
        known: {
          'https://ex.com/a.apk': ['arm64-v8a'],
        },
        readAbis: reader({
          'b.apk': {'armeabi-v7a'},
        }, read),
      );
      expect(selection.apkUrls.map((e) => e.key), ['a.apk']);
      expect(read, ['b.apk']);
      expect(
        selection.apkAbis.keys,
        unorderedEquals(['https://ex.com/a.apk', 'https://ex.com/b.apk']),
      );
    });

    test('leaves an APK it cannot read unknown', () async {
      final selection = await ApkFilterService.selectApksByAbi(
        _apks(['a.apk', 'b.apk']),
        _arm64And32,
        readAbis: reader({'b.apk': {}}, []),
      );
      expect(selection.apkUrls.map((e) => e.key), ['a.apk', 'b.apk']);
      expect(selection.apkAbis, {'https://ex.com/b.apk': <String>[]});
    });

    test('reads nothing without a reader or past the limit', () async {
      final read = <String>[];
      final untracked = await ApkFilterService.selectApksByAbi(
        _apks(['a.apk', 'b.apk']),
        _arm64And32,
      );
      expect(untracked.apkUrls, hasLength(2));
      final many = await ApkFilterService.selectApksByAbi(
        _apks([
          for (var i = 0; i <= ApkFilterService.maxApksToRead; i++)
            'app-$i.apk',
        ]),
        _arm64And32,
        readAbis: reader({}, read),
      );
      expect(many.apkUrls, hasLength(ApkFilterService.maxApksToRead + 1));
      expect(read, isEmpty);
    });
  });
}
