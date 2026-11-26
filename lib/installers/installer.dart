import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/app_sources/samsunggalaxystore.dart';

String installerPackageNameForApp(App app, {required bool googlePlayDefault}) {
  var isGalaxyStore = false;
  if (app.settings.getBool('shizukuPretendToBeGalaxyStore')) {
    try {
      isGalaxyStore =
          SourceProvider().getSource(
                app.url,
                overrideSource: app.overrideSource,
              )
              is SamsungGalaxyStore;
    } catch (_) {
      isGalaxyStore = false;
    }
  }
  if (isGalaxyStore) {
    return 'com.sec.android.app.samsungapps';
  }
  return googlePlayDefault ||
          app.settings.getBool('shizukuPretendToBeGooglePlay')
      ? 'com.android.vending'
      : '';
}

/// Android PackageInstaller status codes: 0 = success, 3 = cancelled / pending,
/// 4 = the system rejected the APK itself (unparseable, bad signature, a
/// downgrade).
const int _installSuccessCode = 0;
const int _installAlreadyPendingCode = 3;
const int _installInvalidCode = 4;

enum InstallOutcome { success, cancelled, error }

/// Unified result of an install operation, replacing the previous
/// "nullable int code" pattern used by the platform install APIs.
class InstallResult {
  final InstallOutcome outcome;
  final int? errorCode;

  /// Whether a failure says the downloaded file itself is unusable, so
  /// installing it again can only fail the same way. Every other failure (a
  /// signature conflict with the installed app, no space left, an incompatible
  /// device) leaves a good file behind that is worth keeping for a retry (#69).
  final bool fileIsInvalid;

  const InstallResult({
    required this.outcome,
    this.errorCode,
    this.fileIsInvalid = false,
  });

  factory InstallResult.success() =>
      const InstallResult(outcome: InstallOutcome.success);

  factory InstallResult.cancelled() =>
      const InstallResult(outcome: InstallOutcome.cancelled);

  /// A failure carrying a platform status [code]. [fileIsInvalid] defaults to
  /// what the PackageInstaller status says; an installer whose code is not one
  /// of those statuses states it explicitly.
  factory InstallResult.error(int code, {bool? fileIsInvalid}) => InstallResult(
    outcome: InstallOutcome.error,
    errorCode: code,
    fileIsInvalid: fileIsInvalid ?? code == _installInvalidCode,
  );

  /// Maps a raw platform install status code to an [InstallResult].
  /// [_installSuccessCode] is a completed install, [_installAlreadyPendingCode]
  /// is a pending/no-op (e.g. already installed), a null code is treated as
  /// cancelled, and any other value is an error carrying the original code.
  factory InstallResult.fromPlatformCode(int? code) {
    if (code == null) {
      return InstallResult.cancelled();
    }
    if (code == _installAlreadyPendingCode) {
      return InstallResult.cancelled();
    }
    if (code == _installSuccessCode) {
      return InstallResult.success();
    }
    return InstallResult.error(code);
  }

  bool get isSuccess => outcome == InstallOutcome.success;
  bool get isError => outcome == InstallOutcome.error;
}

/// Strategy that performs the platform-specific parts of an app installation.
///
/// Implementations are intentionally thin: the surrounding harness in
/// [AppsProvider] handles download validation, downgrade checks, the background
/// completion workaround, persistence, file cleanup, and notifications. An
/// installer only decides silent-install eligibility, manages its own
/// permissions, and performs the terminal platform call.
abstract class Installer {
  final SettingsProvider settingsProvider;

  Installer(this.settingsProvider);

  /// Unique key identifying this installer mode (e.g. 'stock', 'shizuku',
  /// 'external').
  String get modeKey;

  /// Whether directory/bundle installs should hand off the original container
  /// file (XAPK/ZIP/tarball) rather than extracted split APKs.
  bool get wantsContainerHandoff => false;

  /// The installer-specific portion of the silent-install decision. Shared
  /// pre-checks (background updates enabled, exemptions, multi-URL, target SDK)
  /// are handled by the caller before this is invoked.
  Future<bool> canInstallSilently(App app);

  /// Whether the installer currently has the privileges needed to install
  /// without prompting the user. Does not prompt.
  Future<bool> checkPermission();

  /// Ensures the installer has the privileges needed to install, prompting the
  /// user if necessary. Throws an [ObtainiumError] if permission is denied.
  Future<void> ensurePermission();

  /// Installs one or more APK file paths (a base APK plus optional splits).
  /// [installOptions] carries installer-specific key-value flags (e.g. Shizuku's
  /// `installerPackageName`).
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  });
}
