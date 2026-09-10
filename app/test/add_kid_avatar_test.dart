import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/add_kid_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A starting picture, chosen while adding a child.
///
/// Optional, and not the last word: the picture belongs to the child, who can
/// change it in kid mode. This only saves them starting with a blank initial.
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

  Future<void> save(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Finder face(String name) => find.byKey(ValueKey('avatar-$name'));

  testWidgets('every picture the child could choose is offered', (
    tester,
  ) async {
    await openSheet(tester);
    // The same list the kid-mode picker uses, so a parent cannot pick a face
    // the child would never have been able to.
    for (final name in kidAvatars.take(4)) {
      expect(face(name), findsOneWidget, reason: name);
    }
  });

  testWidgets('a picked picture is saved on the new child', (tester) async {
    await openSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.tap(face('frog'));
    await tester.pump();
    await save(tester, 'Save kid');

    expect(app.kids.single.avatar, 'frog');
  });

  testWidgets('skipping it leaves the initial, as before', (tester) async {
    await openSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await save(tester, 'Save kid');

    expect(app.kids.single.hasDrawableAvatar, isFalse);
  });

  testWidgets('tapping the chosen one again clears it', (tester) async {
    await openSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.tap(face('frog'));
    await tester.pump();
    await tester.tap(face('frog'));
    await tester.pump();
    await save(tester, 'Save kid');

    expect(app.kids.single.hasDrawableAvatar, isFalse);
  });

  testWidgets('editing a child can change their picture', (tester) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Zara',
        age: 8,
        languages: const ['en'],
      );
      kid = await gateway.editKid(kid.id, avatar: 'cat');
      await app.refreshKids();
    });
    await openSheet(tester, editing: kid);
    await tester.tap(face('dog'));
    await tester.pump();
    await save(tester, 'Save changes');

    expect(app.kids.single.avatar, 'dog');
  });
}
