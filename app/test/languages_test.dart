import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/add_kid_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One language, for now.
///
/// Urdu is not offered. What is left is a single chip that cannot be unticked
/// and a "pick at least one language" error nobody can trigger, so the whole
/// section is gone rather than left standing as a question with one answer.
///
/// The machinery stays: Gilli still code-switches, still offers a word a
/// session, and a child who was given two languages while there were two keeps
/// them. A screen that stops asking a question is not a reason to answer it
/// for somebody who already did.
void main() {
  late AppState app;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    await app.refreshKids();
  });

  Future<void> openSheet(WidgetTester tester, {Kid? editing}) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => editing == null
                      ? showAddKidSheet(context)
                      : showEditKidSheet(context, editing),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('there is no language question left to answer', (tester) async {
    await openSheet(tester);

    expect(find.text('Urdu'), findsNothing);
    expect(find.text('LANGUAGES'), findsNothing);
    // The chip that would have been left is not worth a section of its own.
    expect(find.text('English'), findsNothing);
  });

  testWidgets('a child added now speaks English', (tester) async {
    await openSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save kid'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(app.kids.single.languages, ['en']);
  });

  testWidgets('a child who already speaks two keeps both', (tester) async {
    late Kid bilingual;
    await tester.runAsync(() async {
      bilingual = await gateway.createKid(
        nickname: 'Zara',
        age: 8,
        languages: const ['en', 'ur'],
      );
      await app.refreshKids();
    });
    await openSheet(tester, editing: bilingual);

    await tester.enterText(find.byType(TextField).first, 'Zara');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Correcting a nickname must not quietly take a language away.
    expect(app.kids.single.languages, ['en', 'ur']);
  });
}
