import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/source_provider.dart';

List<MapEntry<String, String>> _apks(List<String> names) => [
  for (final name in names) MapEntry(name, 'https://ex.com/$name'),
];

int? _match(List<String> names, String? chosen) =>
    ApkFilterService.indexOfApkNamedLike(_apks(names), chosen);

void main() {
  group('apkNameWords', () {
    test('leaves out version numbers', () {
      expect(
        ApkFilterService.apkNameWords(
          'jellyfin-android-v2.7.3-libre-release.apk',
        ),
        {'jellyfin', 'android', 'libre', 'release', 'apk'},
      );
    });

    test('keeps words that only contain digits in part', () {
      expect(
        ApkFilterService.apkNameWords('v2rayNG_2.2.6-fdroid_arm64-v8a.apk'),
        {'v2rayng', 'fdroid', 'arm64', 'v8a', 'apk'},
      );
    });
  });

  group('indexOfApkNamedLike', () {
    test('finds the same flavour in a later release', () {
      const jellyfin = [
        'jellyfin-android-v2.7.4-libre-debug.apk',
        'jellyfin-android-v2.7.4-libre-release.apk',
        'jellyfin-android-v2.7.4-proprietary-debug.apk',
        'jellyfin-android-v2.7.4-proprietary-release.apk',
      ];
      expect(_match(jellyfin, 'jellyfin-android-v2.7.3-libre-release.apk'), 1);
      expect(
        _match(jellyfin, 'jellyfin-android-v2.7.3-proprietary-debug.apk'),
        2,
      );
    });

    test('tells a flavour apart from the plain build', () {
      const saber = ['Saber_FOSS_v1.37.0.apk', 'Saber_v1.37.0.apk'];
      expect(_match(saber, 'Saber_FOSS_v1.36.1.apk'), 0);
      expect(_match(saber, 'Saber_v1.36.1.apk'), 1);
      const bitwarden = [
        'com.x8bit.bitwarden-fdroid.apk',
        'com.x8bit.bitwarden.apk',
      ];
      expect(_match(bitwarden, 'com.x8bit.bitwarden.apk'), 1);
    });

    test('finds it wherever it now sits in the list', () {
      const v2rayNG = [
        'v2rayNG_2.2.7_arm64-v8a.apk',
        'v2rayNG_2.2.7-fdroid_arm64-v8a.apk',
      ];
      expect(_match(v2rayNG, 'v2rayNG_2.2.6-fdroid_arm64-v8a.apk'), 1);
    });

    test('leaves the choice to the user when nothing is named like it', () {
      expect(
        _match([
          'app-arm64-v8a-release-signed.apk',
        ], 'app-arm64-v8a-release.apk'),
        isNull,
      );
      expect(_match(['app-release.apk', 'app-debug.apk'], null), isNull);
    });

    test('leaves the choice to the user when several are named like it', () {
      // F-Droid names each build only by its versionCode.
      expect(
        _match([
          'org.jitsi.meet_26000002.apk',
          'org.jitsi.meet_26000001.apk',
        ], 'org.jitsi.meet_25060102.apk'),
        isNull,
      );
    });
  });

  test('App offers the chosen APK name only while set to remember it', () {
    App app(Map<String, dynamic> settings) => App(
      id: 'com.x8bit.bitwarden',
      url: 'https://github.com/bitwarden/android',
      author: 'Bitwarden',
      name: 'Bitwarden',
      latestVersion: 'v2026.9.1-bwpm',
      preferredApkIndex: 0,
      preferredApkName: 'com.x8bit.bitwarden-fdroid.apk',
      additionalSettings: settings,
    );
    // Apps saved before the setting existed remember it.
    expect(app({}).rememberedApkName, 'com.x8bit.bitwarden-fdroid.apk');
    expect(
      app({'rememberChosenApk': true}).rememberedApkName,
      'com.x8bit.bitwarden-fdroid.apk',
    );
    expect(app({'rememberChosenApk': false}).rememberedApkName, isNull);
  });

  test('App keeps the chosen APK name and the ABIs read through JSON', () {
    final app = App(
      id: 'com.x8bit.bitwarden',
      url: 'https://github.com/bitwarden/android',
      author: 'Bitwarden',
      name: 'Bitwarden',
      latestVersion: 'v2026.9.1-bwpm',
      apkUrls: _apks(['com.x8bit.bitwarden-fdroid.apk']),
      preferredApkIndex: 0,
      preferredApkName: 'com.x8bit.bitwarden-fdroid.apk',
      apkAbis: const {
        'https://ex.com/com.x8bit.bitwarden-fdroid.apk': [
          'arm64-v8a',
          'x86_64',
        ],
      },
      additionalSettings: const {},
    );
    final restored = App.fromJson(
      jsonDecode(jsonEncode(app.toJson())) as Map<String, dynamic>,
    );
    expect(restored.preferredApkName, 'com.x8bit.bitwarden-fdroid.apk');
    expect(restored.apkAbis, {
      'https://ex.com/com.x8bit.bitwarden-fdroid.apk': ['arm64-v8a', 'x86_64'],
    });
    expect(restored.copyWith(preferredApkName: null).preferredApkName, isNull);
    expect(restored.copyWith().preferredApkName, restored.preferredApkName);
  });
}
