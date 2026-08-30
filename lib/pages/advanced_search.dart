import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/import_export.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';

/// One `addAppsByURL` call: the URLs to add, and the source to add them under
/// (null meaning "let host-based detection choose").
class AddAppsBatch {
  final AppSource? source;
  final List<String> urls;
  const AddAppsBatch(this.source, this.urls);
}

/// The source to add [url] under, given that [sourceIdentifier] produced it, or
/// null when plain host-based detection already picks the right source.
///
/// Search results don't always live on a host their own source claims — an
/// F-Droid third-party repo has no hosts at all and is `neverAutoSelect`, so
/// e.g. an IzzyOnDroid repo result (`apt.izzysoft.de/fdroid/repo?appId=...`)
/// would be detected as the IzzyOnDroid source and rejected, since that source
/// only accepts `/fdroid/index/apk/<id>` URLs.
AppSource? sourceOverrideFor(
  SourceProvider sourceProvider,
  String url,
  String sourceIdentifier,
) {
  try {
    if (sourceProvider.getSource(url).sourceIdentifier == sourceIdentifier) {
      return null;
    }
  } on ObtainiumError {
    // No source claims this host, so the result's own source must be used.
  }
  try {
    return sourceProvider.getSource(url, overrideSource: sourceIdentifier);
  } on ObtainiumError {
    // The URL is unusable (`preStandardizeUrl` rejects it). Leaving it
    // unoverridden keeps the failure where addAppsByURL can report it against
    // this one URL, rather than aborting the whole selection here.
    return null;
  }
}

/// Splits [selectedUrls] into the fewest `addAppsByURL` calls that still add
/// each URL under the source that produced it.
///
/// [sourceIdentifiers] maps a URL to that source; URLs it covers are added
/// under an override whenever host detection would pick a different source.
/// [sourceOverride] forces one source for every URL instead.
List<AddAppsBatch> groupUrlsBySource(
  SourceProvider sourceProvider,
  List<String> selectedUrls, {
  AppSource? sourceOverride,
  Map<String, String> sourceIdentifiers = const {},
}) {
  if (selectedUrls.isEmpty) return const [];
  // A caller-supplied source is already configured for these URLs and applies
  // to all of them.
  if (sourceOverride != null) {
    return [AddAppsBatch(sourceOverride, List.of(selectedUrls))];
  }

  // Derived overrides are not interchangeable: getSource() rewrites an
  // overridden source's hosts to the URL's own host, so URLs may only share a
  // source instance if they share a host too.
  final batches = <String, List<String>>{};
  final overrides = <String, AppSource?>{};
  for (final url in selectedUrls) {
    AppSource? override;
    final sourceIdentifier = sourceIdentifiers[url];
    if (sourceIdentifier != null) {
      override = sourceOverrideFor(sourceProvider, url, sourceIdentifier);
    }
    // The host must come off the same normalized URL getSource() built the
    // override from; reading it off the raw one reports '' for a schemeless
    // URL, which would let two hosts share a single override instance.
    final key = override == null
        ? ''
        : '${override.sourceIdentifier}|${Uri.parse(preStandardizeUrl(url)).host}';
    (batches[key] ??= []).add(url);
    overrides[key] = override;
  }
  return batches.entries
      .map((e) => AddAppsBatch(overrides[e.key], e.value))
      .toList();
}

/// Source-driven search, as opposed to the curated repo browsing on the Search
/// page: query a single app source, or several at once, and bulk-add results.
class AdvancedSearchPage extends StatefulWidget {
  const AdvancedSearchPage({super.key});

  @override
  State<AdvancedSearchPage> createState() => _AdvancedSearchPageState();
}

class _AdvancedSearchPageState extends State<AdvancedSearchPage> {
  final SourceProvider sourceProvider = SourceProvider();

  bool multiSourceSearching = false;
  bool singleSourceSearching = false;
  String multiSourceSearchQuery = '';

  bool get doingSomething => multiSourceSearching || singleSourceSearching;

  List<AppSource> get searchableSources =>
      sourceProvider.sources.where((e) => e.canSearch).toList();

  Map<String, List<String>> get sourceEntries => {
    for (final s in searchableSources) s.name: [s.name],
  };

  /// Adds the URLs the user selected, reporting per-URL failures.
  ///
  /// [sourceIdentifiers] maps a URL to the source that returned it; URLs it
  /// covers are added under that source when host detection would pick a
  /// different one. [sourceOverride] forces one source for every URL instead.
  /// Both are required so a caller can't silently drop the source a result
  /// came from — that is exactly how #54 was introduced.
  Future<void> _addSelected(
    List<String> selectedUrls, {
    required AppSource? sourceOverride,
    required Map<String, String> sourceIdentifiers,
  }) async {
    if (selectedUrls.isEmpty) return;
    final appsProvider = context.read<AppsProvider>();
    final errors = <List<String>>[];
    for (final batch in groupUrlsBySource(
      sourceProvider,
      selectedUrls,
      sourceOverride: sourceOverride,
      sourceIdentifiers: sourceIdentifiers,
    )) {
      errors.addAll(
        await appsProvider.addAppsByURL(
          batch.urls,
          sourceOverride: batch.source,
        ),
      );
    }
    if (!mounted) return;
    if (errors.isEmpty) {
      showMessage(
        tr('importedX', args: [plural('apps', selectedUrls.length)]),
        context,
      );
    } else {
      unawaited(
        showDialog(
          context: context,
          builder: (BuildContext ctx) => ImportErrorDialog(
            urlsLength: selectedUrls.length,
            errors: errors,
          ),
        ),
      );
    }
  }

  Future<void> _runMultiSourceSearch() async {
    setState(() => multiSourceSearching = true);
    final settingsProvider = context.read<SettingsProvider>();
    final appsProvider = context.read<AppsProvider>();
    try {
      final entries = sourceEntries;
      final searchSources =
          await showDialog<List<String>?>(
            context: context,
            builder: (BuildContext ctx) => SelectionModal(
              title: tr('selectX', args: [plural('source', 2).toLowerCase()]),
              entries: entries,
              selectedByDefault: true,
              onlyOneSelectionAllowed: false,
              titlesAreLinks: false,
              deselectThese: settingsProvider.searchDeselected,
            ),
          ) ??
          [];
      if (searchSources.isEmpty) return;
      settingsProvider.searchDeselected = entries.keys
          .where((s) => !searchSources.contains(s))
          .toList();

      final selected = searchableSources
          .where((e) => searchSources.contains(e.name))
          .toList();

      // Sources that need extra query options ask for them up front, one at a
      // time, so the dialogs don't stack.
      final Map<AppSource, Map<String, dynamic>> querySettings = {};
      for (final source in selected) {
        if (!source.includeAdditionalOptsInMainSearch) {
          querySettings[source] = {};
          continue;
        }
        if (!mounted) return;
        final values = await showDialog<Map<String, dynamic>?>(
          context: context,
          builder: (BuildContext ctx) => GeneratedFormModal(
            title: tr('searchX', args: [source.name]),
            items: [
              ...source.searchQuerySettingFormItems.map((e) => [e]),
              [_sourceUrlField(source, appsProvider)],
            ],
          ),
        );
        if (values == null) return;
        querySettings[source] = values;
      }

      final results = <MapEntry<String, Map<String, List<String>>>>[];
      await Future.wait(
        querySettings.entries.map((entry) async {
          try {
            final res = await entry.key.search(
              multiSourceSearchQuery,
              querySettings: entry.value,
            );
            results.add(MapEntry(entry.key.sourceIdentifier, res));
          } catch (err) {
            final errorToShow = err is ObtainiumError
                ? ObtainiumError(
                    err.message,
                    code: err.code,
                    unexpected: true,
                    stack: err.stack,
                    data: err.data,
                  )
                : err;
            if (mounted) showError(errorToShow, context);
          }
        }),
      );

      // Interleave results so no single source dominates the top of the list.
      final interleaved = <String, MapEntry<String, List<String>>>{};
      var index = 0;
      var done = false;
      while (!done) {
        done = true;
        for (final r in results) {
          if (r.value.length > index) {
            done = false;
            final single = r.value.entries.elementAt(index);
            interleaved[single.key] = MapEntry(r.key, single.value);
          }
        }
        index++;
      }
      if (interleaved.isEmpty) {
        throw ObtainiumError(tr('noResults'));
      }

      if (!mounted) return;
      final selectedUrls =
          await showDialog<List<String>?>(
            context: context,
            builder: (BuildContext ctx) => SelectionModal(
              entries: interleaved.map((k, v) => MapEntry(k, v.value)),
              selectedByDefault: false,
              onlyOneSelectionAllowed: false,
            ),
          ) ??
          [];
      await _addSelected(
        selectedUrls,
        sourceOverride: null,
        sourceIdentifiers: interleaved.map((k, v) => MapEntry(k, v.key)),
      );
    } catch (e) {
      if (mounted) showError(e, context);
    } finally {
      if (mounted) setState(() => multiSourceSearching = false);
    }
  }

  /// URL / source-override field, pre-filled with the source's default host and
  /// offering the hosts already in use by the user's apps.
  GeneratedFormTextField _sourceUrlField(
    AppSource source,
    AppsProvider appsProvider,
  ) {
    return GeneratedFormTextField(
      'url',
      label: source.hosts.isNotEmpty
          ? tr('overrideSource')
          : plural('url', 1).substring(2),
      autoCompleteOptions: [
        if (source.hosts.isNotEmpty) source.hosts[0],
        ...appsProvider.apps.values
            .where(
              (a) =>
                  sourceProvider
                      .getSource(
                        a.app.url,
                        overrideSource: a.app.overrideSource,
                      )
                      .sourceIdentifier ==
                  source.sourceIdentifier,
            )
            .map((a) {
              final uri = Uri.parse(a.app.url);
              return '${uri.origin}${uri.path}';
            }),
      ],
      value: source.hosts.isNotEmpty ? source.hosts[0] : '',
      required: true,
    );
  }

  Future<void> _runSingleSourceSearch(AppSource source) async {
    final appsProvider = context.read<AppsProvider>();
    try {
      final values = await showDialog<Map<String, dynamic>?>(
        context: context,
        builder: (BuildContext ctx) => GeneratedFormModal(
          title: tr('searchX', args: [source.name]),
          items: [
            [
              GeneratedFormTextField(
                'searchQuery',
                label: tr('searchQuery'),
                required: source.name != FDroidRepo().name,
              ),
            ],
            ...source.searchQuerySettingFormItems.map((e) => [e]),
            [_sourceUrlField(source, appsProvider)],
          ],
        ),
      );
      if (values == null || !mounted) return;

      setState(() => singleSourceSearching = true);
      var effectiveSource = source;
      if (source.hosts.isEmpty || values['url'] != source.hosts[0]) {
        effectiveSource = sourceProvider.getSource(
          values['url'],
          overrideSource: source.sourceIdentifier,
        );
      }
      final urlsWithDescriptions = await effectiveSource.search(
        values['searchQuery'] as String,
        querySettings: values,
      );
      if (urlsWithDescriptions.isEmpty) {
        throw ObtainiumError(tr('noResults'));
      }
      if (!mounted) return;
      final selectedUrls =
          await showDialog<List<String>?>(
            context: context,
            builder: (BuildContext ctx) =>
                SelectionModal(entries: urlsWithDescriptions),
          ) ??
          [];
      await _addSelected(
        selectedUrls,
        sourceOverride: effectiveSource,
        sourceIdentifiers: const {},
      );
    } catch (e) {
      if (mounted) showError(e, context);
    } finally {
      if (mounted) setState(() => singleSourceSearching = false);
    }
  }

  Future<void> _pickSourceThenSearch() async {
    final picked =
        await showDialog<List<String>?>(
          context: context,
          builder: (BuildContext ctx) => SelectionModal(
            title: tr('selectX', args: [tr('source').toLowerCase()]),
            entries: sourceEntries,
            selectedByDefault: false,
            onlyOneSelectionAllowed: true,
            titlesAreLinks: false,
          ),
        ) ??
        [];
    if (!mounted) return;
    final source = searchableSources
        .where((e) => picked.contains(e.name))
        .firstOrNull;
    if (source != null) await _runSingleSourceSearch(source);
  }

  @override
  Widget build(BuildContext context) {
    final sources = searchableSources;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(title: Text(tr('advancedSearch'))),
      body: sources.isEmpty
          ? EmptyState(
              icon: Icons.search_off,
              message: tr('noSearchableSources'),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              children: [
                SectionHeader(title: tr('singleSource')),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: doingSomething ? null : _pickSourceThenSearch,
                  child: Text(
                    tr('searchX', args: [tr('source').toLowerCase()]),
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                SectionHeader(title: tr('multipleSources')),
                const SizedBox(height: 8),
                Row(
                  spacing: 16,
                  children: [
                    Expanded(
                      child: GeneratedForm(
                        items: [
                          [
                            GeneratedFormTextField(
                              'searchSomeSources',
                              label: tr('searchSomeSourcesLabel'),
                              required: false,
                            ),
                          ],
                        ],
                        onValueChanges: (values, valid, isBuilding) {
                          if (values.isNotEmpty && valid && !isBuilding) {
                            setState(() {
                              multiSourceSearchQuery =
                                  (values['searchSomeSources'] ?? '')
                                      .toString()
                                      .trim();
                            });
                          }
                        },
                      ),
                    ),
                    multiSourceSearching
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton.tonal(
                            onPressed:
                                multiSourceSearchQuery.isEmpty || doingSomething
                                ? null
                                : _runMultiSourceSearch,
                            child: Text(tr('search')),
                          ),
                  ],
                ),
                if (doingSomething) ...[
                  const SizedBox(height: 24),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    tr('searchingPleaseWait'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
    );
  }
}
