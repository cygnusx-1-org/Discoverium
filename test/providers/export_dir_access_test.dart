import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _documentFileChannel = MethodChannel(
  'io.alexrintt.plugins/sharedstorage/documentfile',
);
const _safAccessChannel = MethodChannel('dev.imranr.obtainium/saf_access');

const _documents =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments';
const _download =
    'content://com.android.externalstorage.documents/tree/primary%3ADownload';

Map<String, Object> _grant(String uri, {required bool read}) => {
  'isReadPermission': read,
  'isWritePermission': true,
  'persistedTime': 0,
  'uri': uri,
  'isTreeDocumentFile': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<Map<String, Object>> grants;
  late String? pickedDir;
  late List<MethodCall> safAccessCalls;
  late bool failPersist;

  Future<SettingsProvider> withPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SettingsProvider()..prefs = await SharedPreferences.getInstance();
  }

  setUp(() {
    grants = [];
    pickedDir = null;
    safAccessCalls = [];
    failPersist = false;
    messenger.setMockMethodCallHandler(_documentFileChannel, (call) async {
      switch (call.method) {
        case 'persistedUriPermissions':
          return grants;
        case 'canRead':
        case 'canWrite':
        case 'canOpenDocumentTree':
          return true;
        case 'openDocumentTree':
          return pickedDir;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_safAccessChannel, (call) async {
      safAccessCalls.add(call);
      if (failPersist && call.method == 'persistTreeAccess') {
        throw PlatformException(code: 'NO_GRANT');
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_documentFileChannel, null);
    messenger.setMockMethodCallHandler(_safAccessChannel, null);
  });

  group('upgradeExportDirAccess', () {
    test('widens a write-only grant on the export dir', () async {
      grants = [_grant(_documents, read: false)];
      final settings = await withPrefs({'exportDir': _documents});

      await settings.upgradeExportDirAccess();

      expect(safAccessCalls, hasLength(1));
      expect(safAccessCalls.single.method, 'persistTreeAccess');
      expect(safAccessCalls.single.arguments, {'uri': _documents});
    });

    test('leaves a grant that already includes read alone', () async {
      grants = [_grant(_documents, read: true)];
      final settings = await withPrefs({'exportDir': _documents});

      await settings.upgradeExportDirAccess();

      expect(safAccessCalls, isEmpty);
    });

    test('ignores write-only grants on other trees', () async {
      grants = [_grant(_download, read: false)];
      final settings = await withPrefs({'exportDir': _documents});

      await settings.upgradeExportDirAccess();

      expect(safAccessCalls, isEmpty);
    });

    test('does nothing without an export dir', () async {
      grants = [_grant(_documents, read: false)];
      final settings = await withPrefs({});

      await settings.upgradeExportDirAccess();

      expect(safAccessCalls, isEmpty);
    });

    // After a reboot the system has dropped the read mode and refuses to
    // persist it again; that must not surface as an error at startup.
    test('swallows a refused upgrade', () async {
      grants = [_grant(_documents, read: false)];
      failPersist = true;
      final settings = await withPrefs({'exportDir': _documents});

      await expectLater(settings.upgradeExportDirAccess(), completes);
      expect(safAccessCalls.single.method, 'persistTreeAccess');
    });
  });

  group('pickExportDir', () {
    test('persists both modes of the picked tree and releases the old '
        'one', () async {
      grants = [_grant(_download, read: true)];
      pickedDir = _documents;
      final settings = await withPrefs({'exportDir': _download});

      await settings.pickExportDir();

      expect(safAccessCalls.map((c) => [c.method, c.arguments]).toList(), [
        [
          'persistTreeAccess',
          {'uri': _documents},
        ],
        [
          'releaseTreeAccess',
          {'uri': _download},
        ],
      ]);
      expect(settings.prefs!.getString('exportDir'), _documents);
    });

    test('keeps the picked tree when persisting fails', () async {
      pickedDir = _documents;
      failPersist = true;
      final settings = await withPrefs({});

      await settings.pickExportDir();

      expect(settings.prefs!.getString('exportDir'), _documents);
    });

    test('a cancelled pick persists nothing', () async {
      final settings = await withPrefs({});

      await settings.pickExportDir();

      expect(safAccessCalls, isEmpty);
    });
  });
}
