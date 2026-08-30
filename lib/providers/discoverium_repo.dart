import 'dart:async';

import 'package:http/http.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:yaml/yaml.dart';

/// An app entry from Discoverium's curated `repo/apps.yml`.
class DiscoveriumApp {
  final String name;
  final String description;
  final String? id;
  final String? author;
  final String? url;
  final String? icon;
  final String? releasesUrl;
  final List<String> categories;
  final bool verified;
  final bool commercial;

  /// Optional `filters.release.title` regex, applied as the app's
  /// `filterReleaseTitlesByRegEx` setting when the app is added.
  final String? releaseTitleFilterRegex;

  const DiscoveriumApp({
    required this.name,
    required this.description,
    this.id,
    this.author,
    this.url,
    this.icon,
    this.releasesUrl,
    this.categories = const [],
    this.verified = false,
    this.commercial = false,
    this.releaseTitleFilterRegex,
  });

  factory DiscoveriumApp.fromYaml(Map<dynamic, dynamic> yaml) {
    final releases = yaml['releases'];
    final releasesUrl = (releases is Map && releases['url'] != null)
        ? releases['url'].toString()
        : null;

    // The repo uses 'author' in some entries and 'authors' in others.
    final author = (yaml['author'] ?? yaml['authors'])?.toString();

    // Likewise 'categories' (list) or 'category' (single).
    final categoriesRaw = yaml['categories'];
    final List<String> categories = categoriesRaw is List
        ? categoriesRaw.map((e) => e.toString()).toList()
        : (yaml['category'] != null ? [yaml['category'].toString()] : const []);

    String? releaseTitleFilterRegex;
    final filters = yaml['filters'];
    if (filters is Map) {
      final release = filters['release'];
      if (release is Map && release['title'] != null) {
        releaseTitleFilterRegex = release['title'].toString();
      }
    }

    return DiscoveriumApp(
      name: yaml['name']?.toString() ?? yaml['id']?.toString() ?? '?',
      description: yaml['description']?.toString() ?? '',
      id: yaml['id']?.toString(),
      author: author,
      url: yaml['url']?.toString(),
      icon: yaml['icon']?.toString(),
      releasesUrl: releasesUrl,
      categories: categories,
      verified: yaml['verified'] == true,
      commercial: yaml['commercial'] == true,
      releaseTitleFilterRegex: releaseTitleFilterRegex,
    );
  }

  bool matchesSearch(String query) {
    final q = query.toLowerCase();
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q) ||
        (author?.toLowerCase().contains(q) ?? false) ||
        categories.any((c) => c.toLowerCase().contains(q));
  }
}

/// Fetches and caches Discoverium's curated app repository.
///
/// The repo file is ~1000 lines and is consulted several times while adding a
/// single app (ID inference, display names, icon), so results are cached per
/// branch and concurrent callers share one in-flight request.
class DiscoveriumRepo {
  DiscoveriumRepo._();

  static const Duration cacheTtl = Duration(minutes: 30);

  static String _appsUrl(String branch) =>
      'https://raw.githubusercontent.com/cygnusx-1-org/Discoverium/refs/heads/$branch/repo/apps.yml';

  static List<DiscoveriumApp>? _cached;
  static String? _cachedBranch;
  static DateTime? _cachedAt;
  static Future<List<DiscoveriumApp>>? _inFlight;
  static String? _inFlightBranch;

  /// The branch configured in settings, defaulting to `main`.
  static Future<String> currentBranch() async {
    final settings = SettingsProvider();
    await settings.initializeSettings();
    return settings.discoveriumBranch;
  }

  /// Drops the cache so the next read re-fetches (used by pull-to-refresh).
  static void invalidate() {
    _cached = null;
    _cachedBranch = null;
    _cachedAt = null;
  }

  /// All apps in the curated repo for [branch] (defaults to the configured
  /// branch). Returns an empty list if the repo can't be fetched or parsed.
  static Future<List<DiscoveriumApp>> apps({
    String? branch,
    bool forceRefresh = false,
  }) async {
    final b = branch ?? await currentBranch();
    final fresh =
        _cached != null &&
        _cachedBranch == b &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < cacheTtl;
    if (fresh && !forceRefresh) return _cached!;
    if (_inFlight != null && _inFlightBranch == b && !forceRefresh) {
      return _inFlight!;
    }
    final future = _fetch(b);
    _inFlight = future;
    _inFlightBranch = b;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightBranch = null;
      }
    }
  }

  static Future<List<DiscoveriumApp>> _fetch(String branch) async {
    final res = await get(Uri.parse(_appsUrl(branch)));
    if (res.statusCode != 200) {
      throw StateError(
        'Failed to load Discoverium repo apps.yml ($branch): '
        'HTTP ${res.statusCode}',
      );
    }
    final parsed = loadYaml(res.body);
    final apps = <DiscoveriumApp>[];
    if (parsed is List) {
      for (final entry in parsed) {
        if (entry is! Map) continue;
        try {
          apps.add(DiscoveriumApp.fromYaml(entry));
        } catch (e) {
          AppLogger.warn('Skipping malformed Discoverium repo entry: $e');
        }
      }
    }
    _cached = apps;
    _cachedBranch = branch;
    _cachedAt = DateTime.now();
    return apps;
  }

  /// Normalizes a releases URL for comparison: lowercased, no trailing slash,
  /// and with any `/releases...` suffix stripped so a repo URL and its releases
  /// page compare equal.
  static String normalizeUrl(String url) {
    var normalized = url.trim().toLowerCase();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    // Strip a trailing /releases path segment and anything under it. Anchored
    // so a repository whose own name merely starts with "releases" (e.g.
    // .../releases-manager) is not truncated to its owner.
    final releasesSegment = RegExp(r'/releases(/.*)?$').firstMatch(normalized);
    if (releasesSegment != null && releasesSegment.start > 0) {
      normalized = normalized.substring(0, releasesSegment.start);
    }
    return normalized;
  }

  /// Whether [entry] is already in the user's app list.
  ///
  /// Matched on the package ID first: [existingIds] are `AppsProvider.apps`
  /// keys, and an app added from the curated repo takes its ID straight from
  /// the entry, so this is an exact comparison. The display name deliberately
  /// plays no part — `saveApps` overwrites a stored app's name with the
  /// installed package's localized label, so a curated title like
  /// "Fossify Clock" is held as "Zegar" under a Polish locale (#28).
  ///
  /// [existingNormalizedUrls] are the existing apps' URLs run through
  /// [normalizeUrl], checked second so an entry with no ID, or an app still
  /// carrying a temporary ID, is still recognized by the URL it came from.
  static bool isAlreadyAdded(
    DiscoveriumApp entry,
    Set<String> existingIds,
    Set<String> existingNormalizedUrls,
  ) {
    final id = entry.id;
    if (id != null && id.isNotEmpty && existingIds.contains(id)) return true;
    final releasesUrl = entry.releasesUrl;
    return releasesUrl != null &&
        existingNormalizedUrls.contains(normalizeUrl(releasesUrl));
  }

  /// The repo entry whose releases URL matches [standardUrl], if any.
  ///
  /// Never throws — a repo that can't be reached simply yields no metadata so
  /// callers fall back to their normal inference.
  static Future<DiscoveriumApp?> findByUrl(String standardUrl) async {
    try {
      final target = normalizeUrl(standardUrl);
      if (target.isEmpty) return null;
      for (final app in await apps()) {
        final releasesUrl = app.releasesUrl;
        if (releasesUrl == null) continue;
        if (normalizeUrl(releasesUrl) == target) return app;
      }
    } catch (e) {
      AppLogger.debug('Discoverium repo lookup failed for $standardUrl: $e');
    }
    return null;
  }
}
