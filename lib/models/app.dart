// Core app data models shared by providers, sources, and UI.

import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/models/typed_settings.dart';

// ------------------------------------------------------------------------
// AppNames
// ------------------------------------------------------------------------

class AppNames {
  final String author;
  final String name;

  const AppNames(this.author, this.name);

  AppNames copyWith({String? author, String? name}) {
    return AppNames(author ?? this.author, name ?? this.name);
  }
}

// ------------------------------------------------------------------------
// APKDetails
// ------------------------------------------------------------------------

/// One release's notes, kept with the app so the detail page can show them
/// without a request. The update check already downloads the release list, so
/// these come free with it.
class ReleaseNotes {
  final String version;
  final String? notes;

  const ReleaseNotes(this.version, this.notes);

  factory ReleaseNotes.fromJson(Map<String, dynamic> json) =>
      ReleaseNotes(json['version'] as String, json['notes'] as String?);

  Map<String, dynamic> toJson() => {'version': version, 'notes': notes};
}

class APKDetails {
  final String version;
  final List<MapEntry<String, String>> apkUrls;
  final AppNames names;
  final DateTime? releaseDate;
  final String? changeLog;
  final String? releaseUrl;
  final List<MapEntry<String, String>> allAssetUrls;

  /// The newest few releases with their notes, newest first, so the detail
  /// page can render neighbouring versions without asking the network.
  final List<ReleaseNotes> recentReleases;

  const APKDetails(
    this.version,
    this.apkUrls,
    this.names, {
    this.releaseDate,
    this.changeLog,
    this.releaseUrl,
    this.allAssetUrls = const [],
    this.recentReleases = const [],
  });

  APKDetails copyWith({
    String? version,
    List<MapEntry<String, String>>? apkUrls,
    AppNames? names,
    Object? releaseDate = _sentinel,
    Object? changeLog = _sentinel,
    Object? releaseUrl = _sentinel,
    List<MapEntry<String, String>>? allAssetUrls,
    List<ReleaseNotes>? recentReleases,
  }) {
    return APKDetails(
      version ?? this.version,
      apkUrls ?? this.apkUrls,
      names ?? this.names,
      releaseDate: releaseDate == _sentinel
          ? this.releaseDate
          : releaseDate as DateTime?,
      changeLog: changeLog == _sentinel ? this.changeLog : changeLog as String?,
      releaseUrl: releaseUrl == _sentinel
          ? this.releaseUrl
          : releaseUrl as String?,
      allAssetUrls: allAssetUrls ?? this.allAssetUrls,
      recentReleases: recentReleases ?? this.recentReleases,
    );
  }
}

/// Converts a list of [MapEntry] pairs into a 2D list of strings for JSON encoding.
List<List<String>> stringMapListTo2DList(
  List<MapEntry<String, String>> mapList,
) => mapList.map((e) => [e.key, e.value]).toList();

/// Converts a 2D list (decoded from JSON) back into a list of [MapEntry] pairs.
List<MapEntry<String, String>> assumed2DlistToStringMapList(
  List<dynamic> arr,
) => arr.map((e) => MapEntry(e[0] as String, e[1] as String)).toList();

// ------------------------------------------------------------------------
// App
// ------------------------------------------------------------------------

class App {
  final String id;
  final String url;
  final String author;
  final String name;

  /// The installed build's versionName as the package manager reports it (its
  /// versionCode when it has none), or null when the app is not installed. A
  /// track-only app has no APK, so for it this is the release the user marked
  /// as installed instead.
  final String? installedVersion;

  /// The installed build's versionCode. Null when not installed or track-only.
  final int? installedVersionCode;

  /// The source's own name for its latest release: a tag, title or date. It
  /// identifies the release (for its notes, and to hold it back), but whether
  /// there is an update is decided only by the APK's version below.
  final String latestVersion;

  /// The versionCode and versionName declared in the manifest of the APK this
  /// app would install. Null until that APK has been read, and for track-only
  /// apps, which have no APK.
  final int? latestVersionCode;
  final String? latestVersionName;

  /// The name of the APK [latestVersionCode] and [latestVersionName] were read
  /// from, so the same APK of an unchanged release is not read again.
  final String? latestVersionApkName;

  final List<MapEntry<String, String>> apkUrls;
  final List<MapEntry<String, String>> otherAssetUrls;
  final int preferredApkIndex;

  /// The name of the APK the user last picked from several, so that a later
  /// release's APK named like it is picked without asking. Null until then.
  /// It only stands in for asking while [rememberedApkName] gives it.
  final String? preferredApkName;

  /// The ABIs read from inside the latest release's APKs whose names do not
  /// say, by URL (empty for an APK with no native code), so the update check
  /// does not read the same APKs again to filter them by architecture.
  final Map<String, List<String>> apkAbis;
  final Map<String, dynamic> additionalSettings;
  final DateTime? lastUpdateCheck;
  final bool pinned;
  final List<String> categories;
  final DateTime? releaseDate;
  final String? changeLog;

  /// The newer release the minimum-update-age hold is currently withholding,
  /// and the date it was published. Null whenever nothing is being held.
  ///
  /// Everything else on the record describes the release actually being
  /// offered, so these two are the only trace of the one waiting behind it.
  final String? heldVersion;
  final DateTime? heldReleaseDate;

  /// Notes for the newest few releases, newest first, cached by the update
  /// check so the detail page usually needs no request at all.
  final List<ReleaseNotes> recentReleases;
  final String? releaseUrl;
  final String? overrideSource;
  final bool allowIdChange;
  final String? pendingRepoRenameUrl;

  const App({
    required this.id,
    required this.url,
    required this.author,
    required this.name,
    this.installedVersion,
    this.installedVersionCode,
    required this.latestVersion,
    this.latestVersionCode,
    this.latestVersionName,
    this.latestVersionApkName,
    this.apkUrls = const [],
    this.otherAssetUrls = const [],
    required this.preferredApkIndex,
    this.preferredApkName,
    this.apkAbis = const {},
    required this.additionalSettings,
    this.lastUpdateCheck,
    this.pinned = false,
    this.categories = const [],
    this.releaseDate,
    this.changeLog,
    this.heldVersion,
    this.heldReleaseDate,
    this.recentReleases = const [],
    this.releaseUrl,
    this.overrideSource,
    this.allowIdChange = false,
    this.pendingRepoRenameUrl,
  });

  @override
  String toString() {
    return 'ID: $id URL: $url INSTALLED: $installedVersion LATEST: $latestVersion APK: $apkUrls PREFERREDAPK: $preferredApkIndex ADDITIONALSETTINGS: ${additionalSettings.toString()} LASTCHECK: ${lastUpdateCheck.toString()} PINNED $pinned';
  }

  bool get hasPendingRepoRename =>
      pendingRepoRenameUrl != null && pendingRepoRenameUrl!.isNotEmpty;

  String? get overrideName {
    final n = settings.getStringOrNull('appName');
    return n != null && n.trim().isNotEmpty ? n : null;
  }

  String get finalName {
    return overrideName ?? name;
  }

  String? get overrideAuthor {
    final a = settings.getStringOrNull('appAuthor');
    return a != null && a.trim().isNotEmpty ? a : null;
  }

  String get finalAuthor {
    return overrideAuthor ?? author;
  }

  /// [preferredApkName] while the app is set to remember the APK picked from
  /// several, and null while it is set to ask every time.
  String? get rememberedApkName =>
      settings.getBool('rememberChosenApk', defaultValue: true)
      ? preferredApkName
      : null;

  /// Type-safe accessor for [additionalSettings].
  TypedSettings get settings => TypedSettings(additionalSettings);

  App copyWith({
    String? id,
    String? url,
    String? author,
    String? name,
    Object? installedVersion = _sentinel,
    Object? installedVersionCode = _sentinel,
    String? latestVersion,
    Object? latestVersionCode = _sentinel,
    Object? latestVersionName = _sentinel,
    Object? latestVersionApkName = _sentinel,
    List<MapEntry<String, String>>? apkUrls,
    List<MapEntry<String, String>>? otherAssetUrls,
    int? preferredApkIndex,
    Object? preferredApkName = _sentinel,
    Map<String, List<String>>? apkAbis,
    Map<String, dynamic>? additionalSettings,
    Object? lastUpdateCheck = _sentinel,
    bool? pinned,
    List<String>? categories,
    Object? releaseDate = _sentinel,
    Object? changeLog = _sentinel,
    Object? heldVersion = _sentinel,
    Object? heldReleaseDate = _sentinel,
    List<ReleaseNotes>? recentReleases,
    Object? releaseUrl = _sentinel,
    Object? overrideSource = _sentinel,
    bool? allowIdChange,
    Object? pendingRepoRenameUrl = _sentinel,
  }) {
    return App(
      id: id ?? this.id,
      url: url ?? this.url,
      author: author ?? this.author,
      name: name ?? this.name,
      installedVersion: installedVersion == _sentinel
          ? this.installedVersion
          : installedVersion as String?,
      installedVersionCode: installedVersionCode == _sentinel
          ? this.installedVersionCode
          : installedVersionCode as int?,
      latestVersion: latestVersion ?? this.latestVersion,
      latestVersionCode: latestVersionCode == _sentinel
          ? this.latestVersionCode
          : latestVersionCode as int?,
      latestVersionName: latestVersionName == _sentinel
          ? this.latestVersionName
          : latestVersionName as String?,
      latestVersionApkName: latestVersionApkName == _sentinel
          ? this.latestVersionApkName
          : latestVersionApkName as String?,
      apkUrls: apkUrls ?? List<MapEntry<String, String>>.from(this.apkUrls),
      otherAssetUrls:
          otherAssetUrls ??
          List<MapEntry<String, String>>.from(this.otherAssetUrls),
      preferredApkIndex: preferredApkIndex ?? this.preferredApkIndex,
      preferredApkName: preferredApkName == _sentinel
          ? this.preferredApkName
          : preferredApkName as String?,
      apkAbis: apkAbis ?? this.apkAbis,
      additionalSettings:
          additionalSettings ??
          Map<String, dynamic>.from(this.additionalSettings),
      lastUpdateCheck: lastUpdateCheck == _sentinel
          ? this.lastUpdateCheck
          : lastUpdateCheck as DateTime?,
      pinned: pinned ?? this.pinned,
      categories: categories ?? List<String>.from(this.categories),
      releaseDate: releaseDate == _sentinel
          ? this.releaseDate
          : releaseDate as DateTime?,
      changeLog: changeLog == _sentinel ? this.changeLog : changeLog as String?,
      heldVersion: heldVersion == _sentinel
          ? this.heldVersion
          : heldVersion as String?,
      heldReleaseDate: heldReleaseDate == _sentinel
          ? this.heldReleaseDate
          : heldReleaseDate as DateTime?,
      recentReleases: recentReleases ?? this.recentReleases,
      releaseUrl: releaseUrl == _sentinel
          ? this.releaseUrl
          : releaseUrl as String?,
      overrideSource: overrideSource == _sentinel
          ? this.overrideSource
          : overrideSource as String?,
      allowIdChange: allowIdChange ?? this.allowIdChange,
      pendingRepoRenameUrl: pendingRepoRenameUrl == _sentinel
          ? this.pendingRepoRenameUrl
          : pendingRepoRenameUrl as String?,
    );
  }

  /// Parses [json] in the current schema. Callers loading persisted app data
  /// should use `appFromStoredJson` (see `app_json_migration.dart`), which
  /// applies the legacy-schema migrations first.
  factory App.fromJson(Map<String, dynamic> json) {
    try {
      return App(
        id: json['id'] as String,
        url: json['url'] as String,
        author: json['author'] as String,
        name: json['name'] as String,
        installedVersion: json['installedVersion'] == null
            ? null
            : json['installedVersion'] as String,
        installedVersionCode: json['installedVersionCode'] as int?,
        latestVersion: (json['latestVersion'] ?? tr('unknown')) as String,
        latestVersionCode: json['latestVersionCode'] as int?,
        latestVersionName: json['latestVersionName'] as String?,
        latestVersionApkName: json['latestVersionApkName'] as String?,
        apkUrls: assumed2DlistToStringMapList(
          jsonDecode((json['apkUrls'] ?? '[["placeholder", "placeholder"]]')),
        ),
        preferredApkIndex: (json['preferredApkIndex'] ?? -1) as int,
        preferredApkName: json['preferredApkName'] as String?,
        apkAbis: json['apkAbis'] == null
            ? const {}
            : (json['apkAbis'] as Map<String, dynamic>).map(
                (url, abis) => MapEntry(url, List<String>.from(abis as List)),
              ),
        additionalSettings:
            jsonDecode(json['additionalSettings']) as Map<String, dynamic>,
        lastUpdateCheck: json['lastUpdateCheck'] == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(json['lastUpdateCheck']),
        pinned: json['pinned'] ?? false,
        categories: json['categories'] != null
            ? (json['categories'] as List<dynamic>)
                  .map((e) => e.toString())
                  .toList()
            : json['category'] != null
            ? [json['category'] as String]
            : [],
        releaseDate: json['releaseDate'] == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(json['releaseDate']),
        changeLog: json['changeLog'] == null
            ? null
            : json['changeLog'] as String,
        heldVersion: json['heldVersion'] as String?,
        heldReleaseDate: json['heldReleaseDate'] == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(json['heldReleaseDate']),
        recentReleases: json['recentReleases'] == null
            ? const []
            : (jsonDecode(json['recentReleases']) as List<dynamic>)
                  .map((e) => ReleaseNotes.fromJson(e as Map<String, dynamic>))
                  .toList(),
        releaseUrl: json['releaseUrl'] as String?,
        overrideSource: json['overrideSource'],
        allowIdChange: json['allowIdChange'] ?? false,
        otherAssetUrls: assumed2DlistToStringMapList(
          jsonDecode((json['otherAssetUrls'] ?? '[]')),
        ),
        pendingRepoRenameUrl: json['pendingRepoRenameUrl'] as String?,
      );
    } on TypeError catch (e) {
      AppLogger.error(
        e,
        stackTrace: e.stackTrace,
        message: 'Type mismatch in App.fromJson',
      );
      rethrow;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'author': author,
    'name': name,
    'installedVersion': installedVersion,
    'installedVersionCode': installedVersionCode,
    'latestVersion': latestVersion,
    'latestVersionCode': latestVersionCode,
    'latestVersionName': latestVersionName,
    'latestVersionApkName': latestVersionApkName,
    'apkUrls': jsonEncode(stringMapListTo2DList(apkUrls)),
    'otherAssetUrls': jsonEncode(stringMapListTo2DList(otherAssetUrls)),
    'preferredApkIndex': preferredApkIndex,
    'preferredApkName': preferredApkName,
    'apkAbis': apkAbis,
    'additionalSettings': jsonEncode(additionalSettings),
    'lastUpdateCheck': lastUpdateCheck?.microsecondsSinceEpoch,
    'pinned': pinned,
    'categories': categories,
    'releaseDate': releaseDate?.microsecondsSinceEpoch,
    'changeLog': changeLog,
    'heldVersion': heldVersion,
    'heldReleaseDate': heldReleaseDate?.microsecondsSinceEpoch,
    'recentReleases': jsonEncode(
      recentReleases.map((e) => e.toJson()).toList(),
    ),
    'releaseUrl': releaseUrl,
    'overrideSource': overrideSource,
    'allowIdChange': allowIdChange,
    'pendingRepoRenameUrl': pendingRepoRenameUrl,
  };
}

/// Sentinel value used by [App.copyWith] to distinguish "not provided" from
/// an explicitly supplied `null` for nullable fields. Since [Object] uses
/// identity-based equality, a `const` sentinel guarantees it never collides
/// with any real value the caller could pass.
const _sentinel = Object();

/// Returns true if the app's ID is a temporary placeholder rather than a real
/// package name. Matches [generateTempID]'s sha256-hex prefix and legacy numeric
/// IDs; real package names contain a dot and never match.
bool isTempId(App app) {
  return RegExp(r'^[0-9]+$').hasMatch(app.id) ||
      RegExp(r'^[0-9a-f]{12}$').hasMatch(app.id);
}

/// Returns true when the app's installed version is a release label rather than
/// the OS's own version: a track-only app, which has no APK.
bool isVersionPseudo(App app) => app.settings.getBool('trackOnly');
