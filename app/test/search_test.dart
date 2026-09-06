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

/// Search, which a parent turns on per child and which never reaches YouTube.
///
/// The premise of the whole product is that a child only ever sees what a
/// parent approved. A search box is the obvious way to break that, so what it
/// searches matters more than that it exists.
void main() {
  late FakeGateway gateway;
  late AppState app;
  late Kid preReader;
  late Kid reader;

  /// The same two children with search switched on. Built in setUp because
  /// FakeGateway's lag is a real delay and inside testWidgets the clock is the
  /// tester's: awaiting it from a test body never comes back, and the failure
  /// looks like a hang rather than a mistake.
  late Kid readerWithSearch;
  late Kid preReaderWithSearch;

  /// A child whose parent never turned it on, kept separate because
  /// `updateLimits` changes the stored kid: reusing one of the others here
  /// would test a kid that does have search and pass for the wrong reason.
  late Kid neverEnabled;

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
    readerWithSearch = await gateway.updateLimits(
      reader.id,
      searchEnabled: true,
    );
    preReaderWithSearch = await gateway.updateLimits(
      preReader.id,
      searchEnabled: true,
    );
    neverEnabled = await gateway.createKid(
      nickname: 'Sara',
      age: 9,
      languages: const ['en'],
    );
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

  testWidgets('there is no search box until a parent asks for one', (
    tester,
  ) async {
    await open(tester, neverEnabled);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a parent who turns it on gives their child a box', (
    tester,
  ) async {
    await open(tester, readerWithSearch);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a pre-reader never gets one, even if a parent turns it on', (
    tester,
  ) async {
    // Band 4_6 cannot read the box, cannot type into it, and gets no text
    // anywhere else in the app. A search box would be a control that exists
    // only to be poked at.
    await open(tester, preReaderWithSearch);
    expect(find.byType(TextField), findsNothing);
  });

  test('a query only ever narrows what is already approved', () async {
    final on = readerWithSearch;
    final everything = await gateway.home(on.id);
    final all = [for (final r in everything) ...r.videos.map((v) => v.id)];

    final found = await gateway.home(on.id, query: 'volcano');
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
    final off = await gateway.home(neverEnabled.id, query: 'volcano');
    final normal = await gateway.home(neverEnabled.id);
    expect(
      [for (final r in off) r.title],
      [for (final r in normal) r.title],
      reason: 'a query was honoured for a kid whose parent never enabled it',
    );
  });

  test('a word that matches nothing returns nothing, not everything', () async {
    final rows = await gateway.home(
      readerWithSearch.id,
      query: 'zzzznotavideo',
    );
    expect([for (final r in rows) ...r.videos], isEmpty);
  });
}
