import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/fdroid.dart';

/// Jitsi Meet as f-droid.org lists it: one build of each version per ABI, the
/// packages API giving only their versionCodes and suggesting the x86_64 one.
final _api = Response(
  jsonEncode({
    'packageName': 'org.jitsi.meet',
    'suggestedVersionCode': 26000004,
    'packages': [
      {'versionName': '26.0.0', 'versionCode': 26000004},
      {'versionName': '26.0.0', 'versionCode': 26000003},
      {'versionName': '26.0.0', 'versionCode': 26000002},
      {'versionName': '26.0.0', 'versionCode': 26000001},
      {'versionName': '25.6.1', 'versionCode': 25060104},
    ],
  }),
  200,
);

/// The parts of the app's page that say which ABI each build is for, as
/// f-droid.org served them on 2026-10-05.
String _build(String version, int code, List<String> abis) =>
    '''
<li class="package-version">
<div class="package-version-header">
<a name="$version"></a>
<a name="$code"></a>
<b>Version $version</b> ($code)
Added on Apr 19, 2026
</div>
${abis.isEmpty ? '' : '<p class="package-version-nativecode">${abis.map((a) => '<code class="package-nativecode">$a</code>').join('\n')}</p>'}
<p class="package-version-requirement">This version requires Android 8.0 or newer.</p>
</li>''';

final _page =
    '''
<ul class="package-versions-list">
${_build('26.0.0', 26000004, ['x86_64'])}
${_build('26.0.0', 26000003, ['x86'])}
${_build('26.0.0', 26000002, ['arm64-v8a'])}
${_build('26.0.0', 26000001, ['armeabi-v7a'])}
${_build('25.6.1', 25060104, [])}
</ul>''';

const _arm64And32 = ['arm64-v8a', 'armeabi-v7a', 'armeabi'];
const _arm64Only = ['arm64-v8a'];
const _emulator = ['x86_64', 'arm64-v8a'];

List<String> _offered({
  Map<int, List<String>>? nativecodes,
  List<String> deviceAbis = const [],
  bool filterByArch = true,
  bool suggested = true,
  bool highest = false,
}) => FDroid()
    .getAPKUrlsFromFDroidPackagesAPIResponse(
      _api,
      'https://f-droid.org/repo/org.jitsi.meet',
      'https://f-droid.org/packages/org.jitsi.meet',
      'F-Droid',
      additionalSettings: {
        'autoApkFilterByArch': filterByArch,
        'trySelectingSuggestedVersionCode': suggested,
        'autoSelectHighestVersionCode': highest,
      },
      nativecodes: nativecodes,
      deviceAbis: deviceAbis,
    )
    .apkUrls
    .map((e) => e.key)
    .toList();

void main() {
  final nativecodes = FDroid.parseNativecodes(_page);

  test('parseNativecodes reads the ABIs of each build on the page', () {
    expect(nativecodes, {
      26000004: ['x86_64'],
      26000003: ['x86'],
      26000002: ['arm64-v8a'],
      26000001: ['armeabi-v7a'],
      25060104: <String>[],
    });
  });

  group('getAPKUrlsFromFDroidPackagesAPIResponse', () {
    test('offers the suggested build when it cannot tell ABIs apart', () {
      // IzzyOnDroid, or an F-Droid page that could not be read.
      expect(_offered(deviceAbis: _arm64And32), [
        'org.jitsi.meet_26000004.apk',
      ]);
    });

    test('does not offer a suggested build for another ABI', () {
      expect(_offered(nativecodes: nativecodes, deviceAbis: _arm64And32), [
        'org.jitsi.meet_26000002.apk',
      ]);
    });

    test('offers the builds of the suggested version this device can run', () {
      expect(
        _offered(
          nativecodes: nativecodes,
          deviceAbis: _arm64And32,
          filterByArch: false,
        ),
        ['org.jitsi.meet_26000002.apk', 'org.jitsi.meet_26000001.apk'],
      );
      expect(
        _offered(
          nativecodes: nativecodes,
          deviceAbis: _arm64Only,
          filterByArch: false,
        ),
        ['org.jitsi.meet_26000002.apk'],
      );
    });

    test('keeps a suggested build this device can run', () {
      expect(_offered(nativecodes: nativecodes, deviceAbis: _emulator), [
        'org.jitsi.meet_26000004.apk',
      ]);
    });

    test('picks the highest versionCode among the right ABI', () {
      expect(
        _offered(
          nativecodes: nativecodes,
          deviceAbis: _arm64And32,
          suggested: false,
          highest: true,
        ),
        ['org.jitsi.meet_26000002.apk'],
      );
    });

    test('filters the latest version by ABI without a suggestion', () {
      expect(
        _offered(
          nativecodes: nativecodes,
          deviceAbis: _arm64And32,
          suggested: false,
        ),
        ['org.jitsi.meet_26000002.apk'],
      );
    });

    test('offers an older version when no build of the latest runs', () {
      // 25.6.1 has no native code, so it runs anywhere.
      expect(
        _offered(
          nativecodes: nativecodes,
          deviceAbis: const ['riscv64'],
          suggested: false,
        ),
        ['org.jitsi.meet_25060104.apk'],
      );
    });

    test('falls back to every build when none runs on this device', () {
      expect(
        _offered(
          nativecodes: {
            ...nativecodes,
            25060104: ['x86'],
          },
          deviceAbis: const ['riscv64'],
          suggested: false,
        ),
        [
          'org.jitsi.meet_26000004.apk',
          'org.jitsi.meet_26000003.apk',
          'org.jitsi.meet_26000002.apk',
          'org.jitsi.meet_26000001.apk',
        ],
      );
    });
  });
}
