import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/hidden_screen.dart';
import 'package:heygilli/features/parent/parent_home.dart';
import 'package:heygilli/features/parent/policy_screen.dart';
import 'package:heygilli/features/parent/preferences_screen.dart';
import 'package:heygilli/features/parent/setup_review_screen.dart';
import 'package:heygilli/features/parent/starter_channels_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The order a child is set up in, and what the parent can see afterwards.
///
/// The answers are what every upload is read against, so they have to be given
/// before the channels are picked. A household that picked channels first had
/// them screened against nothing it had said — which is how a science channel's
/// motivational-quote compilations reached an eight-year-old's shelf — and the
/// screen where those answers live was in the Rules tab, under the time limits.
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

  Future<void> pumpWide(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: home),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('what they may watch is asked before who they watch', (
    tester,
  ) async {
    await pumpWide(tester, const ParentHome());
    await tester.tap(find.text('Add a kid'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save kid'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // The rules, not the channel list: the answers are what the uploads are
    // then screened against.
    expect(find.byType(PolicyScreen), findsOneWidget);
    expect(find.byType(StarterChannelsScreen), findsNothing);
    expect(find.text('What Abu may watch'), findsOneWidget);
  });

  testWidgets('after the rules it asks what they like, not which channels', (
    tester,
  ) async {
    await pumpWide(tester, const ParentHome());
    await tester.tap(find.text('Add a kid'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save kid'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Skip for now'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Not a list of channels to vouch for sight unseen: two of the twenty-six
    // blurbs were wrong about their own channel, and a parent had no way to
    // check any of them.
    expect(find.byType(PreferencesScreen), findsOneWidget);
    expect(find.byType(StarterChannelsScreen), findsNothing);
    expect(find.text('What Abu likes'), findsOneWidget);
  });

  testWidgets('and then it shows what it found', (tester) async {
    await pumpWide(tester, const ParentHome());
    await tester.tap(find.text('Add a kid'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Abu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save kid'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Skip for now'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Find videos'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // The point of asking is what comes back. Stopping at the question would
    // leave the parent on a child's page with an empty shelf and no idea
    // anything was happening.
    expect(find.byType(SetupReviewScreen), findsOneWidget);
  });

  testWidgets('picking nothing still goes looking', (tester) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
    });
    await pumpWide(tester, PreferencesScreen(kid: kid));

    // "I do not know yet" is the commonest answer during setup and must not be
    // met with a dead button.
    expect(find.text('Find videos'), findsOneWidget);
    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.onPressed, isNotNull);
  });

  testWidgets('a parent who is not ready to answer is not held there', (
    tester,
  ) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
    });
    await pumpWide(tester, PolicyScreen(kid: kid, setup: true));

    // Skipping is an answer here too, and someone who wants to look at the app
    // before deciding what they think must not meet a wall of questions.
    expect(find.text('Skip for now'), findsOneWidget);
  });

  testWidgets('the settings page it used to be has no skip and no rename', (
    tester,
  ) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
    });
    await pumpWide(tester, PolicyScreen(kid: kid));

    expect(find.text('Skip for now'), findsNothing);
    expect(find.text('What your household wants'), findsOneWidget);
  });

  testWidgets('what was kept from the child is shown with Gilli\'s reason', (
    tester,
  ) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
    });
    await pumpWide(tester, HiddenScreen(kid: kid));

    // The one the demo Curator hid, and why — not merely that something was.
    expect(find.textContaining('A live stream'), findsOneWidget);
    // And the ones it allowed are not here: this is the hidden list.
    expect(find.textContaining('Explains how volcanoes work'), findsNothing);
    // A rule the parent cannot overrule is a rule they cannot trust.
    expect(find.text('Allow it anyway'), findsOneWidget);
  });

  testWidgets('putting one back sends it, and it leaves the list', (
    tester,
  ) async {
    late Kid kid;
    await tester.runAsync(() async {
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
    });
    await pumpWide(tester, HiddenScreen(kid: kid));

    await tester.tap(find.text('Allow it anyway'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Allow it anyway'), findsNothing);
    expect(find.textContaining('Nothing has been kept'), findsOneWidget);
  });
}
