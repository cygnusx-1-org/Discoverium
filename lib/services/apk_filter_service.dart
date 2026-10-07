// APK file detection, filtering, and architecture selection.

import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';

// ========================================================================
// ApkFilterService — APK file detection, filtering, and arch-splitting.
// ========================================================================

class ApkFilterService {
  static const List<String> apkContainerExtensions = [
    '.apk',
    '.xapk',
    '.apkm',
    '.apks',
  ];

  static const List<String> archiveExtensions = ['.zip'];

  static const List<String> tarballExtensions = [
    '.tar.gz',
    '.tgz',
    '.tar.bz2',
    '.tar.xz',
  ];

  static bool isApkOrContainerFile(
    String name, {
    bool includeArchives = false,
    bool includeTarballs = false,
  }) {
    final lower = name.toLowerCase();
    bool endsWithAny(List<String> exts) => exts.any(lower.endsWith);
    return endsWithAny(apkContainerExtensions) ||
        (includeArchives && endsWithAny(archiveExtensions)) ||
        (includeTarballs && endsWithAny(tarballExtensions));
  }

  /// Separates the URLs of a split APK set stored in a single `apkUrls` value
  /// (base first, splits after). A newline cannot appear in a legal URL, so it
  /// cannot collide with real URLs.
  static const String multiApkUrlSeparator = '\n';

  static List<String> splitMultiApkUrl(String value) {
    if (value.isEmpty) return [];
    return value.contains(multiApkUrlSeparator)
        ? value.split(multiApkUrlSeparator).where((e) => e.isNotEmpty).toList()
        : [value];
  }

  static String joinMultiApkUrl(Iterable<String> urls) =>
      urls.join(multiApkUrlSeparator);

  List<MapEntry<String, String>> getApkUrlsFromUrls(List<String> urls) =>
      urls.map((e) {
        final segments = e.split('/').where((el) => el.trim().isNotEmpty);
        final apkSegs = segments.where((s) => isApkOrContainerFile(s));
        return MapEntry(apkSegs.isNotEmpty ? apkSegs.last : segments.last, e);
      }).toList();

  List<MapEntry<String, String>> filterApks(
    List<MapEntry<String, String>> apkUrls,
    String? apkFilterRegEx,
    bool? invert,
  ) {
    if (apkFilterRegEx?.isNotEmpty == true) {
      final reg = RegExp(apkFilterRegEx!);
      apkUrls = apkUrls.where((element) {
        final hasMatch = reg.hasMatch(element.key);
        return invert == true ? !hasMatch : hasMatch;
      }).toList();
    }
    return apkUrls;
  }

  /// How APK filenames spell each device ABI (see #3249). Each pattern must
  /// match a whole word of the name, so `x86` is not found in `x86_64`, nor
  /// `arm` in `arm64`.
  static const Map<String, String> _abiNamePatterns = {
    'arm64-v8a': r'arm[-_]?64(?:[-_]?v8a?)?|aarch[-_]?64|arm[-_]?v8a?|v8a',
    'armeabi-v7a':
        r'armeabi[-_]?v7a?|arm[-_]?v7(?:a|l|hf)?|arm[-_]?32(?:[-_]?v7a?)?'
        r'|arm7|armhf|v7a|arm(?![-_]?(?:v\d|\d))',
    'armeabi': r'armeabi(?![-_]?v7)',
    'x86_64': r'x86[-_]?64|x64|amd64',
    'x86': r'x86(?![-_]?64)|i[3-6]86',
    'riscv64': r'riscv[-_]?64',
  };

  static final Map<String, RegExp> _abiNameRegExps = {
    for (final abi in _abiNamePatterns.entries) abi.key: _wholeWord(abi.value),
  };

  /// A fat APK, built for every ABI.
  static final RegExp _universalName = _wholeWord('universal|noarch');

  static RegExp _wholeWord(String pattern) =>
      RegExp('(?<![a-z0-9])(?:$pattern)(?![a-z0-9])');

  /// The ABIs an APK named [name] says it is built for: null when the name
  /// does not say, empty when it calls itself universal.
  static Set<String>? abisFromName(String name) {
    // `appArm64` is two words; lowercasing alone would run them together.
    final words = name
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]}-${m[2]}')
        .toLowerCase();
    final abis = {
      for (final abi in _abiNameRegExps.entries)
        if (abi.value.hasMatch(words)) abi.key,
    };
    if (abis.isNotEmpty) return abis;
    return _universalName.hasMatch(words) ? {} : null;
  }

  /// How well a build for [abis] suits a device whose ABIs are [deviceAbis],
  /// lower being better, or null when the device cannot run it.
  ///
  /// [abis] is null when unknown and empty when the build runs on any ABI.
  /// Either may hold the device's own ABI, so both rank between a build for
  /// that ABI and one for a secondary ABI: picking the 32-bit build on a
  /// 64-bit device just because the 64-bit one is not labelled is worse.
  static int? _abiRank(Set<String>? abis, List<String> deviceAbis) {
    if (abis == null || abis.isEmpty) return 1;
    final best = deviceAbis.indexWhere(abis.contains);
    if (best < 0) return null;
    return best == 0 ? 0 : best + 1;
  }

  /// [candidates] less the builds a device whose ABIs are [deviceAbis] cannot
  /// run, or all of them when it could run none. [abisOf] gives a candidate's
  /// ABIs: null when unknown, empty when it runs on any.
  static List<T> runnableByAbi<T>(
    List<T> candidates,
    Set<String>? Function(T) abisOf,
    List<String> deviceAbis,
  ) {
    if (deviceAbis.isEmpty) return candidates;
    final runnable = candidates
        .where((c) => _abiRank(abisOf(c), deviceAbis) != null)
        .toList();
    return runnable.isEmpty ? candidates : runnable;
  }

  /// The builds of [suggested], a source's suggested builds, that are in
  /// [runnable] (as [runnableByAbi] left it). When there are none, the builds
  /// of the same version in [runnable] stand in for them: a source's one
  /// suggested build of a version is often another ABI's. With none of those
  /// either, [suggested] is returned as is.
  static List<T> runnableSuggestion<T>(
    List<T> suggested,
    List<T> runnable,
    Object? Function(T) versionOf,
  ) {
    final runnableSuggested = suggested.where(runnable.contains).toList();
    if (suggested.isEmpty || runnableSuggested.isNotEmpty) {
      return runnableSuggested;
    }
    final version = versionOf(suggested.first);
    final sameVersion = runnable.where((b) => versionOf(b) == version).toList();
    return sameVersion.isNotEmpty ? sameVersion : suggested;
  }

  /// The members of [candidates] best suited to a device whose ABIs are
  /// [deviceAbis], in their original order. [abisOf] gives a candidate's ABIs:
  /// null when unknown, empty when it runs on any.
  ///
  /// Builds for the most preferred ABI win, and of those only the most
  /// specific (fewest ABIs); builds the device cannot run never do. When
  /// nothing tells the candidates apart they are all returned.
  static List<T> selectByAbi<T>(
    List<T> candidates,
    Set<String>? Function(T) abisOf,
    List<String> deviceAbis,
  ) {
    if (candidates.length < 2) return candidates;
    final runnable = runnableByAbi(candidates, abisOf, deviceAbis);
    final ranks = [for (final c in runnable) _abiRank(abisOf(c), deviceAbis)];
    if (ranks.contains(null)) return candidates;
    final best = ranks.cast<int>().reduce(min);
    var chosen = [
      for (var i = 0; i < runnable.length; i++)
        if (ranks[i] == best) runnable[i],
    ];
    if (best != 1) {
      final fewest = chosen.map((c) => abisOf(c)!.length).reduce(min);
      chosen = chosen.where((c) => abisOf(c)!.length == fewest).toList();
    }
    return chosen;
  }

  /// The words of an APK's name less its version numbers, which change from
  /// one release to the next while the rest of the name stays.
  static Set<String> apkNameWords(String name) => {
    for (final word in name.toLowerCase().split(RegExp('[^a-z0-9]+')))
      if (word.isNotEmpty && !RegExp(r'^v?\d+$').hasMatch(word)) word,
  };

  /// The index in [apkUrls] of the one APK named like [chosenName], with the
  /// same words but for version numbers: the same kind of APK a user picked
  /// from an earlier release's (an F-Droid flavour, say). Null when none or
  /// several are, which leaves the choice to the user again.
  static int? indexOfApkNamedLike(
    List<MapEntry<String, String>> apkUrls,
    String? chosenName,
  ) {
    if (chosenName == null) return null;
    final chosen = apkNameWords(chosenName);
    int? found;
    for (var i = 0; i < apkUrls.length; i++) {
      final words = apkNameWords(apkUrls[i].key);
      if (words.length == chosen.length && words.containsAll(chosen)) {
        if (found != null) return null;
        found = i;
      }
    }
    return found;
  }

  Future<List<MapEntry<String, String>>> filterApksByArch(
    List<MapEntry<String, String>> apkUrls,
    List<String> abis,
  ) async => selectByAbi(apkUrls, (e) => abisFromName(e.key), abis);

  /// Reading more APKs than this to tell them apart costs more than picking
  /// one by hand.
  static const int maxApksToRead = 6;

  /// [apkUrls] narrowed to the builds best suited to a device whose ABIs are
  /// [deviceAbis], with the ABIs read from inside APKs along the way, by URL.
  ///
  /// Names settle it when they can. Only when the choice they leave turns on
  /// an APK whose name does not say are those APKs read, with [readAbis],
  /// unless [known] has them from an earlier check. An APK [readAbis] cannot
  /// read (null) stays unknown.
  static Future<
    ({
      List<MapEntry<String, String>> apkUrls,
      Map<String, List<String>> apkAbis,
    })
  >
  selectApksByAbi(
    List<MapEntry<String, String>> apkUrls,
    List<String> deviceAbis, {
    Map<String, List<String>> known = const {},
    Future<Set<String>?> Function(MapEntry<String, String> apk)? readAbis,
  }) async {
    Set<String>? named(MapEntry<String, String> apk) => abisFromName(apk.key);
    final byName = selectByAbi(apkUrls, named, deviceAbis);
    final unnamed = apkUrls.where((apk) => named(apk) == null).toList();
    if (readAbis == null ||
        apkUrls.length < 2 ||
        !byName.any((apk) => named(apk) == null) ||
        unnamed.length > maxApksToRead) {
      return (apkUrls: byName, apkAbis: const <String, List<String>>{});
    }
    final read = <String, List<String>>{};
    await Future.wait(
      unnamed.map((apk) async {
        final abis = known[apk.value] ?? (await readAbis(apk))?.toList();
        if (abis != null) read[apk.value] = [...abis]..sort();
      }),
    );
    return (
      apkUrls: selectByAbi(
        apkUrls,
        (apk) => named(apk) ?? read[apk.value]?.toSet(),
        deviceAbis,
      ),
      apkAbis: read,
    );
  }
}

/// Delegates to [ApkFilterService.getApkUrlsFromUrls].
List<MapEntry<String, String>> getApkUrlsFromUrls(List<String> urls) =>
    ApkFilterService().getApkUrlsFromUrls(urls);

/// Delegates to [ApkFilterService.splitMultiApkUrl].
List<String> splitMultiApkUrl(String value) =>
    ApkFilterService.splitMultiApkUrl(value);

/// Delegates to [ApkFilterService.joinMultiApkUrl].
String joinMultiApkUrl(Iterable<String> urls) =>
    ApkFilterService.joinMultiApkUrl(urls);

/// The ABIs this device runs, most preferred first.
Future<List<String>> getDeviceAbis() async =>
    (await DeviceInfoPlugin().androidInfo).supportedAbis;

/// Delegates to [ApkFilterService.filterApksByArch].
Future<List<MapEntry<String, String>>> filterApksByArch(
  List<MapEntry<String, String>> apkUrls,
) async => ApkFilterService().filterApksByArch(apkUrls, await getDeviceAbis());

/// Delegates to [ApkFilterService.filterApks].
List<MapEntry<String, String>> filterApks(
  List<MapEntry<String, String>> apkUrls,
  String? apkFilterRegEx,
  bool? invert,
) => ApkFilterService().filterApks(apkUrls, apkFilterRegEx, invert);
