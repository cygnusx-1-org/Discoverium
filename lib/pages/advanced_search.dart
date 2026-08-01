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
  Future<void> _addSelected(
    List<String> selectedUrls, {
    AppSource? sourceOverride,
  }) async {
    if (selectedUrls.isEmpty) return;
    final appsProvider = context.read<AppsProvider>();
    final errors = await appsProvider.addAppsByURL(
      selectedUrls,
      sourceOverride: sourceOverride,
    );
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
      await _addSelected(selectedUrls);
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
      await _addSelected(selectedUrls, sourceOverride: effectiveSource);
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
