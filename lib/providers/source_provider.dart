// ========================================================================
// SourceProvider — resolves URLs to AppSource instances and builds Apps.
//
// App sources, models, and services live in their own libraries. This file
// re-exports them so existing `import source_provider.dart` call sites keep
// resolving the same names.
// ========================================================================

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';

import 'package:obtainium/app_sources/apk4free.dart';
import 'package:obtainium/app_sources/apkcombo.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/apkpure.dart';
import 'package:obtainium/app_sources/app_source.dart';
import 'package:obtainium/app_sources/aptoide.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/coolapk.dart';
import 'package:obtainium/app_sources/direct_apk_link.dart';
import 'package:obtainium/app_sources/farsroid.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/githubstars.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/app_sources/huaweiappgallery.dart';
import 'package:obtainium/app_sources/itchio.dart';
import 'package:obtainium/app_sources/izzyondroid.dart';
import 'package:obtainium/app_sources/jenkins.dart';
import 'package:obtainium/app_sources/liteapks.dart';
import 'package:obtainium/app_sources/neutroncode.dart';
import 'package:obtainium/app_sources/rockmods.dart';
import 'package:obtainium/app_sources/rustore.dart';
import 'package:obtainium/app_sources/samsunggalaxystore.dart';
import 'package:obtainium/app_sources/sourceforge.dart';
import 'package:obtainium/app_sources/sourcehut.dart';
import 'package:obtainium/app_sources/telegramapp.dart';
import 'package:obtainium/app_sources/tencent.dart';
import 'package:obtainium/app_sources/uptodown.dart';
import 'package:obtainium/app_sources/vivoappstore.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apk_version.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/utils/format_utils.dart';
import 'package:obtainium/services/apk_filter_service.dart';
import 'package:obtainium/services/version_service.dart';
import 'package:obtainium/utils/min_update_age.dart';
import 'package:obtainium/utils/url_utils.dart';

export 'package:obtainium/app_sources/app_source.dart';
export 'package:obtainium/models/app.dart';
export 'package:obtainium/models/typed_settings.dart';
export 'package:obtainium/services/apk_filter_service.dart';
export 'package:obtainium/services/http_service.dart';
export 'package:obtainium/services/version_service.dart';
export 'package:obtainium/utils/string_utils.dart' show getSourceRegex;
export 'package:obtainium/utils/url_utils.dart' show preStandardizeUrl;

const int kDefaultFetchConcurrency = 4;

// ========================================================================
// SourceProvider — singleton that manages available AppSource instances,
// URL-to-source resolution, and app construction from URLs.
// ========================================================================

class SourceProvider {
  static final SourceProvider _instance = SourceProvider._();
  factory SourceProvider() => _instance;
  SourceProvider._();

  // Factories for every source, in auto-detection order: sources with hosts
  // are matched by host, then hostless sources are tried in order. HTML is the
  // catch-all fallback and must stay last. Adding a source means adding one
  // entry here.
  static final List<AppSource Function()> _sourceFactories = [
    () => GitHub(),
    () => GitLab(),
    () => Codeberg(),
    () => FDroid(),
    () => FDroidRepo(),
    () => IzzyOnDroid(),
    () => SourceHut(),
    () => APKPure(),
    () => Aptoide(),
    () => Uptodown(),
    () => ItchIO(),
    () => HuaweiAppGallery(),
    () => Tencent(),
    () => VivoAppStore(),
    () => RuStore(),
    () => Farsroid(),
    () => SamsungGalaxyStore(),
    () => LiteAPKs(),
    () => Apk4Free(),
    () => CoolApk(),
    () => SourceForge(),
    () => Jenkins(),
    () => APKMirror(),
    () => APKCombo(),
    () => RockMods(),
    () => TelegramApp(),
    () => NeutronCode(),
    () => DirectAPKLink(),
    // HTML must stay last: hostless sources are tried in order and HTML is the
    // catch-all fallback.
    () => HTML(),
  ];

  /// Cached, read-only source list built lazily from [_sourceFactories].
  /// Because sources are immutable after construction, the cache is safe.
  static List<AppSource>? _cachedSources;
  List<AppSource> get sources =>
      _cachedSources ??= _sourceFactories.map((f) => f()).toList();

  /// Factory lookup by persisted source identifier.
  static Map<String, AppSource Function()>? _sourceFactoriesById;
  static Map<String, AppSource Function()> get _sourceFactoriesByIdCache =>
      _sourceFactoriesById ??= {
        for (final factory in _sourceFactories)
          factory().sourceIdentifier: factory,
      };

  /// Add mass URL source classes here so they are available via the service.
  List<MassAppUrlSource> massUrlSources = [GitHubStars()];

  AppSource getSource(String url, {String? overrideSource}) {
    url = preStandardizeUrl(url);
    if (overrideSource != null) {
      final factory = _sourceFactoriesByIdCache[overrideSource];
      if (factory == null) {
        throw UnsupportedURLError()..url = url;
      }
      // The override path mutates the chosen source's host config, so use a
      // throwaway instance rather than touching the shared cache.
      final res = factory();
      final originalHosts = res.hosts;
      final newHost = Uri.parse(url).host;
      res.hosts = [newHost];
      res.hostChanged = true;
      if (originalHosts.contains(newHost)) {
        res.hostIdenticalDespiteAnyChange = true;
      }
      return res;
    }
    // The non-override path is read-only, so reuse the cached source set.
    final allSources = sources;
    AppSource? source;
    for (var s in allSources.where((element) => element.hosts.isNotEmpty)) {
      // A non-match here is expected control flow during source auto-detection,
      // so failures are intentionally not logged (they are just noise).
      if (s.matchesHost(Uri.parse(url).host)) {
        source = s;
        break;
      }
    }
    if (source == null) {
      for (var s in allSources.where(
        (element) => element.hosts.isEmpty && !element.neverAutoSelect,
      )) {
        // As above, hostless sources are tried in order until one accepts the
        // URL; a rejection is normal and must not be logged as an error.
        try {
          s.sourceSpecificStandardizeURL(url, forSelection: true);
          source = s;
          break;
        } on ObtainiumError {
          // Ignore and try the next source.
        }
      }
    }
    if (source == null) {
      throw UnsupportedURLError()..url = url;
    }
    return source;
  }

  String generateTempID(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) => sha256
      .convert(utf8.encode(standardUrl + additionalSettings.toString()))
      .toString()
      .substring(0, 12);

  Future<String> _resolveAppId(
    AppSource source,
    App? currentApp,
    Map<String, dynamic> additionalSettings,
    bool trackOnly,
    String standardUrl,
    bool inferAppIdIfOptional,
  ) async {
    if (currentApp?.id != null) return currentApp!.id;
    final explicitId = additionalSettings['appId'] as String?;
    if (explicitId != null && explicitId.trim().isNotEmpty) return explicitId;
    if ((!trackOnly || source.inferAppIdEvenWhenTrackOnly) &&
        (!source.appIdInferIsOptional ||
            (source.appIdInferIsOptional && inferAppIdIfOptional))) {
      final inferred = await source.tryInferringAppId(
        standardUrl,
        additionalSettings: additionalSettings,
      );
      if (inferred != null) return inferred;
    }
    return generateTempID(standardUrl, additionalSettings);
  }

  Future<App> getApp(
    AppSource source,
    String url,
    Map<String, dynamic> additionalSettings, {
    App? currentApp,
    bool trackOnlyOverride = false,
    bool sourceIsOverriden = false,
    bool inferAppIdIfOptional = false,
  }) async {
    additionalSettings = Map<String, dynamic>.from(additionalSettings);
    if (trackOnlyOverride || source.enforceTrackOnly) {
      additionalSettings['trackOnly'] = true;
    }
    final trackOnly = additionalSettings['trackOnly'] == true;
    final String standardUrl;
    try {
      standardUrl = source.standardizeUrl(url);
    } on ObtainiumError catch (e) {
      throw e..withUrlContext(url);
    }
    APKDetails apk;
    try {
      apk = await source.getLatestAPKDetails(standardUrl, additionalSettings);
    } on ObtainiumError catch (e) {
      throw e..withUrlContext(standardUrl);
    }

    // Adding an app must honor the minimum update age too. Sources that can
    // look back already return an older eligible release, so this only blocks
    // sources whose latest release is too young and has no older alternative.
    if (currentApp == null && !trackOnly) {
      final minAgeDays = await effectiveMinUpdateAgeDays(additionalSettings);
      if (isReleaseTooYoung(apk.releaseDate, minAgeDays)) {
        throw MinUpdateAgeError(apk.releaseDate!, minAgeDays)
          ..url = standardUrl;
      }
    }

    if (!source.suppressStandardVersionExtraction) {
      final String? extractedVersion = extractVersion(
        additionalSettings['versionExtractionRegEx'] as String?,
        additionalSettings['matchGroupToUse'] as String?,
        apk.version,
      );
      if (extractedVersion != null) {
        apk = apk.copyWith(version: extractedVersion);
      }
    }

    if (additionalSettings['releaseDateAsVersion'] == true &&
        apk.releaseDate != null) {
      apk = apk.copyWith(
        version: apk.releaseDate!.microsecondsSinceEpoch.toString(),
      );
    }
    final settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    apk = apk.copyWith(
      apkUrls: filterApks(
        apk.apkUrls,
        additionalSettings['apkFilterRegEx'] ??
            settingsProvider.globalApkFilterRegEx,
        additionalSettings['invertAPKFilter'],
      ),
    );
    if (apk.apkUrls.isEmpty && !trackOnly) {
      throw NoAPKError()..url = standardUrl;
    }
    var apkAbis = const <String, List<String>>{};
    if (additionalSettings['autoApkFilterByArch'] == true) {
      final selection = await ApkFilterService.selectApksByAbi(
        apk.apkUrls,
        await getDeviceAbis(),
        known: currentApp?.apkAbis ?? const {},
        readAbis: trackOnly
            ? null
            : (apkUrl) => _readApkAbis(
                source,
                standardUrl,
                apkUrl,
                additionalSettings,
                settingsProvider,
              ),
      );
      apk = apk.copyWith(apkUrls: selection.apkUrls);
      apkAbis = selection.apkAbis;
      if (apk.apkUrls.isEmpty && !trackOnly) {
        throw NoAPKError()..url = standardUrl;
      }
    }
    var name = currentApp != null ? currentApp.name.trim() : '';
    name = name.isNotEmpty ? name : apk.names.name;
    final App finalApp = App(
      id: await _resolveAppId(
        source,
        currentApp,
        additionalSettings,
        trackOnly,
        standardUrl,
        inferAppIdIfOptional,
      ),
      url: standardUrl,
      author: apk.names.author,
      name: name,
      installedVersion: currentApp?.installedVersion,
      latestVersion: apk.version,
      apkUrls: apk.apkUrls,
      preferredApkIndex:
          currentApp?.preferredApkIndex ??
          (apk.apkUrls.isNotEmpty ? apk.apkUrls.length - 1 : 0),
      preferredApkName: currentApp?.preferredApkName,
      apkAbis: apkAbis,
      additionalSettings: additionalSettings,
      lastUpdateCheck: DateTime.now(),
      pinned: currentApp?.pinned ?? false,
      categories: currentApp?.categories ?? const [],
      releaseDate: apk.releaseDate,
      changeLog: apk.changeLog,
      recentReleases: apk.recentReleases,
      releaseUrl: apk.releaseUrl,
      overrideSource: sourceIsOverriden
          ? source.sourceIdentifier
          : currentApp?.overrideSource,
      allowIdChange:
          currentApp?.allowIdChange ??
          trackOnly || (source.appIdInferIsOptional && inferAppIdIfOptional),
      otherAssetUrls: apk.allAssetUrls
          .where((a) => apk.apkUrls.indexWhere((p) => a.key == p.key) < 0)
          .toList(),
    );
    return source.postProcessApp(finalApp);
  }

  /// The ABIs read from inside [apk] of the app at [appUrl], or null when it
  /// cannot be read; filtering by architecture then goes on without it.
  Future<Set<String>?> _readApkAbis(
    AppSource source,
    String appUrl,
    MapEntry<String, String> apk,
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) async {
    try {
      final bytes = await openAppApkOverRanges(
        source,
        appUrl,
        apk,
        additionalSettings,
        settingsProvider,
      );
      return bytes == null ? null : await readApkAbis(bytes);
    } catch (e) {
      AppLogger.debug('Could not read the ABIs of ${apk.key}: $e');
      return null;
    }
  }

  // Returns errors in [results, errors] instead of throwing them
  Future<List<dynamic>> getAppsByURLNaive(
    List<String> urls, {
    Set<String> alreadyAddedUrls = const {},
    AppSource? sourceOverride,
  }) async {
    final List<App> apps = [];
    final Map<String, dynamic> errors = {};
    const concurrency = kDefaultFetchConcurrency;
    for (var i = 0; i < urls.length; i += concurrency) {
      final end = i + concurrency > urls.length ? urls.length : i + concurrency;
      final batch = urls.sublist(i, end);
      final results = await Future.wait(
        batch.map((url) async {
          try {
            if (alreadyAddedUrls.contains(url)) {
              throw ObtainiumError('${tr('appAlreadyAdded')} ($url)');
            }
            final source = sourceOverride ?? getSource(url);
            return await getApp(
              source,
              url,
              sourceIsOverriden: sourceOverride != null,
              getDefaultValuesFromFormItems(
                source.combinedAppSpecificSettingFormItems,
              ),
            );
          } catch (e) {
            return e;
          }
        }),
      );
      for (var j = 0; j < batch.length; j++) {
        final result = results[j];
        if (result is App) {
          apps.add(result);
        } else {
          errors[batch[j]] = result;
        }
      }
    }
    return [apps, errors];
  }
}

// ========================================================================
// Discoverium: minimum-update-age hold
// ========================================================================

/// Options (in hours) for the minimum-age-for-updates setting. Zero disables
/// the delay; the empty string means "use the global default" for per-app
/// overrides.
const List<int> minimumUpdateAgeHourOptions = [0, 4, 8, 12, 24, 48, 96];

/// The minimum update age applied when the user has not chosen one: no delay.
const int defaultMinimumUpdateAgeHours = 0;

/// The offered option nearest [hours] without going under it, capped at the
/// largest. Rounding up is deliberate: the day-granularity options this list
/// replaced were finer at the top end, and a delay chosen for supply-chain
/// safety should never be silently shortened when it is converted.
int snapToMinimumUpdateAgeOption(int hours) =>
    minimumUpdateAgeHourOptions.firstWhere(
      (option) => option >= hours,
      orElse: () => minimumUpdateAgeHourOptions.last,
    );

/// The option-label spec for a minimum-age value, resolved by [formOptLabel]
/// (which both the settings page and the generated per-app form go through).
String minimumUpdateAgeOptLabel(int hours) => hours == 0
    ? 'none'
    : hours % 24 == 0
    ? 'day:${hours ~/ 24}'
    : 'hour:$hours';

/// The rendered label for a minimum-age value: "None", "4 hours", "2 days".
String minimumUpdateAgeLabel(int hours) =>
    formOptLabel(minimumUpdateAgeOptLabel(hours));

/// The minimum age a release must reach before [app] will offer it, taking the
/// app's own override when it has one and the global setting otherwise.
Duration minimumUpdateAgeFor(App app, SettingsProvider settingsProvider) {
  final raw = app.additionalSettings['minimumUpdateAgeHours'];
  final hours = raw is String && raw.isNotEmpty
      ? int.tryParse(raw) ?? settingsProvider.minimumUpdateAgeHours
      : settingsProvider.minimumUpdateAgeHours;
  return Duration(hours: hours < 0 ? 0 : hours);
}

/// The moment [app]'s withheld release becomes offerable, or null when nothing
/// is being held.
///
/// Derived from the stored release date rather than a stored deadline so that
/// lowering the setting releases the hold immediately instead of at the next
/// update check.
DateTime? appHeldUntil(App app, SettingsProvider settingsProvider) {
  final heldReleaseDate = app.heldReleaseDate;
  if (app.heldVersion == null || heldReleaseDate == null) return null;
  final minimumAge = minimumUpdateAgeFor(app, settingsProvider);
  if (minimumAge <= Duration.zero) return null;
  final until = heldReleaseDate.add(minimumAge);
  return until.isAfter(DateTime.now()) ? until : null;
}

// ========================================================================
// Discoverium: version comparison (see issue #59)
// ========================================================================

/// Compares two version strings semantically.
///
/// Returns a negative number if [v1] < [v2], zero if equal, positive if
/// [v1] > [v2]. Falls back to string comparison when neither string contains a
/// numeric version core.
int compareVersions(String v1, String v2) {
  if (v1 == v2) return 0;
  return _compareVersionCores(v1, v2) ?? v1.compareTo(v2);
}

/// Orders two version strings by their leading numeric core (e.g. "1.4.0" from
/// "v1.4.0-beta+3"), or null when either string has no core that can be ordered
/// numerically.
///
/// Null means "these two cannot be ordered", which is not the same as "equal":
/// callers that act on the ordering must not substitute a lexicographic one,
/// because sorting two arbitrary strings says nothing about which came first.
int? _compareVersionCores(String v1, String v2) {
  final m1 = _versionCore.firstMatch(v1);
  final m2 = _versionCore.firstMatch(v2);
  if (m1 == null || m2 == null) {
    return null;
  }
  final parts1 = _numericVersionParts(m1.group(0)!);
  final parts2 = _numericVersionParts(m2.group(0)!);
  if (parts1 == null || parts2 == null) {
    // A segment wider than a 64-bit int cannot be ordered numerically; give up
    // rather than letting int.parse throw out of a widget build.
    return null;
  }
  final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;
  for (var i = 0; i < maxLen; i++) {
    final p1 = i < parts1.length ? parts1[i] : 0;
    final p2 = i < parts2.length ? parts2[i] : 0;
    if (p1 != p2) return p1.compareTo(p2);
  }
  return 0;
}

/// Splits a dotted numeric version core into integers, or null if any segment
/// is too wide for a 64-bit int.
List<int>? _numericVersionParts(String core) {
  final parts = <int>[];
  for (final segment in core.split('.')) {
    final value = int.tryParse(segment);
    if (value == null) return null;
    parts.add(value);
  }
  return parts;
}

/// Whether two version strings name the same release.
///
/// Only a leading "v" before a digit is discounted — the one piece of
/// decoration that is pure spelling, and the difference between a GitHub tag
/// ("v1.26") and the version the OS reports for the very same build ("1.26").
/// Everything else is significant: "2.1.0-rc1" and "2.1.0-rc2" stay distinct.
bool sameVersionLabel(String a, String b) =>
    _stripVersionPrefix(a) == _stripVersionPrefix(b);

String _stripVersionPrefix(String version) {
  final trimmed = version.trim();
  return trimmed.length > 1 &&
          (trimmed[0] == 'v' || trimmed[0] == 'V') &&
          _leadingDigit.hasMatch(trimmed[1])
      ? trimmed.substring(1)
      : trimmed;
}

final RegExp _leadingDigit = RegExp(r'[0-9]');

/// A git short hash at the end of a versionName ("12.10.1-dec46b0"). It names
/// the commit a build came from, not a version, so like the ":Eclipse" in
/// "1.18.1:Eclipse" it plays no part in comparing versions. Only a dash and
/// exactly seven lowercase hex digits count; any other suffix is kept.
final RegExp _trailingGitHash = RegExp(r'-[0-9a-f]{7}$');

/// [versionName] without a trailing git short hash.
String withoutGitHash(String versionName) =>
    versionName.replaceFirst(_trailingGitHash, '');

/// The version a build is shown and compared by: its versionName, or its
/// versionCode when it declares no versionName.
String versionNameOrCode(String? versionName, int? versionCode) =>
    versionName ?? versionCode?.toString() ?? '';

/// Whether the build [latestCode]/[latestName] is newer than the installed
/// build [installedCode]/[installedName].
///
/// versionCode decides first: Android orders builds by it, and a higher one is
/// strictly newer. It does not have to change between releases, so only when
/// the two are equal does the versionName decide, with any trailing git hash
/// ignored. There is no further rule — two hashes cannot be ordered, and a
/// different one is not assumed to be newer.
bool apkVersionIsNewer({
  required int installedCode,
  required String installedName,
  required int latestCode,
  required String latestName,
}) {
  if (latestCode != installedCode) return latestCode > installedCode;
  return versionNameIsNewer(
    withoutGitHash(installedName),
    withoutGitHash(latestName),
  );
}

/// Whether versionName [latest] is newer than [installed].
///
/// Ordering is by the leading numeric core, then by what follows it (see
/// [sameCoreIsNewer]). Names with no orderable core are not newer: a pair that
/// cannot be ordered is no evidence of an update.
bool versionNameIsNewer(String installed, String latest) {
  if (sameVersionLabel(installed, latest)) return false;
  final ordering = _compareVersionCores(installed, latest);
  if (ordering == null) return false;
  if (ordering != 0) return ordering < 0;
  return sameCoreIsNewer(installed, latest);
}

/// A pre-release marker: what follows it belongs BEFORE the release naming
/// that core. Anchored to a separator so a commit hash or an architecture
/// ("1.0.0-arch64") is not read as an "rc".
final RegExp _preReleaseMarker = RegExp(
  r'(?:^|[-_+.])(alpha|beta|rc|pre|dev|snapshot|nightly)',
  caseSensitive: false,
);

final RegExp _versionCore = RegExp(r'\d+(?:\.\d+)*');

/// Everything after a version's leading numeric core ("-rc1", "-4-9f3c-dirty",
/// ":Eclipse"), or the empty string when the core is the whole version.
String _versionRemainder(String version) {
  final trimmed = version.trim();
  final match = _versionCore.firstMatch(trimmed);
  return match == null ? trimmed : trimmed.substring(match.end);
}

/// Whether [latest] is a newer release than [installed] when the two share a
/// numeric core, which makes everything after that core the deciding part.
///
/// A pre-release marker sits before the release ("2.1.0-rc1" precedes
/// "2.1.0"). Anything else after the core is build metadata — a git-describe
/// suffix, a build number, a flavour name — and marks a build at or after that
/// release, so "1.0.2-4-9f3c-dirty" is not behind "1.0.2" and "1.18.1:Eclipse"
/// is not behind "v1.18.1".
bool sameCoreIsNewer(String installed, String latest) {
  final installedRest = _versionRemainder(installed);
  final latestRest = _versionRemainder(latest);
  final installedIsPre = _preReleaseMarker.hasMatch(installedRest);
  final latestIsPre = _preReleaseMarker.hasMatch(latestRest);
  // One is a pre-release of this core and the other is not: the pre-release is
  // the older of the two, whichever side it is on.
  if (installedIsPre != latestIsPre) return installedIsPre;
  // Both pre-releases of the same core ("rc1" vs "rc2"): any difference is a
  // new one, since their ordering is not something this can know.
  if (installedIsPre) return installedRest != latestRest;
  // Neither is a pre-release. Only the bare release moving to a decorated one
  // is an update; the reverse is the installed build already being ahead.
  return installedRest.isEmpty && latestRest.isNotEmpty;
}

/// The installed and latest APK versions of [app], or null when they cannot be
/// compared: nothing is installed, the APK has not been read yet, or the app is
/// track-only and has no APK.
({int installedCode, String installedName, int latestCode, String latestName})?
_apkVersions(App app) {
  final installedName = app.installedVersion;
  final installedCode = app.installedVersionCode;
  final latestName = app.latestVersionName;
  final latestCode = app.latestVersionCode;
  if (app.settings.getBool('trackOnly') ||
      installedName == null ||
      installedCode == null ||
      latestName == null ||
      latestCode == null) {
    return null;
  }
  return (
    installedCode: installedCode,
    installedName: installedName,
    latestCode: latestCode,
    latestName: latestName,
  );
}

/// Whether [app] has an update: the APK it would install is newer than the
/// installed build, going only by the versions the two declare (see
/// [apkVersionIsNewer]). The release's tag or title plays no part.
bool appHasUpdate(App app) {
  final versions = _apkVersions(app);
  return versions != null &&
      apkVersionIsNewer(
        installedCode: versions.installedCode,
        installedName: versions.installedName,
        latestCode: versions.latestCode,
        latestName: versions.latestName,
      );
}

/// Whether the APK [after] would install declares a different version from the
/// one [before] would.
bool latestApkVersionChanged(App before, App after) =>
    before.latestVersionCode != after.latestVersionCode ||
    before.latestVersionName != after.latestVersionName;

/// Whether an update should be offered for [app], honouring the user's
/// `hideDowngrades` preference.
///
/// With the preference on (the default) this is [appHasUpdate]. With it off,
/// any APK whose version differs from the installed build's is offered,
/// downgrades included, which is the only thing that switch can mean. A git
/// hash that differs on its own is still not a different version.
bool appHasOfferableUpdate(App app, SettingsProvider settingsProvider) {
  if (settingsProvider.hideDowngrades) return appHasUpdate(app);
  final versions = _apkVersions(app);
  return versions != null &&
      (versions.latestCode != versions.installedCode ||
          !sameVersionLabel(
            withoutGitHash(versions.installedName),
            withoutGitHash(versions.latestName),
          ));
}
