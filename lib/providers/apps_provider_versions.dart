import 'dart:io';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apk_version.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// [app] with its latest APK version settled without reading an APK, or null
/// when its preferred APK has to be read.
///
/// An app with no APK to read (track-only, or none found) has no latest APK
/// version. Otherwise [previous]'s reading carries over when it was taken from
/// an APK of the same name for the same release. The name is the key rather
/// than the URL because some sources sign their download links afresh on every
/// check, which would otherwise read the same APK again each time.
App? latestApkVersionWithoutReading(App app, {App? previous}) {
  if (app.settings.getBool('trackOnly') ||
      app.apkUrls.isEmpty ||
      app.apkUrls.first.value == 'placeholder') {
    return app.copyWith(
      latestVersionCode: null,
      latestVersionName: null,
      latestVersionApkName: null,
    );
  }
  final apkName = _preferredApk(app).key;
  if (previous != null &&
      previous.latestVersionCode != null &&
      previous.latestVersionName != null &&
      previous.latestVersionApkName == apkName &&
      previous.latestVersion == app.latestVersion) {
    return app.copyWith(
      latestVersionCode: previous.latestVersionCode,
      latestVersionName: previous.latestVersionName,
      latestVersionApkName: apkName,
    );
  }
  return null;
}

/// The APK [app] would install: its preferred one, clamped as downloadApp
/// clamps it.
MapEntry<String, String> _preferredApk(App app) =>
    app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];

/// Reads the version of the APK each app would install, for [AppsProvider].
extension AppsProviderVersions on AppsProvider {
  /// Returns [app] with [App.latestVersionCode] and [App.latestVersionName] set
  /// from the manifest of the APK it would install: its preferred APK.
  ///
  /// The manifest is read over byte ranges where the server serves them, and
  /// otherwise from a full download, which stays in the download cache so
  /// installing the APK later does not fetch it again. Nothing is read when
  /// [latestApkVersionWithoutReading] can settle it from [previous], the app as
  /// it was before this check.
  Future<App> resolveLatestApkVersion(App app, {App? previous}) async {
    final settled = latestApkVersionWithoutReading(app, previous: previous);
    if (settled != null) return settled;
    final target = app.copyWith(
      preferredApkIndex: app.preferredApkIndex.clamp(0, app.apkUrls.length - 1),
    );
    final version =
        await _readApkVersionOverRanges(target) ??
        await _readApkVersionFromDownload(target);
    return app.copyWith(
      latestVersionCode: version.versionCode,
      latestVersionName: version.versionName,
      latestVersionApkName: _preferredApk(app).key,
    );
  }

  /// [resolveLatestApkVersion] for an app being added, which is not held up by
  /// it: an APK that cannot be read now is read by the next update check.
  Future<App> resolveLatestApkVersionIfPossible(App app) async {
    try {
      return await resolveLatestApkVersion(app);
    } catch (e) {
      AppLogger.warn('Could not read the latest APK version of ${app.id}: $e');
      return app;
    }
  }

  /// The version [app]'s preferred APK declares, read over byte ranges. Null
  /// when the server does not serve ranges or the APK cannot be read that way.
  Future<ApkVersion?> _readApkVersionOverRanges(App app) async {
    final bytes = await openAppApkOverRanges(
      SourceProvider().getSource(app.url, overrideSource: app.overrideSource),
      app.url,
      app.apkUrls[app.preferredApkIndex],
      app.additionalSettings,
      settingsProvider,
    );
    if (bytes == null) return null;
    final ApkVersion? version;
    try {
      version = await readApkVersion(bytes);
    } on ApkRangeReadUnavailable {
      return null;
    }
    // An APK for another package is an ID change, which the download path
    // vets, so it is left to that.
    if (version == null || (version.packageName != app.id && !isTempId(app))) {
      return null;
    }
    return version;
  }

  /// The version [app]'s preferred APK declares, read from a full download.
  Future<ApkVersion> _readApkVersionFromDownload(App app) async {
    final saved = apps[app.id]?.app;
    try {
      final artifact = await downloadApp(app, null);
      if (artifact is DownloadedApk) {
        final info = await packageManager.getPackageArchiveInfo(
          archiveFilePath: artifact.file.path,
        );
        if (info != null) return _apkVersionOf(info);
      } else if (artifact is DownloadedDir) {
        try {
          final apks =
              artifact.extracted
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => f.path.toLowerCase().endsWith('.apk'))
                  .toList()
                ..sort((a, b) => _baseApkFirst(a, b, artifact.appId));
          for (final apk in apks) {
            final info = await packageManager.getPackageArchiveInfo(
              archiveFilePath: apk.path,
            );
            if (info != null) return _apkVersionOf(info);
          }
        } finally {
          // Installing extracts the bundle again, so nothing is lost here.
          if (artifact.extracted.existsSync()) {
            await artifact.extracted.delete(recursive: true);
          }
        }
      }
      throw ObtainiumError(tr('badDownload'))..url = app.url;
    } finally {
      // downloadApp records the app it is given as the app in memory. Here that
      // is this check's unfinished result, which must not replace the saved
      // app: a check that fails saves whatever app is in memory.
      final entry = apps[app.id];
      if (saved != null && entry != null && identical(entry.app, app)) {
        entry.app = saved;
      }
    }
  }
}

ApkVersion _apkVersionOf(PackageInfo info) => ApkVersion(
  info.versionCode ?? 0,
  versionNameOrCode(info.versionName, info.versionCode),
  packageName: info.packageName,
);

/// Orders a bundle's base APK, named for its package, ahead of its splits.
int _baseApkFirst(File a, File b, String appId) {
  bool isBase(File f) => f.uri.pathSegments.last.startsWith(appId);
  return (isBase(b) ? 1 : 0) - (isBase(a) ? 1 : 0);
}
