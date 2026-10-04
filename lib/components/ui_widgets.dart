import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

Future<void> copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('copiedToClipboard'))));
  }
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  Widget? content,
  String? confirmText,
  String? cancelText,
  bool autofocusConfirm = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: content,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelText ?? tr('no')),
        ),
        FilledButton(
          autofocus: autofocusConfirm,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmText ?? tr('yes')),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<bool> showContinueCancelDialog(
  BuildContext context, {
  required String title,
  String? message,
}) async {
  final result = await showDialog<Map<String, dynamic>?>(
    context: context,
    builder: (ctx) => GeneratedFormModal(
      title: title,
      items: const [],
      initValid: true,
      message: message ?? '',
    ),
  );
  return result != null;
}

void showMessage(dynamic e, BuildContext context, {bool isError = false}) {
  if (isError) context.read<SettingsProvider>().heavyImpact();
  if (isError) {
    AppLogger.error(e, message: e.toString());
  } else {
    AppLogger.info(e.toString());
  }
  if (e is String || (e is ObtainiumError && !e.unexpected)) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(e.toString())));
  } else {
    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          scrollable: true,
          title: Text(
            e is MultiAppMultiError
                ? tr(isError ? 'someErrors' : 'updates')
                : tr(isError ? 'unexpectedError' : 'unknown'),
          ),
          content: GestureDetector(
            onLongPress: () {
              unawaited(copyToClipboard(context, e.toString()));
            },
            child: Text(e.toString()),
          ),
          actions: [
            FilledButton.tonal(
              autofocus: context.read<SettingsProvider>().isTV,
              onPressed: () {
                Navigator.of(context).pop(null);
              },
              child: Text(tr('ok')),
            ),
          ],
        );
      },
    );
  }
}

void showError(dynamic e, BuildContext context) {
  showMessage(e, context, isError: true);
}

/// Dropdown menu that is operable with a TV remote.
///
/// Material's [DropdownMenu] makes its field non-focusable on Android
/// (`requestFocusOnTap` defaults to false), which leaves remote users unable to
/// reach or open it, and its menu entries are never focusable. On TV this
/// wrapper owns focus, draws a focus ring, and opens a picker dialog of
/// focusable rows with the select button. On touch devices it renders the
/// plain [DropdownMenu].
class TvDropdownMenu<T> extends StatefulWidget {
  const TvDropdownMenu({
    super.key,
    required this.initialSelection,
    required this.dropdownMenuEntries,
    this.onSelected,
    this.label,
    this.expandedInsets,
    this.width,
    this.leadingIcon,
    this.menuHeight,
    this.enabled = true,
  });

  final T? initialSelection;
  final List<DropdownMenuEntry<T>> dropdownMenuEntries;
  final ValueChanged<T?>? onSelected;
  final Widget? label;
  final EdgeInsetsGeometry? expandedInsets;
  final double? width;
  final Widget? leadingIcon;
  final double? menuHeight;
  final bool enabled;

  @override
  State<TvDropdownMenu<T>> createState() => _TvDropdownMenuState<T>();
}

class _TvDropdownMenuState<T> extends State<TvDropdownMenu<T>> {
  final FocusNode _focusNode = FocusNode();

  /// Keeps the field's ▾ button out of reach on TV. It sits inside
  /// [DropdownMenu]'s own shortcuts, which turn Up/Down into "move the menu
  /// highlight" and swallow them while the menu is closed, so a remote that
  /// landed on it could never leave.
  final FocusNode _trailingIconFocusNode = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void dispose() {
    _focusNode.dispose();
    _trailingIconFocusNode.dispose();
    super.dispose();
  }

  /// The TV picker. [DropdownMenu]'s entries are never focusable (it drives a
  /// highlight from the arrow keys of a focused field instead), so on TV the
  /// choices are offered as a dialog of focusable rows: the current value is
  /// focused, Select picks, Back cancels, and closing the dialog returns focus
  /// to this field.
  Future<void> _openPicker() async {
    context.read<SettingsProvider>().selectionClick();
    final picked = await showDialog<DropdownMenuEntry<T>>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: widget.label,
        children: [
          for (final entry in widget.dropdownMenuEntries)
            Builder(
              builder: (rowContext) => ListTile(
                autofocus: entry.value == widget.initialSelection,
                // Autofocus doesn't scroll, so in a list taller than the
                // dialog the current row would open focused but out of sight.
                onFocusChange: entry.value == widget.initialSelection
                    ? (focused) {
                        if (focused) {
                          Scrollable.ensureVisible(
                            rowContext,
                            alignmentPolicy:
                                ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                          );
                        }
                      }
                    : null,
                enabled: entry.enabled,
                selected: entry.value == widget.initialSelection,
                // Both states draw an icon of the same size, so the labels
                // line up whichever row is current.
                leading: Icon(
                  entry.value == widget.initialSelection
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(entry.label),
                onTap: () => Navigator.of(dialogContext).pop(entry),
              ),
            ),
        ],
      ),
    );
    if (picked != null) widget.onSelected?.call(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final isTV = context.select<SettingsProvider, bool>((p) => p.isTV);
    final dropdown = DropdownMenu<T>(
      initialSelection: widget.initialSelection,
      dropdownMenuEntries: widget.dropdownMenuEntries,
      onSelected: widget.onSelected,
      label: widget.label,
      expandedInsets: widget.expandedInsets,
      width: widget.width,
      leadingIcon: widget.leadingIcon,
      menuHeight: widget.menuHeight,
      enabled: widget.enabled,
      // Focus is owned by this wrapper on TV. On other platforms keep the
      // widget's own default (keyboard-focusable on desktop).
      requestFocusOnTap: isTV ? false : null,
      trailingIconFocusNode: isTV ? _trailingIconFocusNode : null,
    );
    if (!isTV || !widget.enabled) return dropdown;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          _openPicker();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListenableBuilder(
        listenable: _focusNode,
        builder: (context, child) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _focusNode.hasFocus
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  )
                : null,
            borderRadius: BorderRadius.circular(16),
          ),
          child: child,
        ),
        child: dropdown,
      ),
    );
  }
}

class AppIcon extends StatelessWidget {
  final Uint8List? bytes;
  final double size;
  final double radius;

  final double glyphSize;

  final bool dimmed;

  const AppIcon({
    super.key,
    required this.bytes,
    required this.size,
    this.radius = 12,
    this.glyphSize = 24,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheDim = (size * devicePixelRatio).round();
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: bytes != null
            ? Image.memory(
                bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                cacheWidth: cacheDim,
                cacheHeight: cacheDim,
                opacity: dimmed ? const AlwaysStoppedAnimation(0.6) : null,
              )
            : ColoredBox(
                color: colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Image(
                    image: const AssetImage('assets/graphics/icon_small.png'),
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.4),
                    colorBlendMode: BlendMode.modulate,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                    width: glyphSize,
                    height: glyphSize,
                  ),
                ),
              ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String? message;

  const EmptyState({super.key, required this.icon, this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                icon,
                size: 56,
                color: colorScheme.onSurfaceVariant,
                // The message is rendered below (announced once by the Text).
                semanticLabel: message,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(
                message!,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact "X" button used to cancel an in-progress download.
class DownloadCancelButton extends StatelessWidget {
  final VoidCallback onPressed;

  const DownloadCancelButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.close),
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      tooltip: tr('cancel'),
      onPressed: () {
        context.read<SettingsProvider>().lightImpact();
        onPressed();
      },
    );
  }
}

/// The control [pane]'s Up (or Down) key should move to from [focused], among
/// [pane]'s own focusable descendants only (and of those, only the ones
/// [where] accepts), or null when there is none that way. It goes to the
/// nearest row of controls that way, so nothing nearer is ever skipped for
/// something further off that happens to line up; within that row it prefers
/// controls in line with [focused] (overlapping it horizontally), then the one
/// whose left edge is closest. Unlike Flutter's own traversal it never picks
/// one from a neighbouring pane.
FocusNode? tvNextInPane(
  FocusNode pane,
  FocusNode focused, {
  required bool down,
  bool Function(FocusNode node)? where,
}) {
  // Controls whose near edges are this close count as one row.
  const rowSlack = 16.0;
  final from = focused.rect;
  double gapTo(Rect r) => down ? r.top - from.bottom : from.top - r.bottom;
  final ahead = <FocusNode>[];
  var nearestGap = double.infinity;
  for (final node in pane.traversalDescendants) {
    if (node == focused || (where != null && !where(node))) continue;
    final r = node.rect;
    if (down ? r.top < from.bottom - 1 : r.bottom > from.top + 1) continue;
    ahead.add(node);
    if (gapTo(r) < nearestGap) nearestGap = gapTo(r);
  }
  FocusNode? best;
  var bestInLine = false;
  var bestSideways = double.infinity;
  for (final node in ahead) {
    final r = node.rect;
    if (gapTo(r) > nearestGap + rowSlack) continue;
    final inLine = r.left < from.right && r.right > from.left;
    final sideways = (r.left - from.left).abs();
    if (best == null ||
        (inLine && !bestInLine) ||
        (inLine == bestInLine && sideways < bestSideways)) {
      best = node;
      bestInLine = inLine;
      bestSideways = sideways;
    }
  }
  return best;
}

/// Moves focus to [node] the way Flutter's own Up/Down traversal does,
/// scrolling it into view.
void tvMoveFocus(FocusNode node, {required bool down}) {
  FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
    node,
    alignmentPolicy: down
        ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
        : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
  );
}

/// Whether [event] is an Up or Down press (or repeat): true for Down, false for
/// Up, null for anything else, and null too while a text field has focus, which
/// keeps the keys for its caret.
bool? tvUpDown(KeyEvent event) {
  if (event is KeyUpEvent) return null;
  final focusedContext = FocusManager.instance.primaryFocus?.context;
  if (focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
    return null;
  }
  if (event.logicalKey == LogicalKeyboardKey.arrowDown) return true;
  if (event.logicalKey == LogicalKeyboardKey.arrowUp) return false;
  return null;
}

/// A `Focus.onKeyEvent` for one pane of the TV two-pane layout that keeps Up
/// and Down inside it. Off the top or bottom of a pane, Flutter's traversal
/// would land in whatever sits beside it; the other pane is reached with Left
/// or Right instead.
KeyEventResult tvPaneUpDown(FocusNode pane, KeyEvent event) {
  final down = tvUpDown(event);
  final focused = FocusManager.instance.primaryFocus;
  if (down == null || focused == null) return KeyEventResult.ignored;
  final next = tvNextInPane(pane, focused, down: down);
  if (next != null) tvMoveFocus(next, down: down);
  return KeyEventResult.handled;
}

/// Draws a high-contrast ring around whatever is focused inside [child].
///
/// Material's default focus treatment is a barely-visible overlay intended for
/// mouse/keyboard desktop use. On a TV the focus position is the only cursor,
/// so tiles/rows wrapped in this widget get a bright border whenever focus is
/// anywhere in their subtree. Does nothing on non-TV devices.
class TvFocusRing extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double width;
  final Color? color;

  const TvFocusRing({
    super.key,
    required this.child,
    this.borderRadius = connectedTileBigRadius,
    this.width = 3,
    this.color,
  });

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final isTV = context.select<SettingsProvider, bool>((p) => p.isTV);
    if (!isTV) return widget.child;
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (focused) {
        if (focused != _focused) setState(() => _focused = focused);
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _focused
              ? Border.all(color: color, width: widget.width)
              : null,
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: widget.child,
      ),
    );
  }
}

class ConnectedCard extends StatelessWidget {
  final Widget child;
  final bool isFirst;
  final bool isLast;
  final Color? color;
  final EdgeInsetsGeometry? padding;

  const ConnectedCard({
    super.key,
    required this.child,
    this.isFirst = true,
    this.isLast = true,
    this.color,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return CardTile(
      color: color,
      padding: padding ?? EdgeInsets.zero,
      borderRadius: positionalTileRadius(isFirst: isFirst, isLast: isLast),
      child: child,
    );
  }
}

/// The focus node of a [TvStopCard], so key handling can tell a card being
/// read from a control.
class TvCardFocusNode extends FocusNode {
  TvCardFocusNode() : super(debugLabel: 'TvStopCard');
}

/// A [ConnectedCard] that on TV is a remote stop of its own, for cards with no
/// control inside them. Focused, it takes the highlight a focused list row
/// has: the focus colour filled in under its content and a ring around its
/// edge, both inside the card's own shape so nothing moves. Elsewhere it is a
/// plain [ConnectedCard].
class TvStopCard extends StatefulWidget {
  final Widget child;
  final bool isFirst;
  final bool isLast;
  final EdgeInsetsGeometry? padding;

  const TvStopCard({
    super.key,
    required this.child,
    this.isFirst = true,
    this.isLast = true,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<TvStopCard> createState() => _TvStopCardState();
}

class _TvStopCardState extends State<TvStopCard> {
  final TvCardFocusNode _focusNode = TvCardFocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTV = context.select<SettingsProvider, bool>((p) => p.isTV);
    if (!isTV) {
      return ConnectedCard(
        isFirst: widget.isFirst,
        isLast: widget.isLast,
        padding: widget.padding,
        child: widget.child,
      );
    }
    return Focus(
      focusNode: _focusNode,
      child: ListenableBuilder(
        listenable: _focusNode,
        builder: (context, child) {
          final theme = Theme.of(context);
          final focused = _focusNode.hasPrimaryFocus;
          return DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: positionalTileRadius(
                  isFirst: widget.isFirst,
                  isLast: widget.isLast,
                ),
                side: focused
                    ? BorderSide(color: theme.colorScheme.primary, width: 3)
                    : BorderSide.none,
              ),
            ),
            child: ConnectedCard(
              isFirst: widget.isFirst,
              isLast: widget.isLast,
              padding: widget.padding,
              color: focused
                  ? Color.alphaBlend(
                      theme.focusColor,
                      theme.colorScheme.surfaceContainerLow,
                    )
                  : null,
              child: child!,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

class LinkText extends StatelessWidget {
  final String text;
  final String url;
  final TextStyle? style;

  const LinkText({
    super.key,
    required this.text,
    required this.url,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      child: TvFocusRing(
        borderRadius: 4,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => unawaited(
            launchUrlString(url, mode: LaunchMode.externalApplication),
          ),
          child: Text(
            text,
            style: (style ?? const TextStyle()).copyWith(
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    );
  }
}

class ActionListTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool autoPop;
  final BorderRadius? borderRadius;

  const ActionListTile({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.autoPop = false,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusRing(
      borderRadius: borderRadius?.topLeft.x ?? connectedTileBigRadius,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: trailing,
        enabled: onTap != null,
        shape: borderRadius != null
            ? RoundedRectangleBorder(borderRadius: borderRadius!)
            : null,
        onTap: onTap == null
            ? null
            : () {
                if (autoPop) Navigator.of(context).pop();
                onTap?.call();
              },
      ),
    );
  }
}

class CustomAppBar extends StatelessWidget {
  const CustomAppBar({super.key, required this.title, this.actions, this.logo});

  final String title;
  final List<Widget>? actions;

  /// Drawn just before [title], when given.
  final Widget? logo;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      // Root pages have nothing to pop so no leading is shown; pushed pages
      // (Settings, Add app) get the standard back button.
      automaticallyImplyLeading: true,
      title: logo == null
          ? Text(title)
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [logo!, Text(title)],
            ),
      actions: actions,
    );
  }
}

class _TileClipper extends CustomClipper<Path> {
  final RoundedSuperellipseBorder shape;
  const _TileClipper(this.shape);

  @override
  Path getClip(Size size) => shape.getOuterPath(Offset.zero & size);

  @override
  bool shouldReclip(_TileClipper oldClipper) =>
      oldClipper.shape.borderRadius != shape.borderRadius;
}

Future<void> showHelpDialog(
  BuildContext context, {
  required String title,
  required List<Widget> content,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: content,
      ),
      actions: [
        TextButton(
          autofocus: context.read<SettingsProvider>().isTV,
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(tr('ok')),
        ),
      ],
    ),
  );
}

ValueChanged<bool> hapticSwitchOnChanged(
  BuildContext context,
  ValueChanged<bool> onChanged,
) => (v) {
  context.read<SettingsProvider>().selectionClick();
  onChanged(v);
};

bool _isTile(Widget w) =>
    w is CardTile || w is ToggleTile || w is ConnectedCard;

Widget _wrapChildWithRadius(Widget w, BorderRadius radius) {
  if (w is CardTile) {
    return CardTile(
      key: w.key,
      padding: w.padding,
      borderRadius: radius,
      color: w.color,
      child: w.child,
    );
  }
  if (w is ToggleTile) {
    final r = radius;
    final isFirst = r.topLeft.x == connectedTileBigRadius;
    final isLast = r.bottomLeft.x == connectedTileBigRadius;
    return ConnectedCard(
      key: w.key,
      isFirst: isFirst,
      isLast: isLast,
      child: w,
    );
  }
  if (w is ConnectedCard) {
    final r = radius;
    final isFirst = r.topLeft.x == connectedTileBigRadius;
    final isLast = r.bottomLeft.x == connectedTileBigRadius;
    return ConnectedCard(
      key: w.key,
      isFirst: isFirst,
      isLast: isLast,
      color: w.color,
      padding: w.padding,
      child: w.child,
    );
  }
  return w;
}

List<Widget> shapeCardTiles(List<Widget> children) {
  final result = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    final w = children[i];
    if (!_isTile(w)) {
      result.add(w);
      continue;
    }
    final prevIsTile = i > 0 && _isTile(children[i - 1]);
    final nextIsTile = i < children.length - 1 && _isTile(children[i + 1]);
    result.add(
      _wrapChildWithRadius(
        w,
        positionalTileRadius(isFirst: !prevIsTile, isLast: !nextIsTile),
      ),
    );
  }
  return result;
}

class CardTile extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final Color? color;

  const CardTile({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
    this.borderRadius,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveRadius =
        borderRadius ?? BorderRadius.circular(connectedTileBigRadius);
    final shape = RoundedSuperellipseBorder(borderRadius: effectiveRadius);
    return ClipPath(
      clipper: _TileClipper(shape),
      child: Material(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class ToggleTile extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? subtitle;
  final List<Widget> helpWidgets;
  final bool noPadding;

  const ToggleTile({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.helpWidgets = const [],
    this.noPadding = false,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusRing(
      child: ListTile(
        contentPadding: noPadding
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 20),
        title: Text(label),
        subtitle: subtitle,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (helpWidgets.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: tr('about'),
                onPressed: () =>
                    showHelpDialog(context, title: label, content: helpWidgets),
              ),
            Switch(
              value: value,
              onChanged: onChanged == null
                  ? null
                  : hapticSwitchOnChanged(context, onChanged!),
            ),
          ],
        ),
      ),
    );
  }
}

class LegacyMaterialBridge extends StatelessWidget {
  final Widget child;

  const LegacyMaterialBridge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
    return MaterialUiCompatibilityBridge(child: child);
  }
}

class SectionHeader extends StatelessWidget {
  final String title;

  const SectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
