import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/api_client.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/break_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Time limits and movement breaks, against the shapes in
/// docs/PROTOCOL.md "Time limits and movement breaks".
void main() {
  group('Kid limits', () {
    test('the four settings parse off the wire', () {
      final kid = Kid.fromJson({
        'id': 'k1',
        'nickname': 'Zoya',
        'age': 5,
        'age_band': '4_6',
        'languages': ['en'],
        'daily_minutes': 45,
        'break_after_minutes': 20,
        'break_minutes': 3,
        'max_video_minutes': 12,
      });
      expect(kid.dailyMinutes, 45);
      expect(kid.breakAfterMinutes, 20);
      expect(kid.breakMinutes, 3);
      expect(kid.maxVideoMinutes, 12);
    });

    test('a gateway that omits them means the protocol defaults, not zero', () {
      final kid = Kid.fromJson({'id': 'k1', 'nickname': 'Zoya', 'age': 5});
      expect(kid.dailyMinutes, 60);
      expect(kid.breakAfterMinutes, 25);
      expect(kid.breakMinutes, 5);
      expect(kid.maxVideoMinutes, 0, reason: 'no cap on video length');
    });

    test('0 is "no limit" and "never", not "immediately"', () {
      final kid = Kid.fromJson({
        'id': 'k1',
        'nickname': 'Zoya',
        'age': 5,
        'daily_minutes': 0,
        'break_after_minutes': 0,
      });
      expect(kid.hasDailyLimit, isFalse);
      expect(kid.takesBreaks, isFalse);
    });

    test('limits round-trip through json', () {
      const kid = Kid(
        id: 'k1',
        nickname: 'Zoya',
        age: 5,
        band: AgeBand.b4to6,
        languages: ['en'],
        dailyMinutes: 30,
        breakAfterMinutes: 15,
        breakMinutes: 2,
        maxVideoMinutes: 10,
      );
      final back = Kid.fromJson(kid.toJson());
      expect(back.dailyMinutes, 30);
      expect(back.breakAfterMinutes, 15);
      expect(back.breakMinutes, 2);
      expect(back.maxVideoMinutes, 10);
    });
  });

  group('WatchState and MovementBreak', () {
    final breakJson = {
      'id': 'brk_1',
      'kid_id': 'k1',
      'started_at': '2026-09-06T10:00:00Z',
      'ends_at': '2026-09-06T10:05:00Z',
      'seconds_left': 214,
      'task': {
        'title': 'Be a volcano',
        'steps': ['Crouch down small', 'Push your arms up and go whoosh'],
        'seconds': 120,
        'spoken': 'Let us be a volcano! Crouch down small.',
      },
      'source_titles': ['Every Kind of Volcano'],
      'acked': false,
    };

    test('a break parses whole', () {
      final b = MovementBreak.fromJson(breakJson);
      expect(b.id, 'brk_1');
      expect(b.kidId, 'k1');
      expect(b.secondsLeft, 214);
      expect(b.acked, isFalse);
      expect(b.sourceTitles, ['Every Kind of Volcano']);
      expect(b.task.title, 'Be a volcano');
      expect(b.task.steps.length, 2);
      expect(b.task.seconds, 120);
      expect(b.task.spoken, startsWith('Let us be a volcano'));
    });

    test('a task with no spoken line still has something to say', () {
      const t = BreakTask(title: 'Stretch tall like a tree');
      expect(t.speech, 'Stretch tall like a tree');
    });

    test('a blocked state carries the break', () {
      final s = WatchState.fromJson({
        'minutes_today': 26,
        'minutes_left_today': 34,
        'continuous_minutes': 0,
        'watching_allowed': false,
        'blocked_reason': 'break',
        'active_break': breakJson,
      });
      expect(s.watchingAllowed, isFalse);
      expect(s.blockedReason, BlockedReason.movementBreak);
      expect(s.isOnBreak, isTrue);
      expect(s.isDayDone, isFalse);
      expect(s.activeBreak!.task.title, 'Be a volcano');
    });

    test('the daily limit is a state of its own, with no break', () {
      final s = WatchState.fromJson({
        'minutes_today': 60,
        'minutes_left_today': 0,
        'watching_allowed': false,
        'blocked_reason': 'daily_limit',
        'active_break': null,
      });
      expect(s.isDayDone, isTrue);
      expect(s.isOnBreak, isFalse, reason: 'nothing to do, nothing to show');
    });

    test('an unlimited day parses as allowed', () {
      final s = WatchState.fromJson({
        'minutes_today': 12,
        'minutes_left_today': 0,
        'continuous_minutes': 12,
        'watching_allowed': true,
        'blocked_reason': null,
        'active_break': null,
      });
      expect(s.watchingAllowed, isTrue);
      expect(s.blockedReason, isNull);
    });

    test('a gateway with no limits shipped yet does not lock a child out', () {
      final s = WatchState.fromJson(const {});
      expect(s.watchingAllowed, isTrue);
      expect(s.isOnBreak, isFalse);
    });

    test('an unknown blocked_reason is not invented into a break', () {
      final s = WatchState.fromJson({
        'watching_allowed': false,
        'blocked_reason': 'something_new',
      });
      expect(s.blockedReason, isNull);
      expect(s.isOnBreak, isFalse);
      expect(s.watchingAllowed, isFalse);
    });

    test('state round-trips through json', () {
      final s = WatchState.fromJson({
        'minutes_today': 26,
        'watching_allowed': false,
        'blocked_reason': 'break',
        'active_break': breakJson,
      });
      final back = WatchState.fromJson(s.toJson());
      expect(back.blockedReason, BlockedReason.movementBreak);
      expect(back.activeBreak!.task.steps, s.activeBreak!.task.steps);
    });
  });

  group('the break WebSocket message', () {
    test('{t: "break"} decodes with its break', () {
      final m = ServerMessage.decode(
        jsonEncode({
          't': 'break',
          'break': {
            'id': 'brk_1',
            'kid_id': 'k1',
            'seconds_left': 300,
            'task': {
              'title': 'Waddle like the five little ducks',
              'steps': ['Waddle five steps one way'],
              'seconds': 90,
              'spoken': 'Stand up like a little duck!',
            },
          },
        }),
      );
      expect(m, isA<BreakMessage>());
      final b = (m as BreakMessage).movementBreak;
      expect(b.secondsLeft, 300);
      expect(b.task.title, 'Waddle like the five little ducks');
    });

    test('a break frame with no break in it is not a break', () {
      // Better an ignored frame than a full-screen break a child cannot
      // leave and Gilli has nothing to say on.
      expect(ServerMessage.decode('{"t":"break"}'), isA<UnknownMessage>());
    });
  });

  group('POST /sessions answering 409', () {
    ApiClient clientAnswering(int status, Object body) => ApiClient(
      baseUrl: 'http://gateway',
      token: 't',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final activeBreak = {
      'id': 'brk_9',
      'kid_id': 'k1',
      'seconds_left': 180,
      'task': {'title': 'Be a volcano', 'steps': [], 'spoken': 'Whoosh!'},
    };

    test('200 starts a session', () async {
      final api = clientAnswering(200, {
        'session_id': 's1',
        'video': {'id': 'v1', 'channel_id': 'c1', 'title': 'x'},
        'plan_ready': true,
      });
      final r = await api.startSession(
        kidId: 'k1',
        videoId: 'v1',
        device: 'android',
      );
      expect(r, isA<SessionStarted>());
      expect((r as SessionStarted).session.sessionId, 's1');
    });

    test('409 is a blocked result, not an exception', () async {
      final api = clientAnswering(409, {'break': activeBreak});
      final r = await api.startSession(
        kidId: 'k1',
        videoId: 'v1',
        device: 'android',
      );
      expect(r, isA<SessionBlockedByBreak>());
      expect((r as SessionBlockedByBreak).activeBreak.secondsLeft, 180);
    });

    test('the break is found whichever envelope the gateway uses', () {
      for (final body in [
        jsonEncode(activeBreak),
        jsonEncode({'break': activeBreak}),
        jsonEncode({'active_break': activeBreak}),
        jsonEncode({'detail': activeBreak}),
        jsonEncode({
          'detail': {'break': activeBreak},
        }),
      ]) {
        expect(
          breakFromErrorBody(body)?.task.title,
          'Be a volcano',
          reason: body,
        );
      }
    });

    test('an ordinary error body yields no break', () {
      expect(breakFromErrorBody('{"detail":"video not found"}'), isNull);
      expect(breakFromErrorBody('not json at all'), isNull);
    });

    test('a 409 with nothing usable in it still throws', () async {
      final api = clientAnswering(409, {'detail': 'conflict'});
      await expectLater(
        api.startSession(kidId: 'k1', videoId: 'v1', device: 'android'),
        throwsA(isA<ApiException>()),
      );
    });

    test('other statuses are still errors', () async {
      final api = clientAnswering(500, {'detail': 'boom'});
      await expectLater(
        api.startSession(kidId: 'k1', videoId: 'v1', device: 'android'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('FakeGateway limits', () {
    late FakeGateway gateway;
    late Kid kid;

    setUp(() async {
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      kid = await gateway.createKid(
        nickname: 'Zoya',
        age: 5,
        languages: const ['en'],
      );
    });

    test('a new kid starts on the protocol defaults', () {
      expect(kid.dailyMinutes, 60);
      expect(kid.breakAfterMinutes, 25);
    });

    test('updating limits sticks', () async {
      final updated = await gateway.updateLimits(
        kid.id,
        dailyMinutes: 0,
        breakAfterMinutes: 15,
      );
      expect(updated.dailyMinutes, 0);
      expect(updated.breakAfterMinutes, 15);
      // And unnamed settings are left alone.
      expect(updated.breakMinutes, 5);
      final kids = await gateway.kids();
      expect(kids.single.breakAfterMinutes, 15);
    });

    test('a triggered break blocks watching and blocks POST /sessions', () async {
      gateway.startDemoBreak(kid.id, source: 'Every Kind of Volcano');

      final state = await gateway.watchState(kid.id);
      expect(state.watchingAllowed, isFalse);
      expect(state.blockedReason, BlockedReason.movementBreak);
      expect(state.activeBreak!.task.title, 'Be a volcano');
      expect(state.activeBreak!.sourceTitles, ['Every Kind of Volcano']);

      final start = await gateway.startSession(
        kidId: kid.id,
        videoId: 'pZw9veQ76fo',
        device: 'test',
      );
      expect(start, isA<SessionBlockedByBreak>());
    });

    test('the ack records but does not shorten', () async {
      final started = gateway.startDemoBreak(kid.id);
      final acked = await gateway.ackBreak(kid.id);
      expect(acked.acked, isTrue);
      expect(acked.id, started.id);
      final state = await gateway.watchState(kid.id);
      expect(state.watchingAllowed, isFalse, reason: 'the ack ended it');
      expect(state.activeBreak!.secondsLeft, greaterThan(0));
    });

    test('a parent override clears it', () async {
      gateway.startDemoBreak(kid.id);
      await gateway.overrideBreak(kid.id);
      final state = await gateway.watchState(kid.id);
      expect(state.watchingAllowed, isTrue);
      expect(state.activeBreak, isNull);
      expect(
        await gateway.startSession(
          kidId: kid.id,
          videoId: 'pZw9veQ76fo',
          device: 'test',
        ),
        isA<SessionStarted>(),
      );
    });

    test('using up the day is a daily_limit, with no break to do', () async {
      gateway.useUpTheDay(kid.id);
      final state = await gateway.watchState(kid.id);
      expect(state.isDayDone, isTrue);
      expect(state.isOnBreak, isFalse);
      expect(state.minutesLeftToday, 0);
    });

    test('a kid with no daily limit is never day-done', () async {
      await gateway.updateLimits(kid.id, dailyMinutes: 0);
      gateway.useUpTheDay(kid.id);
      expect((await gateway.watchState(kid.id)).watchingAllowed, isTrue);
    });

    test('the break task is built from what they just watched', () {
      expect(
        gateway.startDemoBreak(kid.id, source: 'Five Little Ducks').task.title,
        contains('ducks'),
      );
      gateway.clearDemoLimits(kid.id);
      expect(
        gateway
            .startDemoBreak(kid.id, source: 'How Ears Let Us Hear the World')
            .task
            .title,
        'Listen like a squirrel',
      );
    });

    test('every built-in task is one a child can do on a rug', () {
      // PROTOCOL safety rules, enforced in code and not only in a prompt.
      const banned = [
        'jump',
        'climb',
        'run',
        'stairs',
        'outside',
        'kitchen',
        'water',
        'spin fast',
        'fetch',
        'get a',
      ];
      for (final source in const [
        'Every Kind of Volcano',
        'Five Little Ducks',
        'How Ears Let Us Hear the World',
        'Something else entirely',
      ]) {
        gateway.clearDemoLimits(kid.id);
        final task = gateway.startDemoBreak(kid.id, source: source).task;
        final words = '${task.title} ${task.steps.join(' ')} ${task.spoken}'
            .toLowerCase();
        for (final b in banned) {
          expect(words, isNot(contains(b)), reason: '$source contains "$b"');
        }
        expect(task.steps, isNotEmpty);
        expect(task.spoken, isNotEmpty, reason: 'band 4_6 hears it or nothing');
      }
    });
  });

  group('the break screen', () {
    late FakeGateway gateway;
    late AppState app;
    late Kid preReader;
    late Kid reader;

    // Everything that talks to the gateway happens here: FakeGateway's
    // simulated network lag is a real delay, and inside testWidgets the clock
    // is the tester's, so an awaited one there would never come back.
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      preReader = await gateway.createKid(
        nickname: 'Zoya',
        age: 5,
        languages: const ['en'],
      );
      reader = await gateway.createKid(
        nickname: 'Bilal',
        age: 9,
        languages: const ['en'],
      );
    });

    MovementBreak aBreak(String kidId, {int seconds = 4}) => MovementBreak(
      id: 'brk_test',
      kidId: kidId,
      startedAt: DateTime.now().toIso8601String(),
      endsAt: DateTime.now()
          .add(Duration(seconds: seconds))
          .toIso8601String(),
      secondsLeft: seconds,
      task: const BreakTask(
        title: 'Be a volcano',
        steps: ['Crouch down small', 'Push your arms up and go whoosh'],
        seconds: 120,
        spoken: 'Let us be a volcano!',
      ),
      sourceTitles: const ['Every Kind of Volcano'],
    );

    Widget host(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<GilliVoice>(create: (_) => _SilentVoice()),
      ],
      child: MaterialApp(home: child),
    );

    Future<void> pumpBreak(
      WidgetTester tester,
      Kid kid, {
      int seconds = 4,
      VoidCallback? onFinished,
    }) async {
      await tester.pumpWidget(
        host(
          BreakScreen(
            kid: kid,
            movementBreak: aBreak(kid.id, seconds: seconds),
            onFinished: onFinished ?? () {},
          ),
        ),
      );
      await tester.pump();
    }

    /// Runs the break's clock down past [seconds], a second at a time.
    Future<void> runOut(WidgetTester tester, int seconds) async {
      for (var i = 0; i <= seconds; i++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }
    }

    testWidgets('band 4_6 sees no text at all during a break', (tester) async {
      await pumpBreak(tester, preReader, seconds: 30);
      await tester.pump(const Duration(milliseconds: 500));

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      expect(
        texts,
        isEmpty,
        reason: 'a pre-reader was shown text: $texts (SPEC 5.1)',
      );
      // The task still reaches them: there is a way to say "I did it", and
      // the spoken line is what carries the task itself.
      expect(find.bySemanticsLabel('I did it'), findsOneWidget);
      await runOut(tester, 31);
    });

    testWidgets('bands 7+ get the task title and its steps', (tester) async {
      await pumpBreak(tester, reader, seconds: 30);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Be a volcano'), findsOneWidget);
      expect(find.text('Crouch down small'), findsOneWidget);
      expect(find.text('Push your arms up and go whoosh'), findsOneWidget);
      // The countdown, and an honest line about what the button does.
      expect(find.textContaining(RegExp(r'^\d+:\d\d$')), findsOneWidget);
      expect(
        find.text('The video comes back when the timer runs out.'),
        findsOneWidget,
      );
      await runOut(tester, 31);
    });

    testWidgets('the countdown running out releases the child', (
      tester,
    ) async {
      var finished = 0;
      await pumpBreak(
        tester,
        reader,
        seconds: 3,
        onFinished: () => finished++,
      );
      expect(finished, 0, reason: 'released before the timer ran');

      await runOut(tester, 4);
      expect(finished, 1, reason: 'the timer ran out and nothing happened');
    });

    testWidgets('"I did it" praises but does not shorten the timer', (
      tester,
    ) async {
      var finished = 0;
      await pumpBreak(
        tester,
        reader,
        seconds: 8,
        onFinished: () => finished++,
      );
      final before = _clockOnScreen(tester);
      expect(before, isNotEmpty);

      await tester.tap(find.text('I did it'));
      await tester.pump();
      await tester.pump();

      expect(
        _clockOnScreen(tester),
        before,
        reason: 'the ack took time off the clock',
      );
      expect(finished, 0, reason: 'the ack ended the break');
      // Warm, and honest about what just happened.
      expect(find.text('Nice one'), findsOneWidget);
      expect(
        find.text('Nice moving. Gilli will call you when the time is up.'),
        findsOneWidget,
      );

      // It still ends on its own clock, a little later.
      await runOut(tester, 9);
      expect(finished, 1);
    });

    testWidgets('a child cannot back out of a break', (tester) async {
      await pumpBreak(tester, reader, seconds: 30);
      expect(
        find.byWidgetPredicate((w) => w is PopScope && !w.canPop),
        findsOneWidget,
        reason: 'back would have dismissed the break',
      );
      await runOut(tester, 31);
    });

    testWidgets('the end of the day is calm, and says when it comes back', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(Scaffold(body: DayDoneScreen(kid: reader))),
      );
      await tester.pump();
      expect(find.text('That is all for today'), findsOneWidget);
      expect(
        find.text('Gilli will be here again tomorrow morning.'),
        findsOneWidget,
      );
    });

    testWidgets('band 4_6 sees no text at the end of the day either', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(Scaffold(body: DayDoneScreen(kid: preReader))),
      );
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });
  });
}

/// The clock as it is drawn right now ("2:41").
String _clockOnScreen(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .firstWhere((s) => RegExp(r'^\d+:\d\d$').hasMatch(s), orElse: () => '');

/// Gilli with the sound turned off: the widget tests are about what a child
/// sees, and the real voice reaches for a platform channel.
class _SilentVoice extends GilliVoice {
  @override
  Future<void> say({
    required String url,
    String? fallbackText,
    String language = 'en',
    bool slow = false,
  }) async {}

  @override
  Future<void> stop() async {}
}
