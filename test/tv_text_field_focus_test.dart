import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/generated_form_renderer.dart';

/// The TV focus ring around a text field must not move or resize the field:
/// focusing a field draws the ring over it, it does not pad it.
void main() {
  testWidgets('focus ring leaves the field on the same pixels', (tester) async {
    final textFocus = FocusNode();
    addTearDown(textFocus.dispose);
    const fieldKey = Key('field');
    const belowKey = Key('below');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TvTextFieldFocus(
                textFocusNode: textFocus,
                autofocus: true,
                child: TextField(key: fieldKey, focusNode: textFocus),
              ),
              const SizedBox(key: belowKey, height: 10),
            ],
          ),
        ),
      ),
    );
    final field = tester.getRect(find.byKey(fieldKey));
    final below = tester.getRect(find.byKey(belowKey));

    // The autofocus request lands after the first frame.
    await tester.pump();
    final ring = find.descendant(
      of: find.byType(TvTextFieldFocus),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    );
    expect(ring, findsOneWidget);
    expect(tester.getRect(find.byKey(fieldKey)), field);
    expect(tester.getRect(find.byKey(belowKey)), below);
  });
}
