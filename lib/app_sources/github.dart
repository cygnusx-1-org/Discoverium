import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart';
import 'package:obtainium/utils/string_compare.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/discoverium_repo.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class GitHub extends AppSource {
  static const int _fallbackCacheSeconds = 3600;

  GitHub({bool hostChanged = false}) {
    name = 'GitHub';
    hosts = ['github.com'];
    appIdInferIsOptional = true;
    showReleaseDateAsVersionToggle = true;
    this.hostChanged = hostChanged;
    allowIncludeZips = true;
    allowIncludeTarballs = true;
    canSearch = true;
  }

  @override
  List<GeneratedFormItem> get sourceConfigSettingFormItems => [
    GeneratedFormTextField(
      'github-creds',
      label: tr('githubPATLabel'),
      password: true,
      required: false,
      helpUrl:
          'https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token',
    ),
    GeneratedFormTextField(
      'GHReqPrefix',
      label: tr('GHReqPrefix'),
      hint: 'gh-proxy.org',
      required: false,
      additionalValidators: [
        (value) {
          try {
            if (value != null && Uri.parse(value).scheme.isNotEmpty) {
              throw true;
            }
            if (value != null) {
              Uri.parse('https://$value/api.github.com');
            }
          } catch (e) {
            return tr('invalidInput');
          }
          return null;
        },
      ],
      helpUrl: 'https://github.com/sky22333/hubproxy',
    ),
    GeneratedFormSwitch(
      'checkRepoRename',
      label: tr('repoRenamedCheck'),
      value: false,
    ),
  ];

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormSwitch(
        'includePrereleases',
        label: tr('includePrereleases'),
        value: false,
      ),
    ],
    AppSource.fallbackToOlderReleasesFormItem,
    [
      GeneratedFormTextField(
        'filterReleaseTitlesByRegEx',
        label: tr('filterReleaseTitlesByRegEx'),
        required: false,
        additionalValidators: [
          (value) {
            return regExValidator(value);
          },
        ],
      ),
    ],
    [
      GeneratedFormTextField(
        'filterReleaseNotesByRegEx',
        label: tr('filterReleaseNotesByRegEx'),
        required: false,
        additionalValidators: [
          (value) {
            return regExValidator(value);
          },
        ],
      ),
    ],
    [GeneratedFormSwitch('verifyLatestTag', label: tr('verifyLatestTag'))],
    [
      GeneratedFormDropdown(
        'sortMethodChoice',
        [
          MapEntry('date', tr('releaseDate')),
          MapEntry('smartname', tr('smartname')),
          MapEntry('none', tr('none')),
          MapEntry(
            'smartname-datefallback',
            '${tr('smartname')} x ${tr('releaseDate')}',
          ),
          MapEntry('name', tr('name')),
        ],
        label: tr('sortMethod'),
        value: 'date',
      ),
    ],
    [
      GeneratedFormSwitch(
        'useLatestAssetDateAsReleaseDate',
        label: tr('useLatestAssetDateAsReleaseDate'),
        value: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'releaseTitleAsVersion',
        label: tr('releaseTitleAsVersion'),
        value: false,
      ),
    ],
  ];

  @override
  List<GeneratedFormItem> get searchQuerySettingFormItems => [
    GeneratedFormTextField(
      'minStarCount',
      label: tr('minStarCount'),
      value: '0',
      additionalValidators: [
        (value) {
          try {
            int.parse(value ?? '0');
          } catch (e) {
            return tr('invalidInput');
          }
          return null;
        },
      ],
    ),
  ];

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    // Discoverium's curated repo records the package ID directly, which saves
    // downloading an APK just to read it back out.
    final repoEntry = await DiscoveriumRepo.findByUrl(standardUrl);
    final repoAppId = repoEntry?.id;
    if (repoAppId != null && repoAppId.isNotEmpty) {
      return repoAppId;
    }

    const possibleBuildGradleLocations = [
      '/app/build.gradle',
      'android/app/build.gradle',
      'src/app/build.gradle',
    ];
    for (var path in possibleBuildGradleLocations) {
      try {
        final res = await sourceRequest(
          '${await convertStandardUrlToAPIUrl(standardUrl, additionalSettings)}/contents/$path',
          additionalSettings,
        );
        if (res.statusCode == 200) {
          try {
            final body = jsonDecode(res.body);
            final trimmedLines = utf8
                .decode(
                  base64.decode(
                    body['content'].toString().split('\n').join(''),
                  ),
                )
                .split('\n')
                .map((e) => e.trim());
            var appIds = trimmedLines.where(
              (l) =>
                  l.startsWith('applicationId "') ||
                  l.startsWith('applicationId \''),
            );
            appIds = appIds.map((appId) {
              final parts = appId.split(
                appId.startsWith('applicationId "') ? '"' : '\'',
              );
              return parts.length > 1 ? parts[1] : '';
            });
            appIds = appIds
                .map((appId) {
                  if (appId.startsWith('\${') && appId.endsWith('}')) {
                    final varLine = trimmedLines
                        .where(
                          (l) => l.startsWith(
                            'def ${appId.substring(2, appId.length - 1)}',
                          ),
                        )
                        .firstOrNull;
                    if (varLine == null) return '';
                    final parts = varLine.split(
                      varLine.contains('"') ? '"' : '\'',
                    );
                    appId = parts.length > 1 ? parts[1] : '';
                  }
                  return appId;
                })
                .where((appId) => appId.isNotEmpty);
            if (appIds.length == 1) {
              return appIds.first;
            }
          } catch (err) {
            AppLogger.info(
              'Error parsing build.gradle from ${res.request?.url.toString() ?? standardUrl}: ${err.toString()}',
            );
          }
        }
      } catch (err) {
        AppLogger.info(
          'Failed to extract ID from build.gradle or APK: ${err.toString()}',
        );
      }
    }
    return null;
  }

  @override
  String sourceSpecificStandardizeURL(
    String url, {
    bool forSelection = false,
  }) => standardizeUrlWithRegex(
    url,
    subdomainPrefix: r'(www\.)?',
    pathPattern: r'/[^/]+/[^/]+',
  );

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    // A request with skipAuth is retried without the configured token (e.g.
    // after the token was rejected for this repository); see #3211.
    final token = additionalSettings['skipAuth'] == true
        ? null
        : await getTokenIfAny(additionalSettings);
    final headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Token $token';
    }
    if (forAPKDownload == true) {
      headers[HttpHeaders.acceptHeader] = 'application/octet-stream';
    }
    if (headers.isNotEmpty) {
      return headers;
    } else {
      return null;
    }
  }

  Future<String?> getTokenIfAny(Map<String, dynamic> additionalSettings) async {
    final SettingsProvider settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    final sourceConfig = await getSourceConfigValues(
      additionalSettings,
      settingsProvider,
    );
    String? creds = sourceConfig['github-creds'];
    if ((additionalSettings['GHReqPrefix'] as String? ?? '').isNotEmpty) {
      creds = null;
    }
    if (creds != null) {
      final userNameEndIndex = creds.indexOf(':');
      if (userNameEndIndex > 0) {
        creds = creds.substring(
          userNameEndIndex + 1,
        ); // For old username-included token inputs
      }
      return creds;
    } else {
      return null;
    }
  }

  @override
  Future<String?> getSourceNote() async {
    if (!hostChanged && (await getTokenIfAny({})) == null) {
      return '${tr('githubSourceNote')} ${hostChanged ? tr('addInfoBelow') : tr('addInfoInSettings')}';
    }
    return null;
  }

  @override
  Future<String> generalReqPrefetchModifier(
    String reqUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    if ((additionalSettings['GHReqPrefix'] as String? ?? '').isNotEmpty) {
      final uri = Uri.parse(reqUrl);
      return 'https://${additionalSettings['GHReqPrefix']}/${uri.toString().substring('https://'.length)}';
    }
    return reqUrl;
  }

  Future<String> getAPIHost(Map<String, dynamic> additionalSettings) async =>
      'https://api.${hosts[0]}';

  /// Whether [res] is a 401/403 whose JSON body says the configured token is
  /// the problem (e.g. "Resource not accessible by personal access token").
  static bool _isAuthRejection(Response res) {
    if (res.statusCode != 401 && res.statusCode != 403) return false;
    try {
      final message = (jsonDecode(res.body)['message'] as String? ?? '')
          .toLowerCase();
      return message.contains('access token') ||
          message.contains('bad credentials');
    } catch (_) {
      return false;
    }
  }

  /// Runs [url] through [sourceRequest], retrying without the configured
  /// token when GitHub rejects the authenticated request (a token that is not
  /// authorized for this repository must not block updates of public repos).
  Future<Response> _sourceRequestWithAuthFallback(
    String url,
    Map<String, dynamic> additionalSettings,
  ) async {
    var res = await sourceRequest(url, additionalSettings);
    if (_isAuthRejection(res)) {
      AppLogger.info(
        'GitHub request for $url rejected due to token access, retrying without token.',
      );
      res = await sourceRequest(
        url,
        Map<String, dynamic>.from(additionalSettings)..['skipAuth'] = true,
      );
    }
    return res;
  }

  Future<String> convertStandardUrlToAPIUrl(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async =>
      '${await getAPIHost(additionalSettings)}/repos${standardUrl.substring('https://${hosts[0]}'.length)}';

  /// Checks if the repository has been renamed or transferred.
  ///
  /// This method explicitly disables automatic redirect following to detect when
  /// GitHub returns a redirect (indicating the repository has moved). A redirect
  /// from the GitHub API for a repository endpoint definitively indicates that
  /// the repository has been renamed or transferred to a different owner.
  ///
  /// Throws [RepositoryRenamedError] if a redirect is detected.
  Future<void> checkForRepositoryRename(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    Map<String, String> sourceConfigSettingValues,
  ) async {
    if (sourceConfigSettingValues['checkRepoRename'] != 'true') {
      return;
    }
    final uri = Uri.tryParse(standardUrl);
    final host = uri?.host.toLowerCase() ?? '';
    // Guard against non-GitHub URLs
    if (host != hosts[0] && host != 'www.${hosts[0]}') {
      return;
    }
    final apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    final Response res = await sourceRequest(
      apiUrl,
      additionalSettings,
      followRedirects: false,
    );
    if (res.statusCode >= 300 && res.statusCode < 400) {
      final String? location =
          res.headers[HttpHeaders.locationHeader.toLowerCase()];
      if (location != null) {
        final Response res2 = await sourceRequest(
          location,
          additionalSettings,
          followRedirects: false,
        );
        String? newUrl;
        try {
          newUrl = jsonDecode(res2.body)['html_url'];
        } catch (e) {
          AppLogger.info(
            'Failed to parse redirect response for repo rename: ${e.toString()}',
          );
        }
        if (newUrl != null) {
          throw RepositoryRenamedError(standardUrl, newUrl);
        }
      }
    }
  }

  @override
  String? changeLogPageFromStandardUrl(String standardUrl) =>
      '$standardUrl/releases';

  List<dynamic> _findReleaseAssetUrls(
    dynamic release,
    bool includeZips,
    bool includeTarballs,
    Map<String, String> sourceConfigSettingValues,
  ) =>
      (release['assets'] as List<dynamic>?)?.map((e) {
        final name = e['name'].toString();
        var url =
            !AppSource.isApkOrContainerFile(
              name,
              includeArchives: includeZips,
              includeTarballs: includeTarballs,
            )
            ? (e['browser_download_url'] ?? e['url'])
            : (e['url'] ?? e['browser_download_url']);
        url = undoGHProxyMod(url, sourceConfigSettingValues);
        e['final_url'] = (e['name'] != null) && (url != null)
            ? MapEntry(e['name'] as String, url as String)
            : const MapEntry('', '');
        return e;
      }).toList() ??
      [];

  DateTime? _getPublishDateFromRelease(dynamic rel) {
    final pub = rel?['published_at'];
    if (pub is String) return DateTime.tryParse(pub);
    final commitCreated = rel?['commit']?['created'];
    if (commitCreated is String) return DateTime.tryParse(commitCreated);
    return null;
  }

  DateTime? _getNewestAssetDateFromRelease(dynamic rel) {
    final allAssets = rel['assets'] as List<dynamic>?;
    final filteredAssets = rel['filteredAssets'] as List<dynamic>?;
    final t = (filteredAssets ?? allAssets)
        ?.map((e) {
          final updated = e?['updated_at'];
          return updated is String ? DateTime.tryParse(updated) : null;
        })
        .where((e) => e != null)
        .toList();
    t?.sort((a, b) => b!.compareTo(a!));
    if (t?.isNotEmpty == true) {
      return t!.first;
    }
    return null;
  }

  DateTime? _getReleaseDateFromRelease(dynamic rel, bool useAssetDate) =>
      !useAssetDate
      ? _getPublishDateFromRelease(rel)
      : _getNewestAssetDateFromRelease(rel);

  void _sortGitHubReleases(
    List<dynamic> releases,
    String sortMethod,
    bool useLatestAssetDateAsReleaseDate,
  ) {
    if (sortMethod == 'none') return;

    // Precompute dates and (for smartname/name sorts) per-release format
    // sets once. Memoization in findStandardFormatsForVersion already handles
    // the per-version cache; we still precompute here so the sort comparator
    // only performs O(1) lookups instead of O(n) per comparison.
    final isDateOnly = sortMethod == 'date';
    final Map<dynamic, DateTime?> dates = {};
    final Map<dynamic, Set<String>> formats = {};
    if (!isDateOnly) {
      for (final r in releases) {
        if (r == null) continue;
        final name = (r['tag_name'] ?? r['name'])?.toString() ?? '';
        formats[r] = findStandardFormatsForVersion(name, false);
      }
    }

    releases.sort((a, b) {
      if (a == null) return -1;
      if (b == null) return 1;

      if (isDateOnly) {
        final dateA = dates.putIfAbsent(
          a,
          () => _getReleaseDateFromRelease(a, useLatestAssetDateAsReleaseDate),
        );
        final dateB = dates.putIfAbsent(
          b,
          () => _getReleaseDateFromRelease(b, useLatestAssetDateAsReleaseDate),
        );
        return (dateA ?? DateTime(0)).compareTo(dateB ?? DateTime(0));
      }

      final nameA = a['tag_name'] ?? a['name'];
      final nameB = b['tag_name'] ?? b['name'];
      final stdFormats = formats[a]!.intersection(formats[b]!);

      if (sortMethod == 'smartname-datefallback' && stdFormats.isEmpty) {
        final dateA = _getReleaseDateFromRelease(
          a,
          useLatestAssetDateAsReleaseDate,
        );
        final dateB = _getReleaseDateFromRelease(
          b,
          useLatestAssetDateAsReleaseDate,
        );
        return (dateA ?? DateTime(0)).compareTo(dateB ?? DateTime(0));
      }

      if (sortMethod != 'name' && stdFormats.isNotEmpty) {
        final sortedFormats = stdFormats.toList()
          ..sort((x, y) => y.length.compareTo(x.length));
        final regCache = <String, RegExp>{};
        final reg = regCache.putIfAbsent(
          sortedFormats.first,
          () => RegExp(sortedFormats.first),
        );
        final matchA = reg.firstMatch(nameA);
        final matchB = reg.firstMatch(nameB);
        if (matchA == null || matchB == null) {
          return compareAlphaNumeric(nameA as String, nameB as String);
        }
        return compareAlphaNumeric(
          (nameA as String).substring(matchA.start, matchA.end),
          (nameB as String).substring(matchB.start, matchB.end),
        );
      }

      return compareAlphaNumeric(nameA as String, nameB as String);
    });
  }

  void _positionLatestRelease(List<dynamic> releases, dynamic latestRelease) {
    if (latestRelease == null ||
        (latestRelease['tag_name'] ?? latestRelease['name']) == null ||
        releases.isEmpty ||
        (latestRelease['tag_name'] ?? latestRelease['name']) ==
            (releases[releases.length - 1]['tag_name'] ??
                releases[releases.length - 1]['name'])) {
      return;
    }
    final ind = releases.indexWhere(
      (element) =>
          (latestRelease['tag_name'] ?? latestRelease['name']) ==
          (element['tag_name'] ?? element['name']),
    );
    if (ind >= 0) {
      releases.add(releases.removeAt(ind));
    }
  }

  /// Notes for the newest few releases, newest first, taken from the response
  /// the update check already made. The detail page shows the installed
  /// version and its neighbour, so a short window covers it without another
  /// request; anything older is fetched on demand.
  static const int _recentReleaseNotesCount = 5;

  /// A release body longer than this is not cached. Bodies have no practical
  /// upper bound on GitHub, and every one kept here is written back to the
  /// app's record on each save and carried in every export; the page fetches
  /// the rare huge one on demand instead.
  static const int _recentReleaseNotesMaxLength = 8192;

  List<ReleaseNotes> _recentReleaseNotes(
    List<dynamic> releases,
    bool includePrereleases,
    bool titleAsVersion,
  ) {
    final recent = <ReleaseNotes>[];
    for (final release in releases) {
      if (recent.length >= _recentReleaseNotesCount) break;
      if (release is! Map) continue;
      if (release['draft'] == true) continue;
      if (release['prerelease'] == true && !includePrereleases) continue;
      final tag = release['tag_name']?.toString();
      final name = release['name']?.toString();
      // Mirrors _selectGitHubTargetRelease exactly, including its fallback to
      // the tag for an untitled release. Deriving it any other way would drop
      // releases the app does count, leaving gaps that make the release before
      // a version look like the one before that.
      final title = name == null || name.trim().isEmpty ? (tag ?? '') : name;
      final version = titleAsVersion ? title : (tag ?? name);
      // Stop for the same reason as an oversized body: a release this cannot
      // name is one the list cannot step over without the entries either side
      // of it becoming neighbours they are not.
      if (version == null || version.isEmpty) break;
      final body = (release['body'] ?? '').toString().trim();
      // Stop rather than skip: the page reads the release before a version as
      // the next entry down, so the list has to stay contiguous. A shorter
      // list just means the page fetches when it needs to reach past it.
      if (body.length > _recentReleaseNotesMaxLength) break;
      recent.add(ReleaseNotes(version, body.isEmpty ? null : body));
    }
    return recent;
  }

  dynamic _selectGitHubTargetRelease({
    required List<dynamic> releases,
    required bool fallbackToOlderReleases,
    required bool includePrereleases,
    required String? regexFilter,
    required String? regexNotesFilter,
    required bool includeZips,
    required bool includeTarballs,
    required Map<String, dynamic> additionalSettings,
    required Map<String, String> sourceConfigSettingValues,
  }) {
    var releaseSkipped = 0;
    final titleRegex = regexFilter != null ? RegExp(regexFilter) : null;
    final notesRegex = regexNotesFilter != null
        ? RegExp(regexNotesFilter)
        : null;
    for (int i = 0; i < releases.length; i++) {
      if (!fallbackToOlderReleases && i > releaseSkipped) break;
      if (!includePrereleases && releases[i]['prerelease'] == true) {
        releaseSkipped++;
        continue;
      }
      if (releases[i]['draft'] == true) {
        releaseSkipped++;
        continue;
      }
      var nameToFilter = releases[i]['name'] as String?;
      if (nameToFilter == null || nameToFilter.trim().isEmpty) {
        nameToFilter = releases[i]['tag_name']?.toString() ?? '';
      }
      if (titleRegex != null && !titleRegex.hasMatch(nameToFilter.trim())) {
        continue;
      }
      if (notesRegex != null &&
          !notesRegex.hasMatch(
            ((releases[i]['body'] as String?) ?? '').trim(),
          )) {
        continue;
      }
      final allAssetsWithUrls = _findReleaseAssetUrls(
        releases[i],
        includeZips,
        includeTarballs,
        sourceConfigSettingValues,
      );
      final List<MapEntry<String, String>> allAssetUrls = allAssetsWithUrls
          .map((e) => e['final_url'] as MapEntry<String, String>)
          .toList();
      final apkAssetsWithUrls = allAssetsWithUrls.where((element) {
        final name = (element['final_url'] as MapEntry<String, String>).key;
        return AppSource.isApkOrContainerFile(
          name,
          includeArchives: includeZips,
          includeTarballs: includeTarballs,
        );
      }).toList();

      final filteredApkUrls = filterApks(
        apkAssetsWithUrls
            .map((e) => e['final_url'] as MapEntry<String, String>)
            .toList(),
        additionalSettings['apkFilterRegEx'],
        additionalSettings['invertAPKFilter'],
      );
      final filteredApks = apkAssetsWithUrls
          .where(
            (e) => filteredApkUrls
                .where(
                  (e2) =>
                      e2.key ==
                      (e['final_url'] as MapEntry<String, String>).key,
                )
                .isNotEmpty,
          )
          .toList();

      if (filteredApks.isEmpty && additionalSettings['trackOnly'] != true) {
        continue;
      }
      final targetRelease = releases[i];
      targetRelease['apkUrls'] = filteredApkUrls;
      targetRelease['filteredAssets'] = filteredApks;
      targetRelease['version'] =
          additionalSettings['releaseTitleAsVersion'] == true
          ? nameToFilter
          : targetRelease['tag_name'] ?? targetRelease['name'];
      if (targetRelease['tarball_url'] != null) {
        allAssetUrls.add(
          MapEntry(
            (targetRelease['version'] ?? 'source') + '.tar.gz',
            undoGHProxyMod(
              targetRelease['tarball_url'],
              sourceConfigSettingValues,
            ),
          ),
        );
      }
      if (targetRelease['zipball_url'] != null) {
        allAssetUrls.add(
          MapEntry(
            (targetRelease['version'] ?? 'source') + '.zip',
            undoGHProxyMod(
              targetRelease['zipball_url'],
              sourceConfigSettingValues,
            ),
          ),
        );
      }
      targetRelease['allAssetUrls'] = allAssetUrls;
      return targetRelease;
    }
    return null;
  }

  /// Fetches and parses GitHub releases, applying sort/filter/prelease settings,
  /// then resolves the best matching release to an [APKDetails] result.
  Future<APKDetails> _fetchReleaseDetails(
    String requestUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings, {
    Function(Response)? onHttpErrorCode,
  }) async {
    final SettingsProvider settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    final sourceConfigSettingValues = await getSourceConfigValues(
      additionalSettings,
      settingsProvider,
    );
    await checkForRepositoryRename(
      standardUrl,
      additionalSettings,
      sourceConfigSettingValues,
    );
    final bool includePrereleases =
        additionalSettings['includePrereleases'] == true;
    final bool fallbackToOlderReleases =
        additionalSettings['fallbackToOlderReleases'] == true;
    final String? regexFilter =
        (additionalSettings['filterReleaseTitlesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseTitlesByRegEx']
        : null;
    final String? regexNotesFilter =
        (additionalSettings['filterReleaseNotesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseNotesByRegEx']
        : null;
    final bool verifyLatestTag = additionalSettings['verifyLatestTag'] == true;
    final bool useLatestAssetDateAsReleaseDate =
        additionalSettings['useLatestAssetDateAsReleaseDate'] == true;
    final String sortMethod =
        additionalSettings['sortMethodChoice'] ?? 'smartname-datefallback';
    final bool includeZips = additionalSettings['includeZips'] == true;
    final bool includeTarballs = additionalSettings['includeTarballs'] == true;
    dynamic latestRelease;
    if (verifyLatestTag) {
      final uri = Uri.parse(requestUrl);
      final latestUrl = uri.replace(query: null, path: '${uri.path}/latest');
      final Response res = await _sourceRequestWithAuthFallback(
        latestUrl.toString(),
        additionalSettings,
      );
      if (res.statusCode != 200) {
        if (onHttpErrorCode != null) {
          onHttpErrorCode(res);
        }
        throw getObtainiumHttpError(res);
      }
      latestRelease = jsonDecode(res.body);
    }
    final Response res = await _sourceRequestWithAuthFallback(
      requestUrl,
      additionalSettings,
    );
    if (res.statusCode == 200) {
      final decoded = jsonDecode(res.body);
      if (decoded is! List) {
        throw NoReleasesError();
      }
      var releases = decoded;
      if (latestRelease != null) {
        final latestTag = latestRelease['tag_name'] ?? latestRelease['name'];
        if (releases
            .where(
              (element) =>
                  (element['tag_name'] ?? element['name']) == latestTag,
            )
            .isEmpty) {
          releases = [latestRelease, ...releases];
        }
      }

      if (sortMethod == 'none') {
        releases = releases.reversed.toList();
      } else {
        _sortGitHubReleases(
          releases,
          sortMethod,
          useLatestAssetDateAsReleaseDate,
        );
      }
      _positionLatestRelease(releases, latestRelease);
      releases = releases.reversed.toList();
      final targetRelease = _selectGitHubTargetRelease(
        releases: releases,
        fallbackToOlderReleases: fallbackToOlderReleases,
        includePrereleases: includePrereleases,
        regexFilter: regexFilter,
        regexNotesFilter: regexNotesFilter,
        includeZips: includeZips,
        includeTarballs: includeTarballs,
        additionalSettings: additionalSettings,
        sourceConfigSettingValues: sourceConfigSettingValues,
      );
      if (targetRelease == null) {
        throw NoReleasesError();
      }
      final String? version = targetRelease['version'];
      final DateTime? releaseDate = _getReleaseDateFromRelease(
        targetRelease,
        useLatestAssetDateAsReleaseDate,
      );
      if (version == null || version.isEmpty) {
        throw NoVersionError();
      }
      final changeLog = (targetRelease['body'] ?? '').toString();
      // Prefer Discoverium's curated name/author/icon over the raw repo path.
      final repoEntry = await DiscoveriumRepo.findByUrl(standardUrl);
      if (repoEntry?.icon != null) {
        additionalSettings['discoveriumIconUrl'] = repoEntry!.icon;
      }
      return APKDetails(
        version,
        targetRelease['apkUrls'] as List<MapEntry<String, String>>,
        _appNamesWithRepoMetadata(standardUrl, repoEntry),
        releaseDate: releaseDate,
        changeLog: changeLog.isEmpty ? null : changeLog,
        allAssetUrls:
            targetRelease['allAssetUrls'] as List<MapEntry<String, String>>,
        recentReleases: _recentReleaseNotes(
          releases,
          includePrereleases,
          additionalSettings['releaseTitleAsVersion'] == true,
        ),
      );
    } else {
      if (onHttpErrorCode != null) {
        onHttpErrorCode(res);
      }
      throw getObtainiumHttpError(res);
    }
  }

  Future<APKDetails> fetchReleaseDetailsWithTagFallback(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    Future<String> Function(bool) reqUrlGenerator,
    dynamic Function(Response)? onHttpErrorCode,
  ) async {
    try {
      return await _fetchReleaseDetails(
        await reqUrlGenerator(false),
        standardUrl,
        additionalSettings,
        onHttpErrorCode: onHttpErrorCode,
      );
    } catch (err) {
      if (err is NoReleasesError && additionalSettings['trackOnly'] == true) {
        return await _fetchReleaseDetails(
          await reqUrlGenerator(true),
          standardUrl,
          additionalSettings,
          onHttpErrorCode: onHttpErrorCode,
        );
      } else {
        rethrowOrWrapError(err);
      }
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      return await fetchReleaseDetailsWithTagFallback(
        standardUrl,
        additionalSettings,
        (bool useTagUrl) async {
          return '${await convertStandardUrlToAPIUrl(standardUrl, additionalSettings)}/${useTagUrl ? 'tags' : 'releases'}?per_page=100';
        },
        (Response res) {
          githubErrorCheck(res);
        },
      );
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }

  /// The release notes GitHub publishes for [version], or null when that
  /// release has no body or cannot be found.
  ///
  /// [getLatestAPKDetails] only carries the notes of the release it selected,
  /// so reading the notes of an already-installed version means asking again.
  /// Tags are matched leniently because a repo may tag `v1.2.3` while the
  /// version string is `1.2.3`.
  Future<String?> getReleaseNotesForVersion(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    String version,
  ) async {
    final apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    final wanted = _bareVersion(version);
    // Ask for the single release by tag first: the releases list runs to
    // hundreds of KB on a repo with any history, and reaches back only 100
    // releases, so an older installed version finds nothing in it.
    for (final tag in {version.trim(), 'v$wanted'}) {
      if (tag.isEmpty) continue;
      final byTag = await _sourceRequestWithAuthFallback(
        '$apiUrl/releases/tags/${Uri.encodeComponent(tag)}',
        additionalSettings,
      );
      if (byTag.statusCode == 404) continue;
      if (byTag.statusCode != 200) {
        githubErrorCheck(byTag);
        throw getObtainiumHttpError(byTag);
      }
      final release = jsonDecode(byTag.body);
      if (release is! Map) break;
      final body = (release['body'] ?? '').toString().trim();
      return body.isEmpty ? null : body;
    }
    // The tag may not be the version string at all (a prefix other than `v`, a
    // version read out of the release title), so fall back to the list.
    final res = await _sourceRequestWithAuthFallback(
      '$apiUrl/releases?per_page=100',
      additionalSettings,
    );
    if (res.statusCode != 200) {
      githubErrorCheck(res);
      throw getObtainiumHttpError(res);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return null;
    for (final release in decoded) {
      if (release is! Map) continue;
      final candidates = [
        release['tag_name']?.toString(),
        release['name']?.toString(),
      ].whereType<String>();
      if (!candidates.any((c) => _bareVersion(c) == wanted)) continue;
      final body = (release['body'] ?? '').toString().trim();
      return body.isEmpty ? null : body;
    }
    return null;
  }

  /// The release published immediately before [version], with the notes it
  /// carries, or null when there is no older release to show.
  ///
  /// Only the newest few releases are fetched: the previous release is
  /// adjacent to the current one in all but pathological cases, and the full
  /// list runs to hundreds of KB. Drafts are always skipped, and prereleases
  /// are skipped unless the app opted into them, so this picks the same
  /// releases an update check would.
  Future<({String version, String? notes})?> getPreviousRelease(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    String version,
  ) async {
    final apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    final res = await _sourceRequestWithAuthFallback(
      '$apiUrl/releases?per_page=10',
      additionalSettings,
    );
    if (res.statusCode != 200) {
      githubErrorCheck(res);
      throw getObtainiumHttpError(res);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return null;
    final wanted = _bareVersion(version);
    final includePrereleases = additionalSettings['includePrereleases'] == true;
    final titleAsVersion = additionalSettings['releaseTitleAsVersion'] == true;
    var passedCurrent = false;
    for (final release in decoded) {
      if (release is! Map) continue;
      if (release['draft'] == true) continue;
      final tag = release['tag_name']?.toString();
      final name = release['name']?.toString();
      if (!passedCurrent) {
        passedCurrent = [
          tag,
          name,
        ].whereType<String>().any((c) => _bareVersion(c) == wanted);
        continue;
      }
      if (release['prerelease'] == true && !includePrereleases) continue;
      // Same rule getLatestAPKDetails uses, so the label matches what an
      // update would have called this version.
      final previous = titleAsVersion ? name : (tag ?? name);
      if (previous == null || previous.isEmpty) continue;
      final body = (release['body'] ?? '').toString().trim();
      return (version: previous, notes: body.isEmpty ? null : body);
    }
    return null;
  }

  /// A tag or release title reduced to the part that identifies the version,
  /// so `v1.2.3` and `1.2.3` compare equal.
  static String _bareVersion(String raw) =>
      raw.trim().replaceFirst(RegExp(r'^[vV](?=\d)'), '');

  /// Release notes with bare `#123` issue references turned into links to the
  /// repository [standardUrl] belongs to.
  ///
  /// GitHub's own web view links these, but the API hands back the raw
  /// markdown, where the reference is just text. The repository comes from the
  /// app's own URL, so this works for any host and any owner/repo.
  ///
  /// Anything already inside code, a link, or a URL is passed through
  /// untouched, so a `#` that belongs to one of those is left alone.
  static String linkIssueReferences(String markdown, String standardUrl) {
    final repoUrl = _repoWebUrl(standardUrl);
    if (repoUrl == null) return markdown;
    return markdown.replaceAllMapped(_issueReferencePattern, (match) {
      final passthrough = match.group(1);
      if (passthrough != null) return passthrough;
      final number = match.group(2)!;
      return '[#$number]($repoUrl/issues/$number)';
    });
  }

  /// The first alternative matches everything that must survive untouched —
  /// fenced and inline code, existing links and images, autolinks, bare URLs —
  /// so the alternation consumes it before the reference branch can. The
  /// second matches a `#123` that starts a word, which is what GitHub treats
  /// as an issue reference; `owner/repo#123` and `&#8212;` are excluded by the
  /// lookbehind.
  static final RegExp _issueReferencePattern = RegExp(
    r'(```[\s\S]*?```|`[^`\n]*`|!?\[[^\]]*\]\([^)]*\)|<[^>\s]+>|'
    r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+)'
    r'|(?<![\w/&#-])#(\d+)\b',
  );

  /// `https://host/owner/repo` for [standardUrl], or null when it does not
  /// name a repository.
  static String? _repoWebUrl(String standardUrl) {
    final uri = Uri.tryParse(standardUrl.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    return '${uri.origin}/${segments[0]}/${segments[1]}';
  }

  /// The curated repo's display name/author when this URL is in it, otherwise
  /// the names derived from the repository path.
  AppNames _appNamesWithRepoMetadata(
    String standardUrl,
    DiscoveriumApp? repoEntry,
  ) {
    final fallback = getAppNames(standardUrl);
    if (repoEntry == null || repoEntry.name.isEmpty) return fallback;
    return AppNames(repoEntry.author ?? fallback.author, repoEntry.name);
  }

  AppNames getAppNames(String standardUrl) {
    final String temp = standardUrl.substring(standardUrl.indexOf('://') + 3);
    final pathStart = temp.indexOf('/');
    if (pathStart < 0) throw InvalidURLError(name);
    final List<String> names = temp.substring(pathStart + 1).split('/');
    if (names.isEmpty || names[0].isEmpty) throw InvalidURLError(name);
    return AppNames(names[0], names.sublist(1).join('/'));
  }

  Future<Map<String, List<String>>> searchCommon(
    String query,
    String requestUrl,
    String rootProp, {
    Function(Response)? onHttpErrorCode,
    Map<String, dynamic> querySettings = const {},
  }) async {
    final Response res = await sourceRequest(requestUrl, {});
    if (res.statusCode == 200) {
      final int minStarCount =
          int.tryParse(querySettings['minStarCount']?.toString() ?? '') ?? 0;
      final Map<String, List<String>> urlsWithDescriptions = {};
      for (var e in (jsonDecode(res.body)[rootProp] as List<dynamic>)) {
        if ((e['stargazers_count'] ?? e['stars_count'] ?? 0) >= minStarCount) {
          urlsWithDescriptions.addAll({
            e['html_url'] as String: [
              e['full_name'] as String,
              ((e['archived'] == true ? '[ARCHIVED] ' : '') +
                  (e['description'] != null
                      ? e['description'] as String
                      : tr('noDescription'))),
            ],
          });
        }
      }
      return urlsWithDescriptions;
    } else {
      if (onHttpErrorCode != null) {
        onHttpErrorCode(res);
      }
      throw getObtainiumHttpError(res);
    }
  }

  String undoGHProxyMod(
    String reqUrl,
    Map<String, String> sourceConfigSettingValues,
  ) {
    final ghReqPrefix = sourceConfigSettingValues['GHReqPrefix'];
    if (ghReqPrefix == null || ghReqPrefix.isEmpty) return reqUrl;
    final prefix = 'https://$ghReqPrefix/';
    return reqUrl.startsWith(prefix) ? reqUrl.substring(prefix.length) : reqUrl;
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final sourceConfigSettingValues = await getSourceConfigValues({}, sp);
    final results = await searchCommon(
      query,
      '${await getAPIHost({})}/search/repositories?q=${Uri.encodeQueryComponent(query)}&per_page=100',
      'items',
      onHttpErrorCode: (Response res) {
        githubErrorCheck(res);
      },
      querySettings: querySettings,
    );
    if ((sourceConfigSettingValues['GHReqPrefix'] ?? '').isNotEmpty) {
      final Map<String, List<String>> results2 = {};
      results.forEach((k, v) {
        results2[undoGHProxyMod(k, sourceConfigSettingValues)] = v;
      });
      return results2;
    } else {
      return results;
    }
  }

  void rateLimitErrorCheck(Response res) {
    if (res.headers['x-ratelimit-remaining'] == '0') {
      final now = DateTime.now();
      final resetEpochSeconds =
          int.tryParse(res.headers['x-ratelimit-reset'] ?? '') ??
          now.millisecondsSinceEpoch ~/ 1000 + _fallbackCacheSeconds;
      final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
      final remainingMinutes = ((resetEpochSeconds - nowSeconds) / 60)
          .ceil()
          .clamp(0, 9999);
      throw RateLimitError(remainingMinutes);
    }
  }

  /// Throws the actual GitHub error for failed API responses: rate limits
  /// (when the headers say so) and auth problems (e.g. a token that is not
  /// authorized for this repository), which the generic handler would
  /// otherwise mislabel as a rate limit (see #3211).
  void githubErrorCheck(Response res) {
    rateLimitErrorCheck(res);
    if (res.statusCode == 401 || res.statusCode == 403) {
      try {
        final message = (jsonDecode(res.body)['message'] as String?)?.trim();
        if (message != null &&
            message.isNotEmpty &&
            !message.toLowerCase().contains('rate limit')) {
          throw ObtainiumError(message);
        }
      } catch (_) {
        // Not a JSON error body; fall through to the generic handler.
      }
    }
  }
}
