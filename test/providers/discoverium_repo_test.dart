import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/discoverium_repo.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

/// The two entries named in #28, verbatim from `repo/apps.yml`.
const fossifyClock = DiscoveriumApp(
  name: 'Fossify Clock',
  description: 'A clock app',
  id: 'org.fossify.clock',
  author: 'Tibor Kaputa, Naveen Singh',
  releasesUrl: 'https://github.com/FossifyOrg/Clock/releases',
);

const antiSplit = DiscoveriumApp(
  name: 'Antisplit-M',
  description: 'Merge split APKs',
  id: 'com.abdurazaaqmohammed.AntiSplit',
  author: 'Abdurazaaq Mohammed',
  releasesUrl: 'https://github.com/AbdurazaaqMohammed/AntiSplit-M/releases',
);

Set<String> urls(List<String> raw) =>
    raw.map(DiscoveriumRepo.normalizeUrl).toSet();

void main() {
  group('isAlreadyAdded', () {
    test('hides an entry whose package ID is in the app list', () {
      expect(
        DiscoveriumRepo.isAlreadyAdded(fossifyClock, {
          'org.fossify.clock',
        }, const {}),
        isTrue,
      );
    });

    test('keeps an entry that is in neither the IDs nor the URLs', () {
      expect(
        DiscoveriumRepo.isAlreadyAdded(fossifyClock, {
          'org.fossify.gallery',
        }, urls(['https://github.com/FossifyOrg/Gallery'])),
        isFalse,
      );
    });

    // #28: `saveApps` overwrites a stored app's name with the installed
    // package's localized label, so the curated title is not what is held.
    test('hides a localized app the old name match could never catch', () {
      // "Zegar" is what a Polish locale stores for Fossify Clock, and the app
      // was added from IzzyOnDroid rather than the curated GitHub URL, so the
      // package ID is the only thing the two have in common.
      expect(
        DiscoveriumRepo.isAlreadyAdded(
          fossifyClock,
          {'org.fossify.clock'},
          urls(['https://apt.izzysoft.de/fdroid/index/apk/org.fossify.clock']),
        ),
        isTrue,
      );
    });

    test('hides an app whose label differs only in punctuation', () {
      // The APK calls itself "AntiSplit M", the repo entry "Antisplit-M".
      expect(
        DiscoveriumRepo.isAlreadyAdded(antiSplit, {
          'com.abdurazaaqmohammed.AntiSplit',
        }, const {}),
        isTrue,
      );
    });

    test('matches the repo URL against a stored URL with no /releases', () {
      // What GitHub's `sourceSpecificStandardizeURL` actually stores.
      expect(
        DiscoveriumRepo.isAlreadyAdded(
          fossifyClock,
          const {},
          urls(['https://github.com/FossifyOrg/Clock']),
        ),
        isTrue,
      );
    });

    test('falls back to the URL for an entry with no ID', () {
      const noId = DiscoveriumApp(
        name: 'Fossify Clock',
        description: 'A clock app',
        releasesUrl: 'https://github.com/FossifyOrg/Clock/releases',
      );
      expect(
        DiscoveriumRepo.isAlreadyAdded(
          noId,
          const {},
          urls(['https://github.com/FossifyOrg/Clock']),
        ),
        isTrue,
      );
    });

    test('ignores an empty ID rather than matching an empty app key', () {
      const emptyId = DiscoveriumApp(
        name: 'Fossify Clock',
        description: 'A clock app',
        id: '',
        releasesUrl: 'https://github.com/FossifyOrg/Clock/releases',
      );
      expect(DiscoveriumRepo.isAlreadyAdded(emptyId, {''}, const {}), isFalse);
    });

    test('keeps an entry with neither an ID nor a releases URL', () {
      const bare = DiscoveriumApp(name: 'Nameless', description: '');
      expect(
        DiscoveriumRepo.isAlreadyAdded(bare, {
          'org.fossify.clock',
        }, urls(['https://github.com/FossifyOrg/Clock'])),
        isFalse,
      );
    });

    // A temporary ID is all digits or 12 hex chars (`isTempId`), so it can
    // never collide with a dotted package name — the URL still has to carry it.
    test('a temp-ID app is still matched by its URL', () {
      expect(
        DiscoveriumRepo.isAlreadyAdded(fossifyClock, {
          'a3f19c2d7b04',
        }, urls(['https://github.com/FossifyOrg/Clock'])),
        isTrue,
      );
    });

    test('a temp-ID app on an unrelated URL does not hide the entry', () {
      expect(
        DiscoveriumRepo.isAlreadyAdded(fossifyClock, {
          'a3f19c2d7b04',
          '12345',
        }, urls(['https://github.com/SomeoneElse/Clock'])),
        isFalse,
      );
    });

    test('an unrelated app sharing the title no longer hides the entry', () {
      // The old name|author fallback would have hidden this one.
      expect(
        DiscoveriumRepo.isAlreadyAdded(fossifyClock, {
          'com.example.knockoff',
        }, urls(['https://github.com/Example/FossifyClockFork'])),
        isFalse,
      );
    });
  });
  group('tv', () {
    // Verbatim from `repo/apps.yml`.
    const libreTorrentYaml = '''
- name: LibreTorrent
  authors: Yaroslav Pronin
  category: tools
  commercial: false
  description: Free and Open Source, full-featured torrent client for Android.
  icon: https://raw.githubusercontent.com/proninyaroslav/libretorrent/refs/heads/master/app/src/release/res/mipmap-xxxhdpi/ic_launcher.png
  id: org.proninyaroslav.libretorrent
  tv: no
  type: curated
  verified: true
  releases:
    url: https://github.com/proninyaroslav/libretorrent/releases
''';

    DiscoveriumApp parse(String yaml) =>
        DiscoveriumApp.fromYaml((loadYaml(yaml) as YamlList).single as YamlMap);

    DiscoveriumApp withTv(String? tvLine, {String id = 'com.example.app'}) =>
        parse('''
- name: Example
  id: $id
${tvLine == null ? '' : '  $tvLine\n'}''');

    test('reads tv: no from a repo entry', () {
      expect(parse(libreTorrentYaml).tv, TvSupport.no);
    });

    test('reads tv: yes and tv: only', () {
      expect(withTv('tv: yes').tv, TvSupport.yes);
      expect(withTv('tv: only').tv, TvSupport.only);
    });

    test('reads tv values in any case', () {
      expect(withTv('tv: Yes').tv, TvSupport.yes);
      expect(withTv('tv: ONLY').tv, TvSupport.only);
    });

    test('still reads the older tv: true and tv: false', () {
      expect(withTv('tv: true').tv, TvSupport.yes);
      expect(withTv('tv: false').tv, TvSupport.no);
    });

    test('a missing or unrecognised tv value means no', () {
      expect(withTv(null).tv, TvSupport.no);
      expect(withTv('tv: maybe').tv, TvSupport.no);
    });

    test('Discoverium supports TV whatever its entry says', () {
      expect(withTv('tv: no', id: obtainiumId).tv, TvSupport.yes);
      expect(withTv('tv: only', id: obtainiumId).tv, TvSupport.yes);
      expect(withTv(null, id: obtainiumId).tv, TvSupport.yes);
    });

    const phoneApp = DiscoveriumApp(name: 'Phone', description: '');
    const bothApp = DiscoveriumApp(
      name: 'Both',
      description: '',
      tv: TvSupport.yes,
    );
    const tvOnlyApp = DiscoveriumApp(
      name: 'TV',
      description: '',
      tv: TvSupport.only,
    );

    test('off leaves out only the TV-only apps', () {
      expect(phoneApp.isShownFor(TvAppsMode.off), isTrue);
      expect(bothApp.isShownFor(TvAppsMode.off), isTrue);
      expect(tvOnlyApp.isShownFor(TvAppsMode.off), isFalse);
    });

    test('on shows everything', () {
      expect(phoneApp.isShownFor(TvAppsMode.on), isTrue);
      expect(bothApp.isShownFor(TvAppsMode.on), isTrue);
      expect(tvOnlyApp.isShownFor(TvAppsMode.on), isTrue);
    });

    test('TV only shows the apps that run on TV', () {
      expect(phoneApp.isShownFor(TvAppsMode.tvOnly), isFalse);
      expect(bothApp.isShownFor(TvAppsMode.tvOnly), isTrue);
      expect(tvOnlyApp.isShownFor(TvAppsMode.tvOnly), isTrue);
    });
  });
  group('showTvApps setting', () {
    Future<SettingsProvider> withPrefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SettingsProvider()..prefs = await SharedPreferences.getInstance();
    }

    test('defaults to off on a phone', () async {
      expect((await withPrefs({})).showTvApps, TvAppsMode.off);
    });

    test('defaults to TV only on Android TV', () async {
      final settings = await withPrefs({})
        ..isTV = true;
      expect(settings.showTvApps, TvAppsMode.tvOnly);
    });

    test('a saved choice wins over the Android TV default', () async {
      final settings = await withPrefs({'showTvApps': 'on'})
        ..isTV = true;
      expect(settings.showTvApps, TvAppsMode.on);
    });

    test('round-trips every option', () async {
      for (final mode in TvAppsMode.values) {
        final settings = await withPrefs({});
        settings.showTvApps = mode;
        expect(settings.showTvApps, mode);
      }
    });

    test('an unknown stored value falls back to the default', () async {
      expect(
        (await withPrefs({'showTvApps': 'sometimes'})).showTvApps,
        TvAppsMode.off,
      );
      final tv = await withPrefs({'showTvApps': 'sometimes'})
        ..isTV = true;
      expect(tv.showTvApps, TvAppsMode.tvOnly);
    });
  });
}
