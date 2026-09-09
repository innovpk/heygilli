import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/kid_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asking for the channels to be screened again.
///
/// Screening only ever started when channels were imported. A first run that
/// came back with nothing — the server could not read a transcript, the model
/// was briefly down — therefore left a child with an empty home permanently,
/// and a parent with nothing anywhere in the app to press. Re-importing did
/// not help either: the channels were already there, so nothing was added and
/// nothing was screened.
class _CountingGateway extends FakeGateway {
  final List<String> curated = [];

  @override
  Future<void> curateNow(String kidId) async {
    curated.add(kidId);
    return super.curateNow(kidId);
  }
}

void main() {
  late AppState app;
  late Kid kid;
  late _CountingGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _CountingGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abeeha',
      age: 5,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> openChannels(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
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
    await tester.tap(find.text('Channels'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a parent can ask for the channels to be screened again', (
    tester,
  ) async {
    await openChannels(tester);

    final button = find.text('Look for new videos now');
    expect(
      button,
      findsOneWidget,
      reason: 'a household stuck empty has nothing to press without it',
    );

    await tester.tap(button);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(gateway.curated, [kid.id]);
  });

  testWidgets('it says the work started, never that it finished', (
    tester,
  ) async {
    await openChannels(tester);
    await tester.tap(find.text('Look for new videos now'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    // Screening runs on the server and takes minutes. Saying it was done, or
    // holding a spinner until it was, would both be lies to the parent.
    expect(
      find.textContaining('takes a few minutes'),
      findsOneWidget,
      reason: 'a parent told "done" will go and look at an empty home',
    );
  });
}
