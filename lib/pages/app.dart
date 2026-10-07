import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/components/app_list_tile.dart';
import 'package:obtainium/components/app_markdown.dart';
import 'package:obtainium/components/category_editor.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/components/qr_code_image.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/components/app_detail_widgets.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/utils/format_utils.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/utils/locale_utils.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/utils/nav_helper.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.appId,
    this.showOppositeOfPreferredView = false,
    this.onClose,
  });

  final String appId;
  final bool showOppositeOfPreferredView;

  /// When provided, the page is being shown embedded in a detail pane (two-pane
  /// layout); "back" and post-action dismissals clear the pane via this instead
  /// of popping a route.
  final VoidCallback? onClose;

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> {
  late final AppsProvider appsProvider;
  late final SettingsProvider settingsProvider;
  late String appId;
  bool _initialized = false;

  late final SourceProvider _sourceProvider;
  WebViewController? webViewController;
  bool webViewLoaded = false;
  bool _webViewReady = false;
  bool get webViewReady => _webViewReady;
  String? _webViewError;
  bool _pendingAppIdChange = false;
  AppInMemory? prevApp;
  bool updating = false;

  int? _appCacheSig;
  AppInMemory? _appCache;

  /// How long the page waits for release notes it has to fetch before giving
  /// up and drawing without them. The page is held back until this resolves,
  /// so it must not be able to hang.
  static const Duration _releaseNotesTimeout = Duration(seconds: 15);

  /// Release notes for the sections below the app details, resolved in full
  /// before any of them is drawn. Null means not resolved yet, and nothing is
  /// drawn at all: filling the cards in afterwards makes them change height
  /// under the reader.
  List<_ReleaseNotesSection>? _releaseNotes;
  String? _releaseNotesKey;
  String? _releaseNotesAppId;

  String? _aboutCacheKey;
  Widget? _aboutCache;

  /// The details scroll view, which [_handleTvScrollKey] scrolls on TV.
  final ScrollController _tvScrollController = ScrollController();

  final GlobalKey _scrollViewKey = GlobalKey();

  /// The whole details pane (the details and the action bar), on TV.
  final FocusNode _tvPaneFocus = FocusNode(debugLabel: 'details pane');

  // Best-effort download-size probe for the currently-selected APK URL.
  String? _sizeProbeKey;
  int? _probedDownloadSize;

  void _maybeProbeDownloadSize(AppInMemory app) {
    final String? releaseUrl = app.app.releaseUrl;
    final bool hasReleaseUrl = releaseUrl != null && releaseUrl.isNotEmpty;
    final int apkIndex =
        (app.app.preferredApkIndex >= 0 &&
            app.app.preferredApkIndex < app.app.apkUrls.length)
        ? app.app.preferredApkIndex
        : 0;
    final List<String> urls = app.app.apkUrls.isNotEmpty
        ? splitMultiApkUrl(
            app.app.apkUrls[apkIndex].value,
          ).where((u) => u.isNotEmpty && u != 'placeholder').toList()
        : const [];
    final String? key = urls.isNotEmpty
        ? '${app.app.id}|${app.app.apkUrls[apkIndex].value}'
        : hasReleaseUrl
        ? '${app.app.id}|$releaseUrl'
        : null;
    if (key == null) {
      if (_sizeProbeKey != null || _probedDownloadSize != null) {
        _sizeProbeKey = null;
        setState(() => _probedDownloadSize = null);
      }
      return;
    }
    if (key == _sizeProbeKey) return;
    _sizeProbeKey = key;
    _probedDownloadSize = null;
    () async {
      try {
        final source = _sourceProvider.getSource(
          app.app.url,
          overrideSource: app.app.overrideSource,
        );
        if (urls.isNotEmpty) {
          // A split set is downloaded in full, so report the combined size.
          final sizes = await Future.wait(
            urls.map((url) async {
              final resolvedUrl = await source.assetUrlPrefetchModifier(
                url,
                app.app.url,
                app.app.additionalSettings,
              );
              final headers = await source.getRequestHeaders(
                app.app.additionalSettings,
                resolvedUrl,
                forAPKDownload: true,
              );
              return getDownloadSize(
                resolvedUrl,
                headers: headers,
                allowInsecure: app.app.settings.getBool('allowInsecure'),
                enableCertificatePinning:
                    settingsProvider.enableCertificatePinning,
              );
            }),
          );
          final knownSizes = sizes.whereType<int>();
          if (mounted && _sizeProbeKey == key && knownSizes.isNotEmpty) {
            setState(
              () => _probedDownloadSize = knownSizes.reduce((a, b) => a + b),
            );
          }
        } else {
          // Track-only sources (e.g. APKMirror) have no direct APK URL; let the
          // source resolve the size from its release page instead.
          final size = await source.resolveDownloadSize(
            app.app.url,
            app.app.additionalSettings,
            releaseUrl: releaseUrl,
          );
          if (mounted && _sizeProbeKey == key && size != null) {
            setState(() => _probedDownloadSize = size);
          }
        }
      } catch (e) {
        // Best-effort only: leave the size unknown when it can't be resolved.
        AppLogger.info('Size probe failed: $e');
      }
    }();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      appId = widget.appId;
      appsProvider = context.read<AppsProvider>();
      settingsProvider = context.read<SettingsProvider>();
      _sourceProvider = context.read<SourceProvider>();
      _initialized = true;
    }
  }

  @override
  void didUpdateWidget(covariant AppPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // React to appId changes even before the WebView is ready, but defer
    // UI updates until the WebView has finished loading to avoid
    // predictive-back crashes.
    if (_initialized && oldWidget.appId != widget.appId) {
      // This state object can be reused for a different app (two-pane layout
      // and list reuse); keep actions pointed at the currently shown app.
      appId = widget.appId;
      prevApp = null;
      _sizeProbeKey = null;
      _probedDownloadSize = null;
      webViewLoaded = false;
      _webViewError = null;
      _pendingAppIdChange = true;
      if (webViewReady) {
        _pendingAppIdChange = false;
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    webViewController = null;
    _tvScrollController.dispose();
    _tvPaneFocus.dispose();
    super.dispose();
  }

  void onWebViewLoaded() {
    if (!mounted) return;
    _webViewReady = true;
    if (_pendingAppIdChange) {
      _pendingAppIdChange = false;
      setState(() {});
    }
  }

  AppSource? get source {
    final aim = appsProvider.apps[appId];
    if (aim == null) return null;
    return _sourceProvider.getSource(
      aim.app.url,
      overrideSource: aim.app.overrideSource,
    );
  }

  WebViewController ensureWebViewController(String url) {
    var wvc = webViewController;
    if (wvc == null) {
      wvc = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (String url) {
              onWebViewLoaded();
            },
            onWebResourceError: (WebResourceError error) {
              if (error.isForMainFrame == true && mounted) {
                setState(() {
                  _webViewError = error.description;
                });
              }
            },
            onNavigationRequest: (NavigationRequest request) =>
                !(request.url.startsWith('http://') ||
                    request.url.startsWith('https://') ||
                    request.url.startsWith('ftp://') ||
                    request.url.startsWith('ftps://'))
                ? NavigationDecision.prevent
                : NavigationDecision.navigate,
          ),
        );
      webViewController = wvc;
    }
    if (!webViewLoaded) {
      webViewLoaded = true;
      wvc.loadRequest(Uri.parse(url));
    }
    return wvc;
  }

  int appSignature(AppInMemory a) {
    final app = a.app;
    return Object.hashAll([
      identityHashCode(a.icon),
      identityHashCode(a.installedInfo),
      app.id,
      a.name,
      a.author,
      app.installedVersion,
      app.installedVersionCode,
      app.latestVersion,
      app.latestVersionCode,
      app.latestVersionName,
      app.url,
      app.overrideSource,
      app.releaseDate?.microsecondsSinceEpoch,
      app.lastUpdateCheck?.microsecondsSinceEpoch,
      Object.hashAll(app.categories),
      app.pinned,
      app.hasPendingRepoRename,
      app.pendingRepoRenameUrl,
      app.apkUrls.length,
      app.otherAssetUrls.length,
      app.preferredApkIndex,
      identityHashCode(app.additionalSettings),
    ]);
  }

  AppInMemory? cachedApp(AppInMemory? source) {
    if (source == null) {
      _appCache = null;
      _appCacheSig = null;
      return null;
    }
    final sig = appSignature(source);
    if (sig == _appCacheSig && _appCache != null) {
      return _appCache;
    }
    final copy = source.deepCopy();
    _appCache = copy;
    _appCacheSig = sig;
    return copy;
  }

  Future<void> getUpdate(BuildContext context) async {
    try {
      updating = true;
      if (mounted) setState(() {});
      await appsProvider.checkUpdate(appId);
    } catch (err) {
      if (err is RepositoryRenamedError && context.mounted) {
        await appsProvider.updatePendingRepoRename(appId, err.newUrl);
      } else if (context.mounted) {
        showError(err, context);
      }
    } finally {
      updating = false;
      if (mounted) setState(() {});
    }
  }

  Future<Map<String, dynamic>?> showAdditionalOptionsDialog(
    BuildContext context,
    AppInMemory? app,
  ) async {
    final s = source;
    final items = (s?.combinedAppSpecificSettingFormItems ?? []).map((row) {
      row = row.map((e) {
        if (app?.app.additionalSettings[e.key] != null) {
          e.value = app?.app.additionalSettings[e.key];
        }
        return e;
      }).toList();
      return row;
    }).toList();

    Map<String, dynamic> values = {};
    return Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        traversalEdgeBehavior: traversalEdgeBehaviorFor(context),
        builder: (ctx) => PopScope<Map<String, dynamic>>(
          // Leaving the page saves the settings, so there is no Continue button.
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            // While a text field is being edited, the first BACK only
            // dismisses the keyboard; it must not also save and leave.
            if (isEditingTextField()) {
              FocusManager.instance.primaryFocus?.unfocus();
              return;
            }
            Navigator.of(ctx).pop(values);
          },
          child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.surface,
            body: CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  automaticallyImplyLeading: true,
                  title: Text(
                    tr('additionalOptsFor', args: [app?.name ?? tr('app')]),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      MediaQuery.of(context).padding.bottom,
                    ),
                    child: GeneratedForm(
                      tileMode: true,
                      items: items,
                      onValueChanges: (v, valid, isBuilding) {
                        values = v;
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void handleAdditionalOptionChanges(
    Map<String, dynamic>? values,
    BuildContext context,
    AppInMemory? app,
  ) {
    if (app != null && values != null) {
      final s = source;
      final Map<String, dynamic> originalSettings = app.app.additionalSettings;
      final savedValues = Map<String, dynamic>.from(values);
      // The additional-options form does not include every stored setting
      // (e.g. the add-time package ID field and source-config overrides such
      // as credentials), so carry those over instead of dropping them.
      originalSettings.forEach((key, value) {
        savedValues.putIfAbsent(key, () => value);
      });
      // Turning off remembering the APK picked from several forgets the
      // pick, so the next install asks again.
      final forgetChosenApk =
          TypedSettings(
            originalSettings,
          ).getBool('rememberChosenApk', defaultValue: true) &&
          !TypedSettings(
            savedValues,
          ).getBool('rememberChosenApk', defaultValue: true);
      app.app = app.app.copyWith(
        additionalSettings: savedValues,
        preferredApkName: forgetChosenApk ? null : app.app.preferredApkName,
      );
      if (s?.enforceTrackOnly == true) {
        app.app = app.app.copyWith(
          additionalSettings: Map<String, dynamic>.from(
            app.app.additionalSettings,
          )..['trackOnly'] = true,
        );
        if (context.mounted) {
          showMessage(tr('appsFromSourceAreTrackOnly'), context);
        }
      }
      appsProvider.saveApps([app.app]).then((_) {
        if (context.mounted) {
          getUpdate(context);
        }
      });
    }
  }

  Future<List<String>> installOrUpdate(
    BuildContext context,
    AppInMemory? app,
  ) async {
    try {
      final trackOnly = app?.app.settings.getBool('trackOnly') == true;
      final successMessage = app?.app.installedVersion == null
          ? tr('installed')
          : tr('appsUpdated');
      final np = Provider.of<NotificationsProvider>(context, listen: false);
      settingsProvider.heavyImpact();
      final res = await appsProvider.downloadAndInstallLatestApps([
        appId,
      ], appNavigatorKey.currentContext);
      if (res.isNotEmpty && !trackOnly && context.mounted) {
        showMessage(successMessage, context);
      }
      if (res.isNotEmpty) {
        unawaited(np.cancel(updateNotificationId));
        unawaited(
          np.cancel(
            SilentUpdateAttemptNotification([], id: res[0].hashCode).id,
          ),
        );
      }
      return res;
    } catch (e) {
      if (context.mounted) showError(e, context);
      return <String>[];
    }
  }

  void resetInstallStatus(AppInMemory? app) {
    if (app == null) return;
    app.app = app.app.copyWith(installedVersion: null);
    unawaited(appsProvider.saveApps([app.app]));
  }

  Future<bool> removeApp(BuildContext context, AppInMemory? app) async {
    if (app == null) return false;
    return await appsProvider.removeAppsWithModal(context, [app.app]) == true;
  }

  void openAppSettings(AppInMemory? app) {
    if (app == null) return;
    appsProvider.openAppSettings(app.app.id);
  }

  void updateAppIcon() {
    appsProvider.updateAppIcon(appId, ignoreCache: true);
  }

  void _closePage() {
    if (!mounted) return;
    if (widget.onClose != null) {
      widget.onClose!();
    } else if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleInstallOrUpdate(
    BuildContext context,
    AppInMemory? app,
  ) async {
    final res = await installOrUpdate(context, app);
    if (res.isNotEmpty && mounted) {
      _closePage();
    }
  }

  Widget _getAppWebView(BuildContext context, AppInMemory? app) {
    if (app == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_webViewError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              Text(tr('webviewLoadError')),
              Text(
                _webViewError!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _webViewError = null;
                    webViewLoaded = false;
                  });
                },
                child: Text(tr('retry')),
              ),
            ],
          ),
        ),
      );
    }
    final webController = ensureWebViewController(app.app.url)
      ..setBackgroundColor(Theme.of(context).colorScheme.surface);
    return WebViewWidget(
      key: ObjectKey(webController),
      controller: webController,
    );
  }

  AppBar _appScreenAppBar() => AppBar(
    automaticallyImplyLeading: widget.onClose == null,
    leading: widget.onClose != null
        ? IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _closePage,
          )
        : null,
  );

  Widget _getPrimaryButton(
    BuildContext context,
    AppInMemory? app,
    bool areDownloadsRunning,
  ) {
    final installed = app?.app.installedVersion;
    final hasAction =
        app != null &&
        !updating &&
        (installed == null ||
            appHasOfferableUpdate(app.app, settingsProvider)) &&
        !areDownloadsRunning;
    final trackOnly = app?.app.settings.getBool('trackOnly') == true;
    return FilledButton.icon(
      onPressed: hasAction ? () => _handleInstallOrUpdate(context, app) : null,
      icon: Icon(
        installed == null
            ? Icons.download_outlined
            : Icons.system_update_alt_rounded,
      ),
      label: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            installed == null
                ? (!trackOnly ? tr('install') : tr('markInstalled'))
                : !trackOnly
                ? tr('update')
                : tr('markUpdated'),
          ),
          if (_probedDownloadSize != null)
            Builder(
              builder: (context) => Text(
                formatBytes(_probedDownloadSize!),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: DefaultTextStyle.of(context).style.color,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _getSecondaryActions(
    BuildContext context,
    AppInMemory? app,
    AppSource? source,
    AppsProvider appsProvider,
    SettingsProvider settingsProvider,
    bool showAppWebpageFinal,
    bool trackOnly,
  ) {
    return <Widget>[
      if (source != null && source.hasAppSpecificSettings)
        IconButton(
          onPressed: app?.downloadProgress != null || updating
              ? null
              : () async {
                  final values = await showAdditionalOptionsDialog(
                    context,
                    app,
                  );
                  if (context.mounted) {
                    handleAdditionalOptionChanges(values, context, app);
                  }
                },
          tooltip: tr('additionalOptions'),
          icon: const Icon(Icons.edit),
        ),
      if (app != null && app.installedInfo != null)
        IconButton(
          onPressed: () {
            openAppSettings(app);
          },
          icon: const Icon(Icons.settings),
          tooltip: tr('settings'),
        ),
      // On TV the app icon is not a remote stop, so opening the app gets a
      // button here.
      if (settingsProvider.isTV && app != null && app.installedInfo != null)
        IconButton(
          onPressed: () {
            settingsProvider.lightImpact();
            packageManager.openApp(app.app.id);
          },
          icon: const Icon(Icons.play_arrow_rounded),
          tooltip: tr('open'),
        ),
      if (app != null && showAppWebpageFinal)
        IconButton(
          onPressed: () async {
            updateAppIcon();
            if (!context.mounted) return;
            unawaited(
              showDialog(
                context: context,
                builder: (BuildContext ctx) =>
                    AppInfoDialog(app: app, appsProvider: appsProvider),
              ),
            );
          },
          icon: const Icon(Icons.more_horiz),
          tooltip: tr('more'),
        ),
      // On TV the release date is not a remote stop, so its changelog gets a
      // button here. A changelog that is just the release page is already the
      // next button.
      if (settingsProvider.isTV &&
          app?.app.changeLog?.trim().isNotEmpty == true)
        IconButton(
          onPressed: getChangeLogFn(context, app!.app),
          tooltip: tr('changes'),
          icon: const Icon(Icons.notes_rounded),
        ),
      if (app?.app.releaseUrl?.isNotEmpty == true)
        IconButton(
          onPressed: () => unawaited(
            launchUrlString(
              app!.app.releaseUrl!,
              mode: LaunchMode.externalApplication,
            ),
          ),
          tooltip: tr('openReleasePage'),
          icon: const Icon(Icons.open_in_new),
        ),
      if (trackOnly &&
          app?.app.installedVersion != null &&
          app?.app.installedVersion == app?.app.latestVersion)
        IconButton(
          onPressed: updating
              ? null
              : () {
                  settingsProvider.selectionClick();
                  resetInstallStatus(app);
                },
          icon: const Icon(Icons.restore_rounded),
          tooltip: tr('resetInstallStatus'),
        ),
      IconButton(
        onPressed: app == null || app.downloadProgress != null || updating
            ? null
            : () {
                removeApp(context, app).then((removed) {
                  if (removed) {
                    _closePage();
                  }
                });
              },
        tooltip: tr('remove'),
        icon: const Icon(Icons.delete_outline),
      ),
    ];
  }

  /// One card of the page. On TV a card is a remote stop of its own unless
  /// [hasControls], in which case its controls are the stops instead.
  Widget _buildSection(
    bool isFirst,
    bool isLast, {
    required List<Widget> children,
    EdgeInsetsGeometry? padding,
    bool hasControls = false,
  }) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    return SliverToBoxAdapter(
      child: Padding(
        padding: AppPaddings.page,
        child: hasControls
            ? ConnectedCard(
                isFirst: isFirst,
                isLast: isLast,
                padding: padding ?? AppPaddings.cardInner,
                child: content,
              )
            : TvStopCard(
                isFirst: isFirst,
                isLast: isLast,
                padding: padding ?? AppPaddings.cardInner,
                child: content,
              ),
      ),
    );
  }

  Widget _repoRenameInfoRow(IconData icon, String title, String subtitle) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Row(
      spacing: 12,
      children: [
        Icon(icon, size: 24, color: cs.onSurfaceVariant),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: tt.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              Text(
                subtitle,
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Banner shown when a repository rename was detected, letting the user adopt
  /// the new URL (which resumes update checks) or dismiss it. Returns no slivers
  /// when there is no pending rename.
  List<Widget> _buildRepoRenameSection(
    AppInMemory? app,
    AppsProvider appsProvider,
  ) {
    if (app?.app.hasPendingRepoRename != true) return const [];
    final appId = app!.app.id;
    final pendingUrl = app.app.pendingRepoRenameUrl!;
    return [
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacings.sectionGap)),
      SliverToBoxAdapter(
        child: Padding(
          padding: AppPaddings.page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 3,
            children: [
              ConnectedCard(
                isFirst: true,
                isLast: false,
                child: _repoRenameInfoRow(
                  Icons.info_outline_rounded,
                  tr('repoRenamed'),
                  tr('repoRenamedExplanation'),
                ),
              ),
              ConnectedCard(
                isFirst: false,
                isLast: false,
                child: _repoRenameInfoRow(
                  Icons.link_rounded,
                  tr('newUrl'),
                  pendingUrl,
                ),
              ),
              ConnectedCard(
                isFirst: false,
                isLast: true,
                child: Row(
                  spacing: 12,
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            appsProvider.updatePendingRepoRename(appId, null),
                        child: Text(tr('dismiss')),
                      ),
                    ),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () async {
                          await appsProvider.acceptRepoRename(
                            appId,
                            pendingUrl,
                          );
                          if (mounted) unawaited(getUpdate(context));
                        },
                        child: Text(tr('updateUrl')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildAppIcon(AppInMemory? app) {
    final icon = AppIcon(bytes: app?.icon, size: 56, radius: 14);
    if (app == null || app.installedInfo == null) return icon;
    // Not a remote stop on TV, matching the app list's rows.
    return ExcludeFocus(
      excluding: settingsProvider.isTV,
      child: Semantics(
        button: true,
        label: app.name,
        child: TvFocusRing(
          borderRadius: 14,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              settingsProvider.lightImpact();
              packageManager.openApp(app.app.id);
            },
            child: icon,
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderSection(AppInMemory? app) {
    return _buildSection(
      true,
      true,
      children: [
        Row(
          children: [
            _buildAppIcon(app),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app?.name ?? tr('app'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('byX', args: [app?.author ?? tr('unknown')]),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildVersionInfoSections(AppInMemory? app) {
    final settingsProvider = context.read<SettingsProvider>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final trackOnly = app?.app.settings.getBool('trackOnly') == true;
    final heldUntil = app?.app == null
        ? null
        : appHeldUntil(app!.app, settingsProvider);
    final apkCount = app?.app.apkUrls.length ?? 0;
    final changeLogFn = app != null ? getChangeLogFn(context, app.app) : null;
    return [
      _buildSection(
        true,
        false,
        children: [
          if (trackOnly) _detailNote(tr('xIsTrackOnly', args: [tr('app')])),
          if (heldUntil != null)
            _detailNote(
              tr(
                'updateHeldUntilX',
                args: [
                  app!.app.heldVersion!,
                  heldUntil.toLocal().toString().split('.').first,
                ],
              ),
            ),
          () {
            String l = appInstalledVersionText(app?.app, settingsProvider);
            final upToDate =
                app == null ||
                !appHasOfferableUpdate(app.app, settingsProvider);
            if (!upToDate) {
              l +=
                  '\n${app.app.latestVersionName ?? app.app.latestVersion} ${tr('latest')}';
            }
            return Text(
              l,
              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            );
          }(),
          if (apkCount > 0)
            _detailNote(
              apkCount == 1 ? app!.app.apkUrls[0].key : plural('apk', apkCount),
            ),
          if (changeLogFn != null || app?.app.releaseDate != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // Not a remote stop on TV, matching the app list's rows.
              child: ExcludeFocus(
                excluding: settingsProvider.isTV,
                child: InkWell(
                  onTap: changeLogFn,
                  borderRadius: BorderRadius.circular(4),
                  child: Text(
                    app?.app.releaseDate == null
                        ? tr('changes')
                        : app!.app.releaseDate!
                              .toLocal()
                              .toString()
                              .split('.')
                              .first,
                    style: tt.bodyMedium?.copyWith(
                      color: changeLogFn != null
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      fontStyle: changeLogFn != null ? FontStyle.italic : null,
                      decoration: changeLogFn != null
                          ? TextDecoration.underline
                          : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 2)),
      _buildSection(
        false,
        true,
        children: [
          Text(
            tr(
              'lastUpdateCheckX',
              args: [
                app?.app.lastUpdateCheck
                        ?.toLocal()
                        .toString()
                        .split('.')
                        .first ??
                    tr('never'),
              ],
            ),
            style: tt.bodyMedium,
          ),
        ],
      ),
    ];
  }

  Widget _detailNote(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }

  /// GitHub's release notes for the installed version paired with its
  /// neighbour: the update ahead of it when one is pending, otherwise the
  /// release before it.
  ///
  /// The app record only carries the notes of the release the source last
  /// selected, so the other section is fetched. Only GitHub is handled: it is
  /// the source whose notes are structured markdown.
  List<Widget> _buildReleaseNotesSections(
    AppInMemory? app,
    SettingsProvider settingsProvider,
  ) {
    final installed = app?.app.installedVersion;
    if (app == null || installed == null) return const [];
    final source = SourceProvider().getSource(
      app.app.url,
      overrideSource: app.app.overrideSource,
    );
    if (source is! GitHub) return const [];
    // The same question the version row above asks, so the two never disagree:
    // a latest that differs from the installed version is not an update when
    // it is older and downgrades are hidden.
    final hasNext = appHasOfferableUpdate(app.app, settingsProvider);
    _ensureReleaseNotes(app.app, source, installed, hasNext);
    final sections = _releaseNotes;
    if (sections == null) return const [];
    return [
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacings.sectionGap)),
      for (var i = 0; i < sections.length; i++) ...[
        if (i > 0) const SliverToBoxAdapter(child: SizedBox(height: 2)),
        _buildSection(
          i == 0,
          i == sections.length - 1,
          children: [
            _releaseNotesHeader(context, sections[i].label),
            sections[i].notes == null
                ? _releaseNotesPlaceholder(context, sections[i].placeholder)
                : AppMarkdown(
                    data: sections[i].notes!,
                    relativeLinkBase: app.app.url,
                  ),
          ],
        ),
      ],
    ];
  }

  /// Whether the release-notes sections are ready to be drawn, starting their
  /// lookup if it has not begun. False only before the first resolution for
  /// this page: a later reload keeps the notes already on screen, so a routine
  /// update check cannot blank the page out from under the reader.
  bool _releaseNotesReady(AppInMemory? app, SettingsProvider settingsProvider) {
    final installed = app?.app.installedVersion;
    if (app == null || installed == null) return true;
    final source = SourceProvider().getSource(
      app.app.url,
      overrideSource: app.app.overrideSource,
    );
    if (source is! GitHub) return true;
    _ensureReleaseNotes(
      app.app,
      source,
      installed,
      appHasOfferableUpdate(app.app, settingsProvider),
    );
    return _releaseNotes != null;
  }

  /// Resolves the release notes for [app] if that has not been done for these
  /// versions yet. Everything the update check already cached is used as-is,
  /// which is the usual case and costs nothing; anything missing is fetched,
  /// and until it arrives the page holds off drawing.
  void _ensureReleaseNotes(
    App app,
    GitHub source,
    String installed,
    bool hasNext,
  ) {
    final key = '${app.id}|$installed|${app.latestVersion}|$hasNext';
    if (key == _releaseNotesKey) return;
    // Notes belonging to a different app must never stay on screen, so this
    // page waits again when it is pointed at another app. Only a version
    // change within the same app keeps what is already drawn.
    if (_releaseNotesAppId != app.id) _releaseNotes = null;
    _releaseNotesAppId = app.id;
    _releaseNotesKey = key;
    final cached = _cachedReleaseNotes(app, installed, hasNext);
    if (cached != null) {
      // Assigning during build is safe and deliberate: this same build then
      // renders the sections, so a fully cached app never waits a frame.
      _releaseNotes = cached;
      return;
    }
    unawaited(_loadReleaseNotes(key, app, source, installed, hasNext));
  }

  /// Both sections built purely from what the update check stored, or null
  /// when any part of it is missing.
  List<_ReleaseNotesSection>? _cachedReleaseNotes(
    App app,
    String installed,
    bool hasNext,
  ) {
    final cache = app.recentReleases;
    if (cache.isEmpty) return null;
    final latest = app.latestVersion;
    ReleaseNotes? entryFor(String version) {
      for (final entry in cache) {
        if (entry.version == version) return entry;
      }
      return null;
    }

    _ReleaseNotesSection sectionFor(String label, ReleaseNotes entry) =>
        _ReleaseNotesSection(
          label: '$label - ${entry.version}',
          notes: entry.notes == null
              ? null
              : GitHub.linkIssueReferences(entry.notes!, app.url),
          placeholder: tr('noReleaseNotes'),
        );

    final installedEntry = entryFor(installed);
    if (installedEntry == null) return null;
    if (hasNext) {
      final latestEntry = entryFor(latest);
      if (latestEntry == null) return null;
      return [
        sectionFor(tr('releaseNotesForNextVersion'), latestEntry),
        sectionFor(tr('releaseNotes'), installedEntry),
      ];
    }
    final index = cache.indexOf(installedEntry);
    // The release before the installed one is the next entry down. The last
    // cached entry has no known successor, so that case is not cached.
    if (index + 1 >= cache.length) return null;
    return [
      sectionFor(tr('releaseNotes'), installedEntry),
      sectionFor(tr('releaseNotesForPreviousVersion'), cache[index + 1]),
    ];
  }

  Future<void> _loadReleaseNotes(
    String key,
    App app,
    GitHub source,
    String installed,
    bool hasNext,
  ) async {
    final latest = app.latestVersion;
    // The stored changelog belongs to the latest release, so it describes the
    // installed version only when the two are literally the same release.
    final changeLog = app.changeLog?.trim();
    final storedNotes = changeLog == null || changeLog.isEmpty
        ? null
        : GitHub.linkIssueReferences(changeLog, app.url);
    final sections = <_ReleaseNotesSection>[];

    Future<_ReleaseNotesSection> notesFor(String label, String version) async {
      try {
        final notes = await source
            .getReleaseNotesForVersion(app.url, app.additionalSettings, version)
            .timeout(_releaseNotesTimeout);
        return _ReleaseNotesSection(
          label: '$label - $version',
          notes: notes == null
              ? null
              : GitHub.linkIssueReferences(notes, app.url),
          placeholder: tr('noReleaseNotes'),
        );
      } catch (e) {
        return _ReleaseNotesSection(
          label: '$label - $version',
          notes: null,
          placeholder: tr('releaseNotesLoadFailed'),
        );
      }
    }

    if (hasNext) {
      sections.add(
        _ReleaseNotesSection(
          label: '${tr('releaseNotesForNextVersion')} - $latest',
          notes: storedNotes,
          placeholder: tr('noReleaseNotes'),
        ),
      );
      sections.add(await notesFor(tr('releaseNotes'), installed));
    } else if (latest == installed) {
      sections.add(
        _ReleaseNotesSection(
          label: '${tr('releaseNotes')} - $installed',
          notes: storedNotes,
          placeholder: tr('noReleaseNotes'),
        ),
      );
      sections.add(await _previousSection(app, source, installed));
    } else {
      // Nothing to offer, but the latest release is not the installed one
      // either (a downgrade the app is hiding), so the changelog on hand
      // describes neither section.
      sections.add(await notesFor(tr('releaseNotes'), installed));
      sections.add(await _previousSection(app, source, installed));
    }

    if (!mounted || key != _releaseNotesKey) return;
    setState(() => _releaseNotes = sections);
  }

  Future<_ReleaseNotesSection> _previousSection(
    App app,
    GitHub source,
    String installed,
  ) async {
    final label = tr('releaseNotesForPreviousVersion');
    try {
      final previous = await source
          .getPreviousRelease(app.url, app.additionalSettings, installed)
          .timeout(_releaseNotesTimeout);
      if (previous == null) {
        return _ReleaseNotesSection(
          label: label,
          notes: null,
          placeholder: tr('noPreviousRelease'),
        );
      }
      final notes = previous.notes;
      return _ReleaseNotesSection(
        label: '$label - ${previous.version}',
        notes: notes == null
            ? null
            : GitHub.linkIssueReferences(notes, app.url),
        placeholder: tr('noReleaseNotes'),
      );
    } catch (e) {
      return _ReleaseNotesSection(
        label: label,
        notes: null,
        placeholder: tr('releaseNotesLoadFailed'),
      );
    }
  }

  /// Renders the source-provided "about" markdown, when present, as its own
  /// section so it fits the sectioned detail layout.
  List<Widget> _buildAboutSection(AppInMemory? app) {
    final about = app?.app.additionalSettings['about'];
    if (about is! String || about.isEmpty) return const [];
    // Reuse the built AppMarkdown while the content is unchanged: returning
    // the identical widget instance lets Flutter skip re-parsing it on every
    // rebuild (download ticks, probes, etc.).
    if (_aboutCacheKey != about || _aboutCache == null) {
      _aboutCacheKey = about;
      _aboutCache = AppMarkdown(data: about);
    }
    return [
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacings.sectionGap)),
      _buildSection(true, true, children: [_aboutCache!]),
    ];
  }

  List<Widget> _buildSourceInfoSections(
    AppInMemory? app,
    AppsProvider appsProvider,
    bool certs,
    bool hasAssets,
  ) {
    final theme = Theme.of(context);
    final widgets = <Widget>[
      _buildSection(
        true,
        certs || hasAssets ? false : true,
        children: [
          // Not a remote stop on TV, like the app icon and release date.
          ExcludeFocus(
            excluding: settingsProvider.isTV,
            child: Tooltip(
              message: tr('copyToClipboard'),
              child: GestureDetector(
                onLongPress: () {
                  copyToClipboard(context, app?.app.url ?? '');
                },
                child: LinkText(
                  text: app?.app.url ?? '',
                  url: app?.app.url ?? '',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ),
          ),
          // On TV the link is not a remote stop, so offer it to a phone instead.
          if (settingsProvider.isTV && (app?.app.url ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            QrCodeImage(data: app!.app.url),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          Text(
            app?.app.id ?? '',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ];
    if (certs) {
      final a = app!;
      widgets.addAll([
        const SliverToBoxAdapter(child: SizedBox(height: 2)),
        _buildSection(
          false,
          !hasAssets,
          children: [
            Text(
              '${plural('certificateHash', a.certificateHashes.length)}'
              '${a.hasMultipleSigners ? " (${tr('multipleSigners')})" : ""}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            ...a.certificateHashes.map(
              (h) => Tooltip(
                message: tr('copyToClipboard'),
                child: GestureDetector(
                  onLongPress: () {
                    copyToClipboard(context, h);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(h, style: theme.textTheme.bodySmall),
                  ),
                ),
              ),
            ),
          ],
        ),
      ]);
    }
    if (hasAssets) {
      widgets.addAll([
        const SliverToBoxAdapter(child: SizedBox(height: 2)),
        _buildSection(
          false,
          true,
          padding: const EdgeInsets.all(0),
          hasControls: true,
          children: [
            Center(
              child: TextButton.icon(
                onPressed: app?.app == null || updating
                    ? null
                    : () async {
                        try {
                          await appsProvider.downloadAppAssets([
                            app!.app.id,
                          ], context);
                        } catch (e) {
                          if (mounted) {
                            showError(e, context);
                          }
                        }
                      },
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(
                  tr(
                    'downloadX',
                    args: [lowerCaseIfEnglish(tr('releaseAsset'))],
                  ),
                ),
              ),
            ),
          ],
        ),
      ]);
    }
    return widgets;
  }

  Widget _buildCategorySection(AppInMemory? app, AppsProvider appsProvider) {
    return _buildSection(
      true,
      true,
      hasControls: true,
      children: [
        CategorySelector(
          alignment: WrapAlignment.start,
          selected: app?.app.categories.toSet() ?? {},
          onChanged: (categories) {
            if (app != null) {
              app.app = app.app.copyWith(categories: categories.toList());
              unawaited(appsProvider.saveApps([app.app]));
            }
          },
        ),
      ],
    );
  }

  Widget _buildActionsContent(
    AppInMemory? app,
    AppsProvider appsProvider,
    SettingsProvider settingsProvider,
    AppSource? source,
    bool showAppWebpageFinal,
    bool trackOnly,
    bool areDownloadsRunning,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (app?.downloadProgress != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    label: app!.downloadProgress! >= 0
                        ? tr(
                            'percentProgress',
                            args: [app.downloadProgress!.toInt().toString()],
                          )
                        : tr('installing'),
                    child: LinearProgressIndicator(
                      value: app.downloadProgress! >= 0
                          ? app.downloadProgress! / 100
                          : null,
                    ),
                  ),
                ),
                if (app.downloadProgress! >= 0) ...[
                  const SizedBox(width: 8),
                  DownloadCancelButton(
                    onPressed: () => appsProvider.cancelDownload(widget.appId),
                  ),
                ],
              ],
            ),
          ),
        if (app?.downloadProgress != null &&
            app!.downloadProgress! >= 0 &&
            app.downloadReceivedBytes != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              formatDownloadSize(
                app.downloadReceivedBytes,
                app.downloadTotalBytes,
              )!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              ..._getSecondaryActions(
                context,
                app,
                source,
                appsProvider,
                settingsProvider,
                showAppWebpageFinal,
                trackOnly,
              ),
              const Spacer(),
              _getPrimaryButton(context, app, areDownloadsRunning),
            ],
          ),
        ),
      ],
    );
  }

  /// On TV, coming over from the app list with Right always starts at the top
  /// card, with the page scrolled back to its start. Right is still held down
  /// while focus arrives, which tells this apart from focus coming back from a
  /// dialog opened here.
  void _onTvPaneFocusChange(bool hasFocus) {
    if (!hasFocus ||
        !settingsProvider.isTV ||
        !HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.arrowRight,
        )) {
      return;
    }
    TvCardFocusNode? top;
    for (final node in _tvPaneFocus.traversalDescendants) {
      if (node is TvCardFocusNode &&
          (top == null || node.rect.top < top.rect.top)) {
        top = node;
      }
    }
    if (top == null) return;
    if (_tvScrollController.hasClients) {
      _tvScrollController.jumpTo(_tvScrollController.position.minScrollExtent);
    }
    top.requestFocus();
  }

  /// On TV a remote scrolls only by moving focus, so every card is a remote
  /// stop (see [_buildSection]), and Up and Down move from one to the next,
  /// scrolling it into view. A card too tall for the screen is read to its
  /// end, a step per press, before focus moves on. Like the app list beside
  /// it, the page keeps Up and Down to itself; the list is reached with Left.
  KeyEventResult _handleTvScrollKey(FocusNode pane, KeyEvent event) {
    final down = tvUpDown(event);
    final focused = FocusManager.instance.primaryFocus;
    if (down == null || focused == null) return KeyEventResult.ignored;
    final viewportBox = _scrollViewKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox ||
        !viewportBox.hasSize ||
        !_tvScrollController.hasClients) {
      final next = tvNextInPane(pane, focused, down: down);
      if (next != null) tvMoveFocus(next, down: down);
      return KeyEventResult.handled;
    }
    // Whether [node] is in the scrolling details rather than the action bar.
    // Details scrolled off the bottom sit underneath the bar, so going by
    // position alone the bar's buttons would always look nearer.
    bool inDetails(FocusNode node) {
      var found = false;
      node.context?.visitAncestorElements((element) {
        found = element.widget.key == _scrollViewKey;
        return !found;
      });
      return found;
    }

    // Nothing below the action bar.
    if (down && !inDetails(focused)) return KeyEventResult.handled;
    final position = _tvScrollController.position;
    final viewport = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    final canScroll = down
        ? position.pixels < position.maxScrollExtent
        : position.pixels > position.minScrollExtent;
    // The details come first; the action bar only once they have run out.
    final next =
        tvNextInPane(pane, focused, down: down, where: inDetails) ??
        (canScroll ? null : tvNextInPane(pane, focused, down: down));
    final readingOn =
        focused is TvCardFocusNode &&
        (down
            ? focused.rect.bottom > viewport.bottom + 1
            : focused.rect.top < viewport.top - 1);
    if (canScroll && (readingOn || next == null)) {
      final step = viewport.height / 2;
      position.animateTo(
        (position.pixels + (down ? step : -step)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else if (next != null) {
      next.requestFocus();
      final nextContext = next.context;
      if (nextContext != null) {
        if (next.rect.height <= viewport.height) {
          Scrollable.ensureVisible(
            nextContext,
            alignmentPolicy: down
                ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
                : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          );
        } else {
          // Taller than the screen: open on its start going down, or on its
          // end coming back up, and read on from there.
          Scrollable.ensureVisible(nextContext, alignment: down ? 0 : 1);
        }
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final appsProvider = context.read<AppsProvider>();
    final settingsProvider = context.watch<SettingsProvider>();
    final showAppWebpageFinal =
        (settingsProvider.showAppWebpage &&
            !widget.showOppositeOfPreferredView) ||
        (!settingsProvider.showAppWebpage &&
            widget.showOppositeOfPreferredView);
    final bool areDownloadsRunning = context.select<AppsProvider, bool>(
      (p) => p.areDownloadsRunning(),
    );
    // Subscribe to this app's download progress so the page rebuilds as it
    // changes: DownloadState.progress is a ValueNotifier and does not notify
    // the provider's listeners.
    context.select<AppsProvider, double?>(
      (p) => p.apps[widget.appId]?.downloadProgress,
    );

    final AppInMemory? app = cachedApp(
      context.select<AppsProvider, AppInMemory?>((p) => p.apps[widget.appId]),
    );
    if (app != null &&
        app.downloadProgress == null &&
        !updating &&
        !areDownloadsRunning &&
        (app.app.installedVersion == null ||
            appHasOfferableUpdate(app.app, settingsProvider))) {
      // Probe from a post-frame callback: build must stay side-effect free, and
      // the key guard inside makes repeat scheduling a cheap no-op.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeProbeDownloadSize(app);
      });
    }
    final source = this.source;

    if (!areDownloadsRunning &&
        prevApp == null &&
        app != null &&
        settingsProvider.checkUpdateOnDetailPage) {
      prevApp = app;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) getUpdate(context);
      });
    }
    final trackOnly = app?.app.settings.getBool('trackOnly') == true;

    final certs = app != null && app.certificateHashes.isNotEmpty;
    final hasAssets =
        app?.app.apkUrls.isNotEmpty == true ||
        app?.app.otherAssetUrls.isNotEmpty == true;

    // The release notes are part of this page's first paint rather than
    // something that appears in it later, so the page waits for them. Notes
    // the update check already cached resolve without any wait at all; only a
    // fetch holds the page, and never past [_releaseNotesTimeout].
    final waitingForReleaseNotes = !_releaseNotesReady(app, settingsProvider);

    return Scaffold(
      appBar: showAppWebpageFinal ? _appScreenAppBar() : null,
      floatingActionButton: showAppWebpageFinal
          ? FloatingActionButton(
              onPressed: () {
                settingsProvider.selectionClick();
                NavHelper.pushAppPage(
                  context,
                  widget.appId,
                  showOppositeOfPreferredView: true,
                );
              },
              tooltip: tr('more'),
              child: const Icon(Icons.info_outline),
            )
          : null,
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: showAppWebpageFinal
          ? _getAppWebView(context, app)
          : waitingForReleaseNotes
          ? const Center(child: CircularProgressIndicator())
          : Focus(
              focusNode: _tvPaneFocus,
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: settingsProvider.isTV ? _handleTvScrollKey : null,
              onFocusChange: _onTvPaneFocusChange,
              child: Column(
                children: [
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async {
                        if (app != null) {
                          await getUpdate(context);
                        }
                      },
                      child: CustomScrollView(
                        key: _scrollViewKey,
                        // Phones keep the default primary controller.
                        controller: settingsProvider.isTV
                            ? _tvScrollController
                            : null,
                        slivers: [
                          SliverToBoxAdapter(
                            child: SizedBox(
                              height: MediaQuery.of(context).padding.top + 8,
                            ),
                          ),
                          _buildHeaderSection(app),
                          ..._buildRepoRenameSection(app, appsProvider),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacings.sectionGap),
                          ),
                          ..._buildVersionInfoSections(app),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacings.sectionGap),
                          ),
                          ..._buildSourceInfoSections(
                            app,
                            appsProvider,
                            certs,
                            hasAssets,
                          ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: AppSpacings.sectionGap),
                          ),
                          _buildCategorySection(app, appsProvider),
                          ..._buildReleaseNotesSections(app, settingsProvider),
                          ..._buildAboutSection(app),
                          const SliverToBoxAdapter(child: SizedBox(height: 32)),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      border: Border(
                        top: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: SafeArea(
                      top: false,
                      child: _buildActionsContent(
                        app,
                        appsProvider,
                        settingsProvider,
                        source,
                        showAppWebpageFinal,
                        trackOnly,
                        areDownloadsRunning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// The heading each release-notes section carries, so the two sections label
/// themselves identically.
Widget _releaseNotesHeader(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
  ),
);

Widget _releaseNotesPlaceholder(BuildContext context, String text) => Text(
  text,
  style: Theme.of(context).textTheme.bodySmall?.copyWith(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

/// One rendered release-notes card: its heading, the markdown to show, and the
/// line to show instead when there is no markdown.
class _ReleaseNotesSection {
  final String label;
  final String? notes;
  final String placeholder;

  const _ReleaseNotesSection({
    required this.label,
    required this.notes,
    required this.placeholder,
  });
}
