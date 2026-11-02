import 'dart:async';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Every markdown surface in the app renders through this widget.
///
/// `flutter_markdown_plus` still reads `package:flutter/material.dart`'s
/// [Theme], which this app no longer installs anywhere above it — so without
/// [LegacyMaterialBridge] its `Theme.of` falls back to Flutter's built-in
/// light theme and the markdown comes out near-black on the dark surface.
/// Funnelling every call site through one widget is what stops that bridge
/// from being forgotten at one of them, and gives the goldens in
/// `test/goldens/app_markdown_golden_test.dart` a single surface to pin.
class AppMarkdown extends StatelessWidget {
  const AppMarkdown({
    super.key,
    required this.data,
    this.resolveLink,
    this.softLineBreak = false,
  });

  /// The markdown to render.
  final String data;

  /// Turns a tapped link into the URL to open, so a relative link can be
  /// resolved against the page the markdown came from. When null, a link is
  /// opened exactly as written.
  final String Function(String href)? resolveLink;

  /// Whether a single newline inside a paragraph breaks the line, the way
  /// GitHub renders release notes, rather than joining the two lines.
  final bool softLineBreak;

  @override
  Widget build(BuildContext context) {
    // Read outside the bridge, from the modern theme: the bridge maps the
    // colour scheme and the text theme across to the legacy [ThemeData] but
    // not cardColor, so the blockquote has to come from this side.
    final blockquoteColor = Theme.of(context).cardColor;
    return LegacyMaterialBridge(
      child: MarkdownBody(
        data: data,
        softLineBreak: softLineBreak,
        styleSheet: MarkdownStyleSheet(
          blockquoteDecoration: BoxDecoration(color: blockquoteColor),
        ),
        onTapLink: (text, href, title) {
          if (href == null) return;
          unawaited(
            launchUrlString(
              resolveLink?.call(href) ?? href,
              mode: LaunchMode.externalApplication,
            ),
          );
        },
        extensionSet: md.ExtensionSet(
          md.ExtensionSet.gitHubFlavored.blockSyntaxes,
          [md.EmojiSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
        ),
      ),
    );
  }
}
