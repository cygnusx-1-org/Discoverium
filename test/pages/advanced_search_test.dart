import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/advanced_search.dart';
import 'package:obtainium/providers/source_provider.dart';

/// A search result from the "F-Droid third-party repo" source pointed at
/// IzzyOnDroid — the exact URL shape [FDroidRepo.search] builds from that
/// repo's `index-v2.json` base, and the one that broke in #54.
const izzyRepoUrl =
    'https://apt.izzysoft.de/fdroid/repo?appId=com.aurora.store';
const izzyRepoUrl2 =
    'https://apt.izzysoft.de/fdroid/repo?appId=com.aurora.store.nightly';

/// The same, for a repo on a host no source claims.
const otherRepoUrl = 'https://fdroid.example.org/fdroid/repo?appId=a.b';

const githubUrl = 'https://github.com/ImranR98/Obtainium';
const githubUrl2 = 'https://github.com/cygnusx-1-org/Discoverium';

AddAppsBatch batchFor(List<AddAppsBatch> batches, String url) =>
    batches.firstWhere((b) => b.urls.contains(url));

void main() {
  late SourceProvider sourceProvider;

  setUp(() => sourceProvider = SourceProvider());

  group('host detection alone (the #54 precondition)', () {
    test('claims an F-Droid repo URL for the IzzyOnDroid source', () {
      expect(
        sourceProvider.getSource(izzyRepoUrl).sourceIdentifier,
        'IzzyOnDroid',
      );
    });

    test('and that source rejects the URL, which is the reported error', () {
      final source = sourceProvider.getSource(izzyRepoUrl);
      expect(
        () => source.standardizeUrl(izzyRepoUrl),
        throwsA(isA<InvalidURLError>()),
      );
    });

    test('falls back to HTML for a repo on an unclaimed host', () {
      expect(sourceProvider.getSource(otherRepoUrl).sourceIdentifier, 'HTML');
    });
  });

  group('sourceOverrideFor', () {
    test('overrides when host detection would pick a different source', () {
      final source = sourceOverrideFor(
        sourceProvider,
        izzyRepoUrl,
        'FDroidRepo',
      );
      expect(source?.sourceIdentifier, 'FDroidRepo');
    });

    test('the overridden source accepts the URL untouched', () {
      final source = sourceOverrideFor(
        sourceProvider,
        izzyRepoUrl,
        'FDroidRepo',
      )!;
      expect(source.standardizeUrl(izzyRepoUrl), izzyRepoUrl);
    });

    test('overrides on a host no source claims, rather than leaving HTML', () {
      expect(
        sourceOverrideFor(
          sourceProvider,
          otherRepoUrl,
          'FDroidRepo',
        )?.sourceIdentifier,
        'FDroidRepo',
      );
    });

    test('does not override when host detection is already right', () {
      expect(sourceOverrideFor(sourceProvider, githubUrl, 'GitHub'), isNull);
    });
  });

  group('groupUrlsBySource', () {
    test('adds an IzzyOnDroid repo result under FDroidRepo (#54)', () {
      final batches = groupUrlsBySource(
        sourceProvider,
        [izzyRepoUrl],
        sourceIdentifiers: {izzyRepoUrl: 'FDroidRepo'},
      );
      expect(batches, hasLength(1));
      expect(batches.single.source?.sourceIdentifier, 'FDroidRepo');
      expect(batches.single.urls, [izzyRepoUrl]);
    });

    test('leaves a correctly detected result without an override', () {
      final batches = groupUrlsBySource(
        sourceProvider,
        [githubUrl],
        sourceIdentifiers: {githubUrl: 'GitHub'},
      );
      expect(batches.single.source, isNull);
    });

    test('falls back to host detection for a URL with no known source', () {
      final batches = groupUrlsBySource(sourceProvider, [
        izzyRepoUrl,
      ], sourceIdentifiers: const {});
      expect(batches.single.source, isNull);
    });

    test('makes one call per source, keeping every URL exactly once', () {
      final urls = [
        githubUrl,
        izzyRepoUrl,
        githubUrl2,
        izzyRepoUrl2,
        otherRepoUrl,
      ];
      final batches = groupUrlsBySource(
        sourceProvider,
        urls,
        sourceIdentifiers: {
          githubUrl: 'GitHub',
          githubUrl2: 'GitHub',
          izzyRepoUrl: 'FDroidRepo',
          izzyRepoUrl2: 'FDroidRepo',
          otherRepoUrl: 'FDroidRepo',
        },
      );
      expect(batches, hasLength(3));
      expect(
        batches.expand((b) => b.urls),
        unorderedEquals(urls),
        reason: 'no URL may be dropped or added twice',
      );
      expect(batchFor(batches, githubUrl).urls, [githubUrl, githubUrl2]);
      expect(batchFor(batches, izzyRepoUrl).urls, [izzyRepoUrl, izzyRepoUrl2]);
      expect(batchFor(batches, otherRepoUrl).urls, [otherRepoUrl]);
    });

    test('does not share one overridden source across hosts', () {
      final batches = groupUrlsBySource(
        sourceProvider,
        [izzyRepoUrl, otherRepoUrl],
        sourceIdentifiers: {
          izzyRepoUrl: 'FDroidRepo',
          otherRepoUrl: 'FDroidRepo',
        },
      );
      expect(batches, hasLength(2));
      // getSource() rewrites an overridden source's hosts to the URL's own
      // host, so a shared instance would send one repo's request to the other.
      for (final batch in batches) {
        expect(batch.source?.hosts, [Uri.parse(batch.urls.single).host]);
      }
    });

    test('an explicit sourceOverride applies to every URL', () {
      final override = sourceProvider.getSource(
        'https://apt.izzysoft.de',
        overrideSource: 'FDroidRepo',
      );
      final batches = groupUrlsBySource(
        sourceProvider,
        [izzyRepoUrl, githubUrl],
        sourceOverride: override,
        sourceIdentifiers: {githubUrl: 'GitHub'},
      );
      expect(batches, hasLength(1));
      expect(batches.single.source, same(override));
      expect(batches.single.urls, [izzyRepoUrl, githubUrl]);
    });

    test('returns nothing for an empty selection', () {
      expect(
        groupUrlsBySource(
          sourceProvider,
          const [],
          sourceIdentifiers: const {},
        ),
        isEmpty,
      );
    });
  });
}
