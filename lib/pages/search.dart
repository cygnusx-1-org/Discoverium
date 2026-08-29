import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/add_app.dart';
import 'package:obtainium/pages/advanced_search.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/discoverium_repo.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';

/// Browses Discoverium's curated app repository so users can discover apps
/// rather than having to already know a release URL.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  // Search is a pushed route, so its state would otherwise be discarded every
  // time the user opens an app and comes back. These preserve the query, the
  // loaded repo and the exact scroll position across visits.
  static String _lastQuery = '';
  static List<DiscoveriumApp> _lastApps = [];
  static double _lastScrollOffset = 0;
  static bool _loadedOnce = false;
  static String? _lastBranch;

  late final TextEditingController _searchController;
  late final ScrollController _scrollController;

  /// Releases URLs of adds currently in flight, shown on their own rows.
  final Set<String> _addingUrls = <String>{};

  List<DiscoveriumApp> _allApps = [];
  List<DiscoveriumApp> _filteredApps = [];
  bool _isLoading = false;
  String? _error;
  final Set<String> _failedIconUrls = <String>{};

  @override
  void initState() {
    super.initState();
    final branch = context.read<SettingsProvider>().discoveriumBranch;
    if (_lastBranch != branch) {
      // A different branch is a different catalogue, so the retained query,
      // results and scroll position no longer describe anything.
      _lastBranch = branch;
      _lastQuery = '';
      _lastApps = [];
      _lastScrollOffset = 0;
      _loadedOnce = false;
    }
    _searchController = TextEditingController(text: _lastQuery);
    _scrollController = ScrollController(
      initialScrollOffset: _lastScrollOffset,
    );
    _allApps = List.of(_lastApps);
    _searchController.addListener(_onQueryChanged);
    if (!_loadedOnce) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadApps());
    }
  }

  @override
  void dispose() {
    _lastQuery = _searchController.text;
    _lastApps = List.of(_allApps);
    if (_scrollController.hasClients) {
      _lastScrollOffset = _scrollController.offset;
    }
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(_recomputeFiltered);

  Future<void> _loadApps({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final branch = context.read<SettingsProvider>().discoveriumBranch;
      final apps = await DiscoveriumRepo.apps(
        branch: branch,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      // Only after the results are actually kept, or leaving mid-load would
      // suppress every later attempt.
      _loadedOnce = true;
      setState(() {
        _allApps = apps;
        _isLoading = false;
        _recomputeFiltered();
      });
    } catch (e) {
      AppLogger.error(e, message: 'Failed to load the Discoverium app repo');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Applies the query plus the verified/commercial filters, and hides apps the
  /// user has already added.
  void _recomputeFiltered() {
    final settings = context.read<SettingsProvider>();
    final allowUnverified = settings.allowUnverifiedApps;
    final allowCommercial = settings.allowCommercialApps;
    final query = _searchController.text.trim();

    final existing = context.read<AppsProvider>().apps.values.map((a) => a.app);
    final existingUrls = <String>{};
    final existingNameAuthors = <String>{};
    for (final app in existing) {
      existingUrls.add(DiscoveriumRepo.normalizeUrl(app.url));
      existingNameAuthors.add(
        '${app.name.toLowerCase()}|${app.author.toLowerCase()}',
      );
    }

    bool alreadyAdded(DiscoveriumApp app) {
      final releasesUrl = app.releasesUrl;
      if (releasesUrl != null &&
          existingUrls.contains(DiscoveriumRepo.normalizeUrl(releasesUrl))) {
        return true;
      }
      final nameAuthor =
          '${app.name.toLowerCase()}|${(app.author ?? '').toLowerCase()}';
      return existingNameAuthors.contains(nameAuthor);
    }

    _filteredApps = _allApps
        .where(
          (app) =>
              (allowUnverified || app.verified) &&
              (allowCommercial || !app.commercial) &&
              (_addingUrls.contains(app.releasesUrl) || !alreadyAdded(app)) &&
              (query.isEmpty || app.matchesSearch(query)),
        )
        .toList();
  }

  Future<void> _confirmAndAdd(DiscoveriumApp app) async {
    if (app.releasesUrl == null) {
      showError(ObtainiumError(tr('noReleasesUrl')), context);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(app.name),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            if (app.description.isNotEmpty) Text(app.description),
            if (app.author != null)
              Text(
                tr('byX', args: [app.author!]),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            Text(tr('addAppConfirmation')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('cancel')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('add')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _addApp(app);
    }
  }

  Future<void> _addApp(DiscoveriumApp discoveriumApp) async {
    final appsProvider = context.read<AppsProvider>();
    final notificationsProvider = context.read<NotificationsProvider>();
    final sourceProvider = SourceProvider();
    final releasesUrl = discoveriumApp.releasesUrl!;
    final requestUrl = releasesUrl.trim();

    setState(() => _addingUrls.add(releasesUrl));

    try {
      final source = sourceProvider.getSource(requestUrl);
      final additionalSettings = getDefaultValuesFromFormItems(
        source.combinedAppSpecificSettingFormItems,
      );

      // Some curated entries publish several artifacts per release and need a
      // title filter to pick the right one.
      final titleFilter = discoveriumApp.releaseTitleFilterRegex;
      if (titleFilter != null && titleFilter.isNotEmpty) {
        additionalSettings['filterReleaseTitlesByRegEx'] = titleFilter;
      }

      var app = await sourceProvider.getApp(
        source,
        requestUrl,
        additionalSettings,
        trackOnlyOverride: false,
        sourceIsOverriden: false,
        inferAppIdIfOptional: true,
      );

      // The curated repo usually records the package ID, so this download is
      // only needed for entries that don't.
      if (isTempId(app) && !app.settings.getBool('trackOnly')) {
        if (!mounted) throw ObtainiumError(tr('cancelled'));
        final apkUrl = await appsProvider.confirmAppFileUrl(
          app,
          context,
          false,
        );
        if (apkUrl == null) {
          throw ObtainiumError(tr('cancelled'));
        }
        app = app.copyWith(
          preferredApkIndex: app.apkUrls
              .map((e) => e.value)
              .toList()
              .indexOf(apkUrl.value),
        );
        if (!mounted) throw ObtainiumError(tr('cancelled'));
        final downloadedArtifact = await appsProvider.downloadApp(
          app,
          appNavigatorKey.currentContext,
          notificationsProvider: notificationsProvider,
        );
        DownloadedApk? downloadedFile;
        DownloadedDir? downloadedDir;
        if (downloadedArtifact is DownloadedApk) {
          downloadedFile = downloadedArtifact;
        } else if (downloadedArtifact is DownloadedDir) {
          downloadedDir = downloadedArtifact;
        }
        if (downloadedFile == null && downloadedDir == null) {
          throw ObtainiumError(tr('downloadFailed'));
        }
        app = app.copyWith(id: downloadedFile?.appId ?? downloadedDir!.appId);
      }

      // Checked after the download because the ID can change above.
      if (appsProvider.apps.containsKey(app.id)) {
        throw ObtainiumError(tr('appAlreadyAdded'));
      }

      if (app.settings.getBool('trackOnly') ||
          !app.settings.getBool('versionDetection')) {
        app = app.copyWith(installedVersion: app.latestVersion);
      }

      await appsProvider.saveApps([app], onlyIfExists: false);
    } catch (e) {
      if (mounted) showError(e, context);
    } finally {
      // The row leaves the list on success (already-added apps are filtered
      // out), so there is nothing more to report.
      if (mounted) {
        setState(() {
          _addingUrls.remove(releasesUrl);
          _recomputeFiltered();
        });
      } else {
        _addingUrls.remove(releasesUrl);
      }
    }
  }

  Widget _repoIcon(DiscoveriumApp app, double size) {
    final url = app.icon;
    final cacheDim = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final placeholder = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.apps, size: size * 0.55),
    );
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null || _failedIconUrls.contains(url)
            ? placeholder
            : Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: cacheDim,
                cacheHeight: cacheDim,
                errorBuilder: (context, error, stack) {
                  // Remember the failure so the list stops retrying on scroll.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _failedIconUrls.add(url)) setState(() {});
                  });
                  return placeholder;
                },
              ),
      ),
    );
  }

  Widget _statusChip(String label, {bool warn = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 10)),
      labelStyle: warn ? TextStyle(color: colorScheme.onErrorContainer) : null,
      backgroundColor: warn ? colorScheme.errorContainer : null,
      side: warn ? BorderSide.none : null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _appTile(DiscoveriumApp app) {
    final colorScheme = Theme.of(context).colorScheme;
    final showChips =
        app.categories.isNotEmpty || app.commercial || !app.verified;
    final adding = _addingUrls.contains(app.releasesUrl);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: adding
            ? const SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : _repoIcon(app, 40),
        title: Text(
          app.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            if (app.description.isNotEmpty) Text(app.description),
            if (app.author != null)
              Text(
                tr('byX', args: [app.author!]),
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            if (showChips)
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  ...app.categories.map(_statusChip),
                  if (app.commercial) _statusChip(tr('commercial'), warn: true),
                  if (!app.verified) _statusChip(tr('unverified'), warn: true),
                ],
              ),
          ],
        ),
        isThreeLine: true,
        onTap: app.releasesUrl == null || adding
            ? null
            : () => _confirmAndAdd(app),
      ),
    );
  }

  /// Wraps a non-scrolling state so pull-to-refresh still reaches it.
  Widget _refreshable(Widget child) {
    return RefreshIndicator(
      onRefresh: () => _loadApps(forceRefresh: true),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Icon(
                Icons.error_outline,
                size: 56,
                color: Theme.of(context).colorScheme.error,
              ),
              Text(
                tr('errorOccurred'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              FilledButton.tonalIcon(
                onPressed: () => _loadApps(forceRefresh: true),
                icon: const Icon(Icons.refresh),
                label: Text(tr('retry')),
              ),
            ],
          ),
        ),
      );
    }
    if (_allApps.isEmpty) {
      // Refreshable: this state is otherwise a dead end, since there is no
      // retry button here and _loadedOnce suppresses the reload on re-entry.
      return _refreshable(
        EmptyState(icon: Icons.apps, message: tr('noAppsLoaded')),
      );
    }
    if (_filteredApps.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        message: tr('tryDifferentSearch'),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadApps(forceRefresh: true),
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 96,
        ),
        itemCount: _filteredApps.length,
        itemBuilder: (context, index) => _appTile(_filteredApps[index]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the verified/commercial filters or the app list change, so
    // newly added apps disappear from the results.
    context.watch<SettingsProvider>();
    context.watch<AppsProvider>();
    _recomputeFiltered();

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(tr('searchApps')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdvancedSearchPage()),
            ),
            child: Text(tr('advancedSearch')),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: tr('searchHint'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: tr('clear'),
                        onPressed: _searchController.clear,
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AddAppPage())),
        tooltip: tr('addApp'),
        icon: const Icon(Icons.add),
        label: Text(tr('add')),
      ),
    );
  }
}
