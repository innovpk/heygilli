import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:heygilli/features/kid/nothing_yet_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The kid home with nothing approved in it — the state every household is in
/// before the Curator has finished, and the first thing a new profile shows.
///
/// It used to render an empty list: a dark screen with nothing on it, which a
/// child cannot tell apart from a broken app. The rules it has to keep are the
/// end-of-day screen's rules, because it is the same situation — nothing to
/// watch, through no fault of the child.
void main() {
  const preReader = Kid(
    id: 'k1',
    nickname: 'Lisa',
    age: 5,
    band: AgeBand.b4to6,
    languages: ['en'],
  );
  const reader = Kid(
    id: 'k2',
    nickname: 'Rayan',
    age: 9,
    band: AgeBand.b9to11,
    languages: ['en'],
  );

  /// A household whose Curator has approved nothing, built here rather than in
  /// a test body: FakeGateway's lag is a real delay, and inside testWidgets the
  /// clock is the tester's, so awaiting it from a test never comes back.
  late AppState emptyApp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _EmptyHomeGateway();
    await gateway.signInDev('parent');
    emptyApp = AppState(gateway: gateway, settings: await LocalSettings.load());
    emptyApp.enterKidMode(
      await gateway.createKid(
        nickname: 'Lisa',
        age: 5,
        languages: const ['en'],
      ),
    );
  });

  Widget host(Kid kid) => ChangeNotifierProvider<GilliVoice>(
    create: (_) => _SilentVoice(),
    child: MaterialApp(
      home: Scaffold(body: NothingYetScreen(kid: kid)),
    ),
  );

  testWidgets('an older child is told, plainly, that there is nothing yet', (
    tester,
  ) async {
    await tester.pumpWidget(host(reader));
    await tester.pump();
    expect(find.text('Nothing to watch yet'), findsOneWidget);
  });

  testWidgets('a pre-reader sees no text at all', (tester) async {
    // The rule the whole product bends around for band 4_6: they cannot read,
    // so a written explanation is no explanation. They get Gilli and a voice.
    await tester.pumpWidget(host(preReader));
    await tester.pump();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('it is spoken, and slowly for a pre-reader', (tester) async {
    final voice = _SilentVoice();
    await tester.pumpWidget(
      ChangeNotifierProvider<GilliVoice>.value(
        value: voice,
        child: MaterialApp(
          home: Scaffold(body: NothingYetScreen(kid: preReader)),
        ),
      ),
    );
    await tester.pump();

    expect(voice.said, hasLength(1), reason: 'said once, not on every frame');
    expect(voice.slowly.single, isTrue);
  });

  testWidgets('it never promises something is on its way', (tester) async {
    // A household that has added no channels has nothing happening at all.
    // "Coming soon" or "Gilli is looking" would be a screen lying to a child.
    final voice = _SilentVoice();
    for (final kid in [preReader, reader]) {
      await tester.pumpWidget(
        ChangeNotifierProvider<GilliVoice>.value(
          value: voice,
          child: MaterialApp(
            home: Scaffold(body: NothingYetScreen(kid: kid)),
          ),
        ),
      );
      await tester.pump();
    }
    final everything = [
      ...voice.said,
      ...tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''),
    ].join(' ').toLowerCase();

    for (final promise in ['soon', 'looking', 'finding', 'wait', 'loading']) {
      expect(
        everything.contains(promise),
        isFalse,
        reason: 'the screen promised "$promise" when nothing may be happening',
      );
    }
  });

  testWidgets('the home reaches for it when there is nothing to show', (
    tester,
  ) async {
    // The wiring, not the screen: the bug was never in what this screen says,
    // it was that an empty row list rendered a ListView with no children and
    // the child got a blank teal rectangle.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: emptyApp),
          ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
        ],
        child: const MaterialApp(home: KidHomeScreen()),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.byType(NothingYetScreen), findsOneWidget);
  });

  testWidgets('it is not dressed as an error', (tester) async {
    await tester.pumpWidget(host(reader));
    await tester.pump();
    // No retry button to press at, and nothing that reads as a failure.
    expect(find.byType(FilledButton), findsNothing);
    expect(
      find.textContaining(RegExp('error|wrong|failed', caseSensitive: false)),
      findsNothing,
    );
  });
}

/// Gilli with the sound off, recording what it was asked to say.
class _SilentVoice extends GilliVoice {
  final List<String> said = [];
  final List<bool> slowly = [];

  @override
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {
    said.add(fallbackText ?? '');
    slowly.add(slow);
  }
}

/// A household whose Curator has approved nothing yet, which is where every
/// one of them starts.
class _EmptyHomeGateway extends FakeGateway {
  @override
  Future<List<HomeRow>> home(String kidId) async => const [];
}
