import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/apps_provider.dart';

AppInMemory _aim(String id, {required bool trackOnly}) => AppInMemory(
  App(
    id: id,
    url: 'https://example.com/$id',
    author: 'Author',
    name: 'App $id',
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    preferredApkIndex: 0,
    additionalSettings: {'trackOnly': trackOnly},
  ),
  null,
  null,
  null,
);

void main() {
  group('unconfirmedBulkObtainIds', () {
    test('leaves non-installed apps out when nothing is selected', () {
      expect(
        unconfirmedBulkObtainIds(
          ['update'],
          ['notInstalled'],
          hasSelection: false,
        ),
        {'update'},
      );
    });

    test('includes non-installed apps the user selected', () {
      expect(
        unconfirmedBulkObtainIds(
          ['update'],
          ['notInstalled'],
          hasSelection: true,
        ),
        {'update', 'notInstalled'},
      );
    });

    test('is empty when only unselected non-installed apps are pending', () {
      expect(
        unconfirmedBulkObtainIds(const [], [
          'notInstalled',
        ], hasSelection: false),
        isEmpty,
      );
    });
  });

  group('withoutTrackOnlyApps', () {
    final apps = {
      'normal': _aim('normal', trackOnly: false),
      'tracked': _aim('tracked', trackOnly: true),
    };

    test('drops track-only apps and keeps the rest', () {
      expect(withoutTrackOnlyApps(['normal', 'tracked'], apps), ['normal']);
    });

    test('drops an app that is no longer known', () {
      expect(withoutTrackOnlyApps(['removed'], apps), isEmpty);
    });
  });
}
