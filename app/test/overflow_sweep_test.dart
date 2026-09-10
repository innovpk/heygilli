import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/break_screen.dart';
import 'package:heygilli/features/kid/games/catch_gilli_game.dart';
import 'package:heygilli/features/kid/games/find_gilli_game.dart';
import 'package:heygilli/features/kid/games/play_screen.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:heygilli/features/kid/nothing_yet_screen.dart';
import 'package:heygilli/features/parent/channel_reviews_screen.dart';
import 'package:heygilli/features/parent/digest_screen.dart';
import 'package:heygilli/features/parent/hidden_screen.dart';
import 'package:heygilli/features/parent/history_screen.dart';
import 'package:heygilli/features/parent/inbox_screen.dart';
import 'package:heygilli/features/parent/kid_detail_screen.dart';
import 'package:heygilli/features/parent/parent_home.dart';
import 'package:heygilli/features/parent/parent_widgets.dart';
import 'package:heygilli/features/parent/policy_screen.dart';
import 'package:heygilli/features/parent/check_link_screen.dart';
import 'package:heygilli/features/parent/preferences_screen.dart';
import 'package:heygilli/features/parent/progress_screen.dart';
import 'package:heygilli/features/parent/setup_review_screen.dart';
import 'package:heygilli/features/parent/sign_in_screen.dart';
import 'package:heygilli/features/parent/starter_channels_screen.dart';
import 'package:heygilli/features/parent/takeout_import_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every screen, at every size a parent or a child will actually hold it at,
/// with nothing allowed to overflow.
///
/// An overflow is Flutter's yellow-and-black stripe in debug and, in release,
/// content that is silently cut off — a button half off the edge, a reason a
/// parent cannot finish reading. Each one is found by somebody holding a
/// device the author did not, so this holds all of them at once: a small
/// phone, an ordinary one, a tablet and a desktop window for the parent side,
/// and the kid side in landscape, which is how kid mode runs.
///
/// Every overflow in a case is collected rather than failing on the first, so
/// one run shows the whole list.
void main() {
  const parentSizes = {
    'small phone': Size(320, 568),
    'phone': Size(390, 844),
    'tablet': Size(820, 1180),
    'desktop': Size(1280, 800),
  };
  // Kid mode pins landscape.
  const kidSizes = {
    'small phone landscape': Size(568, 320),
    'phone landscape': Size(844, 390),
    'tablet landscape': Size(1180, 820),
  };

  late AppState app;
  late Kid reader;
  late Kid preReader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    reader = await gateway.createKid(
      nickname: 'Abu',
      age: 8,
      languages: const ['en'],
    );
    preReader = await gateway.createKid(
      nickname: 'Zara',
      age: 5,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<List<String>> render(
    WidgetTester tester,
    Size size,
    Widget screen, {
    Future<void> Function(WidgetTester)? then,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final overflows = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      if (text.contains('overflowed')) {
        // The widget that overflowed, as a lib/ path and line, so the failure
        // says where to look rather than only that something is wrong.
        final where =
            RegExp(
              r'lib/[\w/]+\.dart:\d+',
            ).firstMatch(details.toString())?.group(0) ??
            '';
        overflows.add('${text.split('\n').first}  $where'.trim());
      } else {
        previous?.call(details);
      }
    };
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
          ],
          child: MaterialApp(home: screen),
        ),
      );
      // FakeGateway answers after a real delay, and several screens chain two
      // or three calls before they draw their final layout.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (then != null) {
        await then(tester);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
      }
      // Tear the tree down inside the test so periodic timers (the break
      // countdown) are cancelled by dispose rather than reported as leaks.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    } finally {
      FlutterError.onError = previous;
    }
    return overflows.toSet().toList();
  }

  Future<void> Function(WidgetTester) tab(String label) =>
      (tester) async => tester.tap(find.text(label).first);

  final parentCases =
      <String, (Widget Function(), Future<void> Function(WidgetTester)?)>{
        'sign in': (() => const SignInScreen(), null),
        'kids list': (() => const ParentHome(), null),
        // Pushed from a child's page inside a scaffold, which is the only way
        // the app ever shows it on its own.
        'inbox': (
          () => const ParentScaffold(title: 'Inbox', body: InboxScreen()),
          null,
        ),
        'kid overview (reader)': (() => KidDetailScreen(kid: reader), null),
        'kid overview (pre-reader)': (
          () => KidDetailScreen(kid: preReader),
          null,
        ),
        'kid progress tab': (
          () => KidDetailScreen(kid: reader),
          tab('Progress'),
        ),
        'kid rules tab': (() => KidDetailScreen(kid: reader), tab('Rules')),
        'kid channels tab': (
          () => KidDetailScreen(kid: reader),
          tab('Channels'),
        ),
        'progress': (() => ProgressScreen(kid: reader), null),
        'digest': (() => DigestScreen(kid: reader), null),
        'history': (() => HistoryScreen(kid: reader), null),
        'hidden': (() => HiddenScreen(kid: reader), null),
        'policy (setup)': (() => PolicyScreen(kid: reader, setup: true), null),
        'preferences': (() => PreferencesScreen(kid: reader), null),
        'check link': (() => CheckLinkScreen(kid: reader), null),
        'setup review': (() => SetupReviewScreen(kid: reader), null),
        'starter channels': (() => StarterChannelsScreen(kid: reader), null),
        'channel reviews': (() => ChannelReviewsScreen(kid: reader), null),
        'takeout import': (() => const TakeoutImportScreen(), null),
      };

  for (final c in parentCases.entries) {
    for (final s in parentSizes.entries) {
      testWidgets('${c.key} at ${s.key} ${s.value.width.toInt()}w', (
        tester,
      ) async {
        final found = await render(
          tester,
          s.value,
          c.value.$1(),
          then: c.value.$2,
        );
        expect(found, isEmpty, reason: found.join('\n'));
      });
    }
  }

  final kidCases = <String, Widget Function()>{
    'kid home (reader)': () => const KidHomeScreen(),
    'break': () => BreakScreen(
      kid: reader,
      breakPeriod: BreakPeriod(id: 'b', kidId: reader.id, secondsLeft: 240),
      onFinished: () {},
    ),
    'day done': () => DayDoneScreen(kid: reader),
    'nothing yet': () => NothingYetScreen(kid: reader),
  };

  for (final c in kidCases.entries) {
    for (final s in kidSizes.entries) {
      testWidgets('${c.key} at ${s.key} ${s.value.width.toInt()}w', (
        tester,
      ) async {
        app.enterKidMode(reader);
        final found = await render(tester, s.value, c.value());
        expect(found, isEmpty, reason: found.join('\n'));
      });
    }
  }

  // Gilli's games. Their rounds run on timers a disposed widget cannot
  // cancel, so each case unmounts and runs them out before it ends.
  final gameCases = <String, Widget Function()>{
    'play picker': () => PlayScreen(kid: reader),
    'play picker (pre-reader)': () => PlayScreen(kid: preReader),
    'find gilli': () => Scaffold(
      body: FindGilliGame(
        kid: reader,
        onBack: () {},
        onAgain: () {},
        onHome: () {},
      ),
    ),
    'find gilli (pre-reader)': () => Scaffold(
      body: FindGilliGame(
        kid: preReader,
        onBack: () {},
        onAgain: () {},
        onHome: () {},
      ),
    ),
    'catch gilli': () => Scaffold(
      body: CatchGilliGame(
        kid: reader,
        onBack: () {},
        onAgain: () {},
        onHome: () {},
      ),
    ),
  };

  for (final c in gameCases.entries) {
    for (final s in kidSizes.entries) {
      testWidgets('${c.key} at ${s.key} ${s.value.width.toInt()}w', (
        tester,
      ) async {
        final found = await render(tester, s.value, c.value());
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 10));
        expect(found, isEmpty, reason: found.join('\n'));
      });
    }
  }

  for (final s in kidSizes.entries) {
    testWidgets('kid home (pre-reader) at ${s.key}', (tester) async {
      app.enterKidMode(preReader);
      final found = await render(tester, s.value, const KidHomeScreen());
      expect(found, isEmpty, reason: found.join('\n'));
    });
  }
}

class _SilentVoice extends GilliVoice {
  @override
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {}
}
