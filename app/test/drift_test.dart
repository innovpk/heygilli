import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/channel_reviews_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Channel drift (PROTOCOL "Channel drift: a channel is not what it was").
///
/// The rule the whole feature turns on: a drift is information. HeyGilli
/// never removes a channel on its own, and the tests below fail if a card
/// ever acts before the parent does.
void main() {
  group('ChannelDrift payload', () {
    ChannelDrift parse() => ChannelDrift.fromJson({
      'channel_id': 'ch_a',
      'title': 'Slime Lab Kids',
      'was': {
        'verdict': 'good',
        'flags': [
          {'kind': 'low_quality', 'note': 'Thin, but harmless.'},
        ],
        'reviewed_at': '2026-03-01T00:00:00Z',
      },
      'now': {
        'verdict': 'concern',
        'flags': [
          {'kind': 'low_quality', 'note': 'Thin, but harmless.'},
          {'kind': 'ads_or_merch', 'note': 'Sponsor read in every upload.'},
        ],
        'reviewed_at': '2026-09-01T00:00:00Z',
      },
      'worse': true,
      'what_changed': 'It has started running sponsor reads.',
      'sample_titles': ['MY NEW MERCH', 'Sponsored haul'],
    });

    test('parses both ends of the change', () {
      final d = parse();
      expect(d.was.verdict, ReviewVerdict.good);
      expect(d.now.verdict, ReviewVerdict.concern);
      expect(d.worse, isTrue);
      expect(d.sampleTitles, hasLength(2));
    });

    test('only the flags that are new are the news', () {
      // The parent already read and accepted the old ones when they approved
      // the channel; repeating them buries the difference.
      final d = parse();
      expect(d.newFlags.map((f) => f.kind), ['ads_or_merch']);
      expect(d.verdictMove, 'Looks fine, now Worth a look');
    });

    test('a verdict that did not move leaves the flag to carry it', () {
      final d = ChannelDrift.fromJson({
        'channel_id': 'ch_a',
        'was': {'verdict': 'mixed'},
        'now': {
          'verdict': 'mixed',
          'flags': [
            {'kind': 'scary'},
          ],
        },
        'worse': true,
      });
      expect(d.verdictMove, isEmpty);
      expect(d.newFlags.single.label, 'Scary moments');
    });

    test('a drift that cannot be read is not surfaced as a worry', () {
      final d = ChannelDrift.fromJson({'channel_id': 'ch_a'});
      expect(d.worse, isFalse);
      expect(d.was.verdict, ReviewVerdict.unknown);
    });

    test('only the ones that got worse reach a parent', () {
      final check = DriftCheck.fromJson({
        'drifted': [
          {'channel_id': 'ch_worse', 'worse': true},
          {'channel_id': 'ch_better', 'worse': false},
        ],
        'checked': 2,
      });

      // A channel that improved is not something to interrupt anyone about.
      expect(check.drifted, hasLength(2));
      expect(check.worse.single.channelId, 'ch_worse');
      expect(check.checked, 2);
    });
  });

  group('an inbox entry that is not about a video', () {
    test('is kept rather than dropped on the floor', () {
      // PROTOCOL says a drift raises an inbox entry, and a drift has no video
      // in it. Refusing to parse one would silently lose the thing the entry
      // exists to tell the parent.
      final p = ParentPrompt.fromJson({
        'id': 'prompt_drift_1',
        'kid_id': 'kid_1',
        'title': 'Slime Lab Kids',
        'reason': 'This channel has started running sponsor reads.',
        'created_at': '2026-09-06T08:00:00Z',
      });

      expect(p.video, isNull);
      expect(p.subject, 'Slime Lab Kids');
      expect(p.reason, contains('sponsor reads'));
    });

    test('an ordinary video entry is unchanged', () {
      final p = ParentPrompt.fromJson({
        'id': 'prompt_1',
        'kid_id': 'kid_1',
        'video': {'id': 'vid_1', 'title': 'Volcanoes', 'duration_s': 300},
        'reason': 'Longer than usual.',
      });

      expect(p.video?.title, 'Volcanoes');
      expect(p.subject, 'Volcanoes');
    });
  });

  group('FakeGateway drift check', () {
    late FakeGateway gateway;
    late Kid kid;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      kid = await gateway.createKid(
        nickname: 'Zoya',
        age: 9,
        languages: const ['en'],
      );
      await gateway.importChannels(kid.id, const [
        'ch_slimelabkids',
        'ch_pranksquadworld',
        'ch_teded',
      ]);
    });

    test('reports the channels that moved and nothing else', () async {
      final channels = await gateway.channels(kid.id);
      final check = await gateway.checkDrift([for (final c in channels) c.id]);

      expect(check.worse.map((d) => d.channelId), [
        'ch_slimelabkids',
        'ch_pranksquadworld',
      ]);
      for (final d in check.worse) {
        expect(d.whatChanged, isNotEmpty, reason: d.channelId);
        expect(d.sampleTitles, isNotEmpty, reason: d.channelId);
        expect(d.newFlags, isNotEmpty, reason: d.channelId);
      }
    });

    test(
      'a second check re-reads nothing, the way a rate limit works',
      () async {
        final ids = [for (final c in await gateway.channels(kid.id)) c.id];

        final first = await gateway.checkDrift(ids);
        final again = await gateway.checkDrift(ids);

        expect(first.checked, greaterThan(0));
        expect(again.checked, 0);
        // Still reported, though: cached is not the same as gone.
        expect(again.worse, hasLength(first.worse.length));
      },
    );

    test('checking a drift never removes anything', () async {
      final before = (await gateway.channels(kid.id)).length;
      await gateway.checkDrift([
        for (final c in await gateway.channels(kid.id)) c.id,
      ]);

      expect((await gateway.channels(kid.id)).length, before);
    });
  });

  group('the drift card', () {
    late FakeGateway gateway;
    late AppState app;
    late Kid kid;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      kid = await gateway.createKid(
        nickname: 'Zoya',
        age: 9,
        languages: const ['en'],
      );
      await gateway.importChannels(kid.id, const [
        'ch_slimelabkids',
        'ch_pranksquadworld',
        'ch_teded',
      ]);
    });

    Widget host() => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(home: ChannelReviewsScreen(kid: kid)),
    );

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    testWidgets('says what changed, and what it read to say it', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('This is not what it was'), findsNWidgets(2));
      expect(find.text('Slime Lab Kids'), findsWidgets);
      expect(
        find.textContaining('most uploads open with a sponsor read'),
        findsOneWidget,
      );
      // The uploads behind the claim, so a parent can check it.
      expect(find.text('THE UPLOADS THAT CHANGED IT'), findsNWidgets(2));
      expect(find.textContaining('MY NEW MERCH IS HERE'), findsOneWidget);
    });

    testWidgets('says plainly that nothing has been done about it', (
      tester,
    ) async {
      await open(tester);

      // A warning card that has already acted is the failure mode here.
      expect(
        find.textContaining('Nothing has changed for Zoya'),
        findsNWidgets(2),
      );
      expect(
        find.textContaining('stays approved until you say otherwise'),
        findsNWidgets(2),
      );
    });

    testWidgets('keeping it puts the card away and removes nothing', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.text('Keep it').first);
      await tester.pump();

      expect(find.text('This is not what it was'), findsOneWidget);
      expect(find.textContaining('removed from'), findsNothing);
    });

    testWidgets('removing it is the parent doing it, with an undo', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.text('Remove it').first);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // The snackbar only appears after the gateway actually removed it.
      expect(
        find.textContaining('Slime Lab Kids removed from Zoya'),
        findsOneWidget,
      );
      expect(find.text('Undo'), findsOneWidget);
    });
  });
}
