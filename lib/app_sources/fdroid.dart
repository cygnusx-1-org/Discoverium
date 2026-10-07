import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:html/parser.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class FDroid extends AppSource {
  static const _maxChangeLogCodeUnits = 2048;
  static const String _fdroidDataBaseUrl =
      'https://gitlab.com/fdroid/fdroiddata/-/raw/master/metadata';
  @override
  String get name => tr('fdroid');

  FDroid() {
    hosts = ['f-droid.org'];
    canSearch = true;
    inferAppIdFromUrlPath = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormTextField(
        'filterVersionsByRegEx',
        label: tr('filterVersionsByRegEx'),
        required: false,
        additionalValidators: [
          (value) {
            return regExValidator(value);
          },
        ],
      ),
    ],
    [
      GeneratedFormSwitch(
        'trySelectingSuggestedVersionCode',
        label: tr('trySelectingSuggestedVersionCode'),
        value: true,
      ),
    ],
    [
      GeneratedFormSwitch(
        'autoSelectHighestVersionCode',
        label: tr('autoSelectHighestVersionCode'),
      ),
    ],
  ];

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    final RegExp standardUrlRegExB = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}/+[^/]+/+packages/+[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegExB.firstMatch(url);
    if (match != null) {
      url =
          'https://${Uri.parse(match.group(0)!).host}/packages/${Uri.parse(url).pathSegments.where((s) => s.trim().isNotEmpty).last}';
    }
    final RegExp standardUrlRegExA = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}/+packages/+[^/]+',
      caseSensitive: false,
    );
    match = standardUrlRegExA.firstMatch(url);
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final String? appId = await tryInferringAppId(standardUrl);
      if (appId == null) {
        throw NoReleasesError();
      }
      final String host = Uri.parse(standardUrl).host;
      final res = await sourceRequest(
        'https://$host/api/v1/packages/$appId',
        additionalSettings,
      );
      final nativecodes = _hasSeveralBuildsOfAVersion(res)
          ? await _fetchNativecodes(host, appId, additionalSettings)
          : null;
      var details = getAPKUrlsFromFDroidPackagesAPIResponse(
        res,
        'https://$host/repo/$appId',
        standardUrl,
        name,
        additionalSettings: additionalSettings,
        nativecodes: nativecodes,
        deviceAbis: nativecodes == null ? const [] : await getDeviceAbis(),
      );
      if (!hostChanged) {
        try {
          final res = await sourceRequest(
            '$_fdroidDataBaseUrl/$appId.yml',
            additionalSettings,
          );
          final lines = res.body.split('\n');
          final authorLines = lines.where((l) => l.startsWith('AuthorName: '));
          if (authorLines.isNotEmpty) {
            details = details.copyWith(
              names: details.names.copyWith(
                author: authorLines.first.split(': ').sublist(1).join(': '),
              ),
            );
          }
          final changelogUrls = lines
              .where((l) => l.startsWith('Changelog: '))
              .map((e) => e.split(' ').sublist(1).join(' '));
          if (changelogUrls.isNotEmpty) {
            details = details.copyWith(changeLog: changelogUrls.first);
            bool isGitHub = false;
            bool isGitLab = false;
            try {
              GitHub(
                hostChanged: true,
              ).sourceSpecificStandardizeURL(details.changeLog!);
              isGitHub = true;
            } on InvalidURLError {
              // URL does not match GitHub format, silently skipped
            }
            try {
              GitLab(
                hostChanged: true,
              ).sourceSpecificStandardizeURL(details.changeLog!);
              isGitLab = true;
            } on InvalidURLError {
              // URL does not match GitLab format, silently skipped
            }
            if ((isGitHub || isGitLab) &&
                (details.changeLog?.indexOf('/blob/') ?? -1) >= 0) {
              details = details.copyWith(
                changeLog: (await sourceRequest(
                  details.changeLog!.replaceFirst('/blob/', '/raw/'),
                  additionalSettings,
                )).body,
              );
            }
          }
        } catch (e) {
          AppLogger.info(
            'Failed to process changelog for F-Droid app: ${e.toString()}',
          );
        }
        if ((details.changeLog?.length ?? 0) > _maxChangeLogCodeUnits) {
          final cl = details.changeLog!;
          var end = _maxChangeLogCodeUnits;
          if (end > 0 &&
              cl.codeUnitAt(end - 1) >= 0xD800 &&
              cl.codeUnitAt(end - 1) <= 0xDBFF) {
            end--;
          }
          details = details.copyWith(changeLog: '${cl.substring(0, end)}...');
        }
      }
      return details;
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final Response res = await sourceRequest(
      'https://search.${hosts[0]}/?q=${Uri.encodeQueryComponent(query)}',
      {},
    );
    if (res.statusCode == 200) {
      final Map<String, List<String>> urlsWithDescriptions = {};
      parse(res.body).querySelectorAll('.package-header').forEach((e) {
        String? url = e.attributes['href'];
        if (url != null) {
          try {
            // Keep the canonical form so search results match stored app URLs
            // and duplicate detection works.
            url = standardizeUrl(url);
          } catch (e) {
            url = null;
          }
        }
        if (url != null) {
          urlsWithDescriptions[url] = [
            e.querySelector('.package-name')?.text.trim() ?? '',
            e.querySelector('.package-summary')?.text.trim() ??
                tr('noDescription'),
          ];
        }
      });
      return urlsWithDescriptions;
    } else {
      throw getObtainiumHttpError(res);
    }
  }

  /// Whether the packages API lists more than one build of some version, as
  /// it does for an app built separately for each ABI.
  bool _hasSeveralBuildsOfAVersion(Response res) {
    try {
      final packages = jsonDecode(res.body)['packages'] as List<dynamic>;
      final versionNames = packages.map((p) => p['versionName']).toList();
      return versionNames.toSet().length < versionNames.length;
    } catch (e) {
      return false;
    }
  }

  /// The native code of each build on the app's page, by versionCode, or null
  /// when the page cannot be read.
  Future<Map<int, List<String>>?> _fetchNativecodes(
    String host,
    String appId,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final res = await sourceRequest(
        'https://$host/packages/$appId/',
        additionalSettings,
      );
      if (res.statusCode != 200) return null;
      final nativecodes = parseNativecodes(res.body);
      return nativecodes.isEmpty ? null : nativecodes;
    } catch (e) {
      AppLogger.debug('Could not read the native code of $appId: $e');
      return null;
    }
  }

  /// The ABIs each build listed on an F-Droid app page is for, by versionCode:
  /// empty for a build with no native code, which runs on any ABI.
  ///
  /// The packages API leaves this out, so without it the builds of a version
  /// for different ABIs differ only in a versionCode that follows no standard
  /// — and F-Droid's suggested one is often for x86_64 (#13).
  static Map<int, List<String>> parseNativecodes(String html) {
    final nativecodes = <int, List<String>>{};
    for (final build in parse(html).querySelectorAll('.package-version')) {
      // The header reads "Version 26.0.0 (26000004)".
      final versionCode = RegExp(r'\((\d+)\)')
          .allMatches(
            build.querySelector('.package-version-header')?.text ?? '',
          )
          .map((m) => int.tryParse(m[1]!))
          .lastOrNull;
      if (versionCode == null) continue;
      nativecodes[versionCode] = [
        for (final code in build.querySelectorAll('.package-nativecode'))
          if (code.text.trim().isNotEmpty) code.text.trim(),
      ];
    }
    return nativecodes;
  }

  /// [nativecodes] gives the ABIs of the builds it knows, by versionCode, for
  /// telling the builds of one version apart on a device whose ABIs are
  /// [deviceAbis].
  APKDetails getAPKUrlsFromFDroidPackagesAPIResponse(
    Response res,
    String apkUrlPrefix,
    String standardUrl,
    String sourceName, {
    Map<String, dynamic> additionalSettings = const {},
    Map<int, List<String>>? nativecodes,
    List<String> deviceAbis = const [],
  }) {
    final autoSelectHighestVersionCode =
        additionalSettings['autoSelectHighestVersionCode'] == true;
    final trySelectingSuggestedVersionCode =
        additionalSettings['trySelectingSuggestedVersionCode'] == true;
    final filterVersionsByRegEx =
        (additionalSettings['filterVersionsByRegEx'] as String?)?.isNotEmpty ==
            true
        ? additionalSettings['filterVersionsByRegEx']
        : null;
    final apkFilterRegEx =
        (additionalSettings['apkFilterRegEx'] as String?)?.isNotEmpty == true
        ? additionalSettings['apkFilterRegEx']
        : null;
    if (res.statusCode == 200) {
      final response = jsonDecode(res.body);
      List<dynamic> releases = response is Map
          ? (response['packages'] ?? [])
          : [];
      if (apkFilterRegEx != null) {
        releases = releases.where((rel) {
          final String apk = '${apkUrlPrefix}_${rel['versionCode']}.apk';
          return filterApks(
            [MapEntry(apk, apk)],
            apkFilterRegEx,
            false,
          ).isNotEmpty;
        }).toList();
      }
      if (releases.isEmpty) {
        throw NoReleasesError();
      }
      Set<String>? abisOf(dynamic release) =>
          nativecodes?[int.tryParse('${release['versionCode']}')]?.toSet();
      // Builds this device cannot run are never offered while it can run
      // some.
      final allReleases = releases;
      releases = ApkFilterService.runnableByAbi(releases, abisOf, deviceAbis);
      String? version;
      Iterable<dynamic> releaseChoices = [];
      // Grab the versionCode suggested if the user chose to do that
      // Only do so at this stage if the user has no release filter
      if (trySelectingSuggestedVersionCode &&
          response['suggestedVersionCode'] != null &&
          filterVersionsByRegEx == null) {
        final suggestedReleases = allReleases.where(
          (element) =>
              element['versionCode'] == response['suggestedVersionCode'],
        );
        if (suggestedReleases.isNotEmpty) {
          version = suggestedReleases.first['versionName'];
          releaseChoices = ApkFilterService.runnableSuggestion(
            suggestedReleases.toList(),
            releases,
            (release) => release['versionName'],
          );
        }
      }
      // Apply the release filter if any
      if (filterVersionsByRegEx?.isNotEmpty == true) {
        version = null;
        releaseChoices = [];
        final versionFilter = RegExp(filterVersionsByRegEx!);
        for (var i = 0; i < releases.length; i++) {
          if (versionFilter.hasMatch(releases[i]['versionName'])) {
            version = releases[i]['versionName'];
            break;
          }
        }
        if (version == null || version.isEmpty) {
          throw NoVersionError();
        }
      }
      // Default to the highest version
      version ??= releases[0]['versionName'];
      if (version == null || version.isEmpty) {
        throw NoVersionError();
      }
      // If a suggested release was not already picked, pick all those with the selected version
      if (releaseChoices.isEmpty) {
        releaseChoices = releases.where(
          (element) => element['versionName'] == version,
        );
      }
      if (additionalSettings['autoApkFilterByArch'] == true) {
        releaseChoices = ApkFilterService.selectByAbi(
          releaseChoices.toList(),
          abisOf,
          deviceAbis,
        );
      }
      // For the remaining releases, use the toggles to auto-select one if possible
      if (releaseChoices.length > 1) {
        if (autoSelectHighestVersionCode) {
          releaseChoices = [releaseChoices.first];
        } else if (trySelectingSuggestedVersionCode &&
            response['suggestedVersionCode'] != null) {
          final suggestedReleases = releaseChoices.where(
            (element) =>
                element['versionCode'] == response['suggestedVersionCode'],
          );
          if (suggestedReleases.isNotEmpty) {
            releaseChoices = suggestedReleases;
          }
        }
      }
      if (releaseChoices.isEmpty) {
        throw NoReleasesError();
      }
      final List<String> apkUrls = releaseChoices
          .map((e) => '${apkUrlPrefix}_${e['versionCode']}.apk')
          .toList();
      return APKDetails(
        version,
        getApkUrlsFromUrls(apkUrls.toSet().toList()),
        AppNames(sourceName, Uri.parse(standardUrl).pathSegments.last),
      );
    } else {
      throw getObtainiumHttpError(res);
    }
  }
}
