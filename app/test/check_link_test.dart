import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/check_link_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Checking a video or channel the parent found, before allowing anything.
void main() {
  late AppState app;
  late FakeGateway gateway;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> checkLink(WidgetTester tester, String url) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: CheckLinkScreen(kid: kid)),
      ),
    );
    expect(
      find.text('3 checks a day. Looking again at one is free.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Check'));
    await settle(tester);
  }

  testWidgets('a video is read and the verdict shown, with its reason', (
    tester,
  ) async {
    await checkLink(tester, 'https://www.youtube.com/watch?v=abcdefghijk');

    expect(find.text('Twinkle Twinkle Little Star'), findsOneWidget);
    expect(find.text('Gilli would ask you'), findsOneWidget);
    expect(find.textContaining('A sponsor named'), findsOneWidget);
    expect(find.text('2 of 3 checks left today'), findsOneWidget);
  });

  testWidgets('allowing one puts that video on the shelf and says so', (
    tester,
  ) async {
    await checkLink(tester, 'https://www.youtube.com/watch?v=abcdefghijk');
    await tester.tap(find.text('Allow anyway'));
    await settle(tester);

    expect(find.text("On Abu's shelf"), findsOneWidget);
    late List<String> shelf;
    await tester.runAsync(() async {
      shelf = [
        for (final row in await gateway.home(kid.id))
          for (final v in row.videos) v.title,
      ];
    });
    expect(shelf, contains('Twinkle Twinkle Little Star'));
  });

  testWidgets('a channel is read through its newest uploads and can be added', (
    tester,
  ) async {
    await checkLink(tester, 'https://www.youtube.com/@DemoChannel');

    expect(find.text('Demo channel'), findsOneWidget);
    expect(find.text('Its newest 3 videos, read below'), findsOneWidget);
    expect(find.text('Add this channel'), findsOneWidget);
    // Two of those three were already on the shelf.
    expect(find.text("On Abu's shelf"), findsNWidgets(2));
    expect(find.text('0 of 3 checks left today'), findsOneWidget);
  });
}
