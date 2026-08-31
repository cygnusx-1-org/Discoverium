import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

/// From #39: a Cloudflare challenge is a plain 403, so it was reported as a
/// rate limit ("try again in a minute") that never clears, or as a bare
/// "Forbidden". Waiting never helps - only a browser passes the check - so it
/// needs to be told apart from an actual rate limit.
///
/// Verified against the real host: `https://dl.pgsharp.com/...apk` answers
/// identical requests with 200 or with a 5723-byte `cf-mitigated: challenge`
/// interstitial, non-deterministically.
const _challengeBody =
    '<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>'
    '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js">'
    '</script></head><body></body></html>';

http.Response _res(int status, {Map<String, String>? headers, String? body}) =>
    http.Response(body ?? '', status, headers: headers ?? const {});

void main() {
  group('isBotProtectionResponse', () {
    test('detects the cf-mitigated header', () {
      expect(isBotProtectionResponse(cfMitigated: 'challenge'), isTrue);
    });

    test('ignores an absent or empty cf-mitigated header', () {
      expect(isBotProtectionResponse(cfMitigated: null), isFalse);
      expect(isBotProtectionResponse(cfMitigated: ''), isFalse);
    });

    test('detects the challenge page by body when no header is present', () {
      expect(isBotProtectionResponse(body: _challengeBody), isTrue);
    });

    test('does not flag an ordinary error body', () {
      expect(
        isBotProtectionResponse(body: '<html><body>Forbidden</body></html>'),
        isFalse,
      );
    });
  });

  group('getObtainiumHttpError', () {
    test('a challenged 403 is a BotProtectionError, not a rate limit', () {
      final err = getObtainiumHttpError(
        _res(403, headers: {'cf-mitigated': 'challenge'}, body: _challengeBody),
      );
      expect(err, isA<BotProtectionError>());
      expect(err.code, 'BOT_PROTECTION');
    });

    test('a challenge page without the header is still detected', () {
      final err = getObtainiumHttpError(_res(403, body: _challengeBody));
      expect(err, isA<BotProtectionError>());
    });

    test('a 503 challenge is detected too', () {
      final err = getObtainiumHttpError(_res(503, body: _challengeBody));
      expect(err, isA<BotProtectionError>());
    });

    test('a plain 403 is still reported as a rate limit', () {
      final err = getObtainiumHttpError(_res(403));
      expect(err, isA<RateLimitError>());
    });

    test('a 429 is still reported as a rate limit', () {
      final err = getObtainiumHttpError(_res(429));
      expect(err, isA<RateLimitError>());
    });

    test('a 404 still wins over the challenge check', () {
      expect(getObtainiumHttpError(_res(404)), isA<NoReleasesError>());
    });

    test('a non-challenge body is not scanned on an unrelated status', () {
      // 500 never carries a challenge, so the body is not consulted at all.
      final err = getObtainiumHttpError(_res(500, body: _challengeBody));
      expect(err, isNot(isA<BotProtectionError>()));
    });
  });
}
