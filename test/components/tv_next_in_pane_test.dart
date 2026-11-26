import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/ui_widgets.dart';

void main() {
  // The TV details pane in miniature: two cards wholly on screen, a third the
  // action bar cuts off part-way (it carries on underneath the bar, as the
  // details do), a fourth scrolled off the top, and a button in the bar.
  const viewport = Rect.fromLTRB(0, 0, 800, 400);
  final pane = FocusNode(debugLabel: 'pane');
  final above = FocusNode(debugLabel: 'scrolled off the top');
  final first = FocusNode(debugLabel: 'first card');
  final second = FocusNode(debugLabel: 'second card');
  final cutOff = FocusNode(debugLabel: 'cut-off card');
  final button = FocusNode(debugLabel: 'bar button');

  tearDownAll(() {
    for (final node in [pane, above, first, second, cutOff, button]) {
      node.dispose();
    }
  });

  Widget stop(FocusNode node, Rect rect) => Positioned.fromRect(
    rect: rect,
    child: Focus(focusNode: node, child: const SizedBox.expand()),
  );

  Future<void> pumpPane(WidgetTester tester) => tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Focus(
        focusNode: pane,
        canRequestFocus: false,
        skipTraversal: true,
        child: Stack(
          children: [
            stop(above, const Rect.fromLTRB(16, -200, 784, -100)),
            stop(first, const Rect.fromLTRB(16, 0, 784, 100)),
            stop(second, const Rect.fromLTRB(16, 120, 784, 220)),
            stop(cutOff, const Rect.fromLTRB(16, 240, 784, 700)),
            stop(button, const Rect.fromLTRB(16, 420, 64, 460)),
          ],
        ),
      ),
    ),
  );

  bool card(FocusNode node) => node != button;

  testWidgets('Up from the bar skips a card the bar cuts off', (tester) async {
    await pumpPane(tester);
    expect(tvNextInPane(pane, button, down: false, where: card), same(second));
  });

  testWidgets('Up from the bar within the screen lands on the cut-off card', (
    tester,
  ) async {
    await pumpPane(tester);
    expect(
      tvNextInPane(pane, button, down: false, where: card, within: viewport),
      same(cutOff),
    );
  });

  testWidgets('within passes over what is off the screen entirely', (
    tester,
  ) async {
    await pumpPane(tester);
    expect(tvNextInPane(pane, first, down: false), same(above));
    expect(tvNextInPane(pane, first, down: false, within: viewport), isNull);
  });
}
