import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Search, on by default and never reaching YouTube.
///
/// The premise of the whole product is that a child only ever sees what a
/// parent approved. A search box is the obvious way to break that, so what it
/// searches matters more than that it exists. Because it can only narrow the
/// approved list, it is safe to leave on; a parent can still turn it off.
void main() {
  late FakeGateway gateway;
  late AppState app;
  late Kid preReader;
  late Kid reader;

  /// A child whose parent turned search off. Built in setUp because
  /// FakeGateway's lag is a real delay and inside testWidgets the clock is the
  /// tester's: awaiting it from a test body never comes back, and the failure
  /// looks like a hang rather than a mistake.
  late Kid turnedOff;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    preReader = await gateway.createKid(
      nickname: 'Lisa',
      age: 5,
      languages: const ['en'],
    );
    reader = await gateway.createKid(
      nickname: 'Rayan',
      age: 9,
      languages: const ['en'],
    );
    final sara = await gateway.createKid(
      nickname: 'Sara',
      age: 9,
      languages: const ['en'],
    );
    turnedOff = await gateway.updateLimits(sara.id, searchEnabled: false);
  });

  Future<void> open(WidgetTester tester, Kid kid) async {
    app.enterKidMode(kid);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<GilliVoice>(create: (_) => GilliVoice()),
        ],
        child: const MaterialApp(home: KidHomeScreen()),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  test('a new child can search unless a parent says otherwise', () {
    expect(reader.searchEnabled, isTrue);
    expect(preReader.searchEnabled, isTrue);
  });

  testWidgets('every child gets a box, with a mic to say it', (tester) async {
    await open(tester, reader);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key('search-mic')), findsOneWidget);
  });

  testWidgets('a pre-reader gets one too: they can say what they want', (
    tester,
  ) async {
    await open(tester, preReader);
    expect(find.byKey(const Key('search-mic')), findsOneWidget);
  });

  testWidgets('a parent who turns it off takes the box away', (tester) async {
    await open(tester, turnedOff);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('search-mic')), findsNothing);
  });

  test('a query only ever narrows what is already approved', () async {
    final everything = await gateway.home(reader.id);
    final all = [for (final r in everything) ...r.videos.map((v) => v.id)];

    final found = await gateway.home(reader.id, query: 'volcano');
    final hits = [for (final r in found) ...r.videos.map((v) => v.id)];

    expect(hits, isNotEmpty, reason: 'the demo shelf has a volcano video');
    expect(
      all,
      containsAll(hits),
      reason: 'search returned something that was not on this kid\'s shelf',
    );
    expect(hits.length, lessThan(all.length), reason: 'it narrowed nothing');
  });

  test('a query does nothing at all while the parent has search off', () async {
    final off = await gateway.home(turnedOff.id, query: 'volcano');
    final normal = await gateway.home(turnedOff.id);
    expect(
      [for (final r in off) r.title],
      [for (final r in normal) r.title],
      reason: 'a query was honoured for a kid whose parent turned search off',
    );
  });

  test('a word that matches nothing returns nothing, not everything', () async {
    final rows = await gateway.home(reader.id, query: 'zzzznotavideo');
    expect([for (final r in rows) ...r.videos], isEmpty);
  });
}
