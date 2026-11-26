import 'dart:io';
import 'dart:typed_data';

// Deprecated since Flutter 3.47, but the harness has to read the legacy theme
// that flutter_markdown_plus still renders against.
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/theme.dart';

/// The seed the goldens are recorded with. A fixed seed rather than the
/// settings default so a change to the default theme colour cannot silently
/// rewrite every golden.
const Color goldenSeedColor = Color(0xFF6750A4);

/// Families the shipped font is registered under, so every text run in a
/// golden draws real glyphs instead of the test framework's placeholder boxes.
///
/// The aliases are what make a *failing* golden legible. A subtree that has
/// lost its [LegacyMaterialBridge] falls back to Flutter's built-in theme,
/// which asks for `Roboto` (and `monospace` for markdown's code spans, and the
/// binding's own `FlutterTest` default when a style names no family at all) —
/// none of which a test process has. Without the aliases the broken render is
/// a wall of boxes: the right colours, but nothing that shows what the user
/// would actually see. With them it reads the way the device does, dark text
/// on a dark card.
const List<String> _goldenFontFamilies = [
  'Montserrat',
  'Roboto',
  'monospace',
  'FlutterTest',
];

/// Loads the font the app actually ships. Call once per suite.
Future<void> loadAppFont() async {
  final Uint8List bytes = File(
    'assets/fonts/Montserrat-Regular.ttf',
  ).readAsBytesSync();
  for (final family in _goldenFontFamilies) {
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

/// Pins the surface so a golden is the same pixels on every machine.
void useFixedSurface(WidgetTester tester, {Size size = const Size(700, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The app's own theme at [brightness], built the way `main.dart` builds it.
ThemeData goldenTheme(Brightness brightness) => buildObtainiumTheme(
  ColorScheme.fromSeed(seedColor: goldenSeedColor, brightness: brightness),
  'Montserrat',
);

/// A widget under the app's real theme, in an app shell that mirrors
/// `main.dart`: a `material_ui` [MaterialApp] with **no** app-wide
/// compatibility bridge. That absence is the point — it is what makes a
/// subtree that forgets [LegacyMaterialBridge] render against Flutter's
/// built-in light theme, which is the defect these goldens exist to catch.
Widget goldenApp(Brightness brightness, {required Widget child}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: goldenTheme(brightness),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  ),
);

/// Asserts that the legacy `package:flutter/material.dart` theme resolved at
/// [subtree] is the app's theme and not Flutter's built-in fallback.
///
/// This is the same defect the goldens catch, stated as a claim instead of as
/// pixels: it names the surface that is missing its bridge, and it holds for
/// any legacy-package subtree, not only the ones a golden happens to render.
void expectLegacyThemeBridged(
  WidgetTester tester,
  Finder subtree,
  Brightness expected, {
  required String describedAs,
}) {
  final String what = describedAs;
  final legacy.ThemeData resolved = legacy.Theme.of(
    tester.element(subtree.first),
  );
  final ColorScheme appScheme = goldenTheme(expected).colorScheme;
  expect(
    resolved.brightness,
    expected,
    reason:
        '$what resolves the legacy Material fallback theme; its subtree is '
        'missing a LegacyMaterialBridge.',
  );
  expect(
    resolved.colorScheme.onSurface,
    appScheme.onSurface,
    reason: '$what does not paint text in the app theme\'s onSurface colour.',
  );
  expect(
    resolved.colorScheme.surface,
    appScheme.surface,
    reason: '$what does not resolve the app theme\'s surface colour.',
  );
}
