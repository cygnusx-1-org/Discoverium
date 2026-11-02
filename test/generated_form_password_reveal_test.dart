import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';

/// Password fields (source tokens) are masked by default and can be revealed
/// with an eye button; any reveal is undone when the app leaves the
/// foreground.
void main() {
  Future<void> pumpForm(
    WidgetTester tester,
    List<List<GeneratedFormItem>> items,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: GeneratedForm(items: items, onValueChanges: (_, _, _) {}),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  bool obscured(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).obscureText;

  GeneratedFormTextField tokenField() => GeneratedFormTextField(
    'token',
    label: 'Token',
    value: 'secret-token',
    password: true,
    required: false,
    helpUrl: 'https://example.com/help',
  );

  testWidgets('eye button reveals and re-masks a password field', (
    tester,
  ) async {
    await pumpForm(tester, [
      [tokenField()],
    ]);
    expect(obscured(tester), isTrue);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(obscured(tester), isFalse);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(obscured(tester), isTrue);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
  });

  testWidgets('leaving the foreground re-masks a revealed field', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpForm(tester, [
      [tokenField()],
    ]);
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(obscured(tester), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(obscured(tester), isTrue);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('plain text fields get no eye button', (tester) async {
    await pumpForm(tester, [
      [GeneratedFormTextField('text', label: 'Text', value: '')],
    ]);
    expect(obscured(tester), isFalse);
    expect(find.byIcon(Icons.visibility), findsNothing);
  });
}
