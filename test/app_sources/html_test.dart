import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/html.dart';

/// The bug from #39: scanning bare text for links stopped a URL only at
/// whitespace, so the quote that closes the URL in HTML/JSON was swallowed into
/// it. Tracking `https://api.pgsharp.com/download` that way stored
/// `https://api.pgsharp.com/download"`, which the host answers with a 404 -
/// surfaced to the user as "Not Found [PGSharp]".
void main() {
  group('trimUrlEnd', () {
    test('leaves a clean URL untouched', () {
      expect(
        trimUrlEnd('https://api.pgsharp.com/download'),
        'https://api.pgsharp.com/download',
      );
    });

    test('keeps parentheses the URL opened itself', () {
      expect(
        trimUrlEnd(
          'https://dl.pgsharp.com/pgs1.269.2_0.425.1_DvbwE(arm64).apk',
        ),
        'https://dl.pgsharp.com/pgs1.269.2_0.425.1_DvbwE(arm64).apk',
      );
    });

    test('drops a closing bracket the URL never opened', () {
      expect(trimUrlEnd('https://ex.com/a.apk)'), 'https://ex.com/a.apk');
      expect(trimUrlEnd('https://ex.com/a.apk]'), 'https://ex.com/a.apk');
      expect(trimUrlEnd('https://ex.com/a.apk}'), 'https://ex.com/a.apk');
    });

    test('drops prose punctuation', () {
      expect(trimUrlEnd('https://ex.com/a.apk,'), 'https://ex.com/a.apk');
      expect(trimUrlEnd('https://ex.com/a.apk.'), 'https://ex.com/a.apk');
    });

    test('drops a punctuation and bracket pile-up in one pass', () {
      expect(trimUrlEnd('https://ex.com/a.apk).'), 'https://ex.com/a.apk');
    });

    test('keeps balanced parens while dropping the unbalanced one', () {
      expect(trimUrlEnd('https://ex.com/a(b))'), 'https://ex.com/a(b)');
    });
  });

  group('getLinksInLines', () {
    test('stops at the quote closing a JSON string value', () {
      expect(
        getLinksInLines(
          '{"url":"https://api.pgsharp.com/download"}',
        ).map((e) => e.key),
        ['https://api.pgsharp.com/download'],
      );
    });

    test('stops at the quote closing an href attribute', () {
      expect(
        getLinksInLines(
          '<a href="https://ex.com/app.apk">Get</a>',
        ).map((e) => e.key),
        ['https://ex.com/app.apk'],
      );
    });

    test('stops at the quote closing a single-quoted JS string', () {
      expect(
        getLinksInLines("var u = 'https://ex.com/app.apk';").map((e) => e.key),
        ['https://ex.com/app.apk'],
      );
    });

    test('keeps an arch suffix in parens but drops the closing quote', () {
      expect(
        getLinksInLines('"https://dl.ex.com/app(arm64).apk"').map((e) => e.key),
        ['https://dl.ex.com/app(arm64).apk'],
      );
    });

    test('reports the filename without the swallowed delimiter', () {
      // The stored apkUrls key is built from this; #39 stored `download"`.
      expect(
        getLinksInLines(
          '{"url":"https://api.pgsharp.com/download"}',
        ).map((e) => e.value),
        ['download'],
      );
    });

    test('finds several links and trims each', () {
      expect(
        getLinksInLines(
          'a "https://ex.com/one.apk" and (https://ex.com/two.apk)',
        ).map((e) => e.key),
        ['https://ex.com/one.apk', 'https://ex.com/two.apk'],
      );
    });

    test('still matches a plain whitespace-delimited URL', () {
      expect(
        getLinksInLines('get https://ex.com/app.apk now').map((e) => e.key),
        ['https://ex.com/app.apk'],
      );
    });

    test('matches http and ftp as well as https', () {
      expect(
        getLinksInLines(
          'http://ex.com/a.apk ftp://ex.com/b.apk',
        ).map((e) => e.key),
        ['http://ex.com/a.apk', 'ftp://ex.com/b.apk'],
      );
    });

    test('discards a match trimmed back to a bare scheme', () {
      expect(getLinksInLines('https://,').map((e) => e.key), isEmpty);
    });

    test('finds nothing in text with no URL', () {
      expect(getLinksInLines('no links here'), isEmpty);
    });
  });
}
