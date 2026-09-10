import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/kid_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A child's page, for the parent.
///
/// It had grown into one column holding everything anyone might want about a
/// child, so "where do I change this" was answered by scrolling. Three tabs,
/// split by question: what happened, what is allowed, what they can watch.
void main() {
  late AppState app;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: KidDetailScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('the four tabs are there, and kid mode is above them', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('Rules'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    // Starting a session is what a parent came to do most often, so it is not
    // filed inside one of the four.
    expect(find.text('Enter kid mode'), findsOneWidget);
  });

  testWidgets('the note is the first thing shown, not a card about it', (
    tester,
  ) async {
    // The tab used to be four doors, one of which led to the note a parent
    // came to read. The note is the page now.
    await open(tester);
    expect(find.textContaining("TONIGHT'S NOTE"), findsOneWidget);
    expect(find.textContaining('Waiting for you'), findsOneWidget);
    expect(find.textContaining('Rules in one glance'), findsOneWidget);
  });

  testWidgets('the rules live together, away from the reading', (tester) async {
    await open(tester);
    // Not on the first tab.
    expect(find.textContaining('Time limits'), findsNothing);

    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Time limits'), findsOneWidget);
    expect(
      find.textContaining('What Gilli says at break time'),
      findsOneWidget,
    );
    expect(find.textContaining('What your household wants'), findsOneWidget);
  });

  testWidgets('channels are their own tab, not the tail of a long page', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();

    expect(find.textContaining('CHANNELS'), findsOneWidget);
    // Every way to add is behind one button, not four on the page.
    expect(find.textContaining('YouTube Kids'), findsNothing);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Import from YouTube Kids'), findsOneWidget);
    expect(find.text('Suggest channels for Abu'), findsOneWidget);
  });
}
