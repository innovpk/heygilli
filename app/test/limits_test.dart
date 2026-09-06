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

/// Time limits and break periods, against the shapes in
/// docs/PROTOCOL.md "Time limits and break periods".
///
/// The line running through all of it: every word a child hears during a
/// break was written by their parent. Nothing here should pass if a model,
/// or this app, can put a sentence in front of a child on its own.
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

  group('WatchState and BreakPeriod', () {
    final breakJson = {
      'id': 'brk_1',
      'kid_id': 'k1',
      'started_at': '2026-09-06T10:00:00Z',
      'ends_at': '2026-09-06T10:05:00Z',
      'seconds_left': 214,
      'message': {
        'id': 'msg_1',
        'text': 'Time to stretch. Ammi is in the kitchen if you want a snack.',
        'spoken':
            'Time to stretch! Ammi is in the kitchen if you want a snack.',
      },
      'is_firm': true,
      'acked': false,
    };

    test('a break parses whole', () {
      final b = BreakPeriod.fromJson(breakJson);
      expect(b.id, 'brk_1');
      expect(b.kidId, 'k1');
      expect(b.secondsLeft, 214);
      expect(b.acked, isFalse);
      expect(b.isFirm, isTrue);
      expect(b.message!.id, 'msg_1');
      expect(b.message!.text, startsWith('Time to stretch'));
      expect(b.message!.spoken, startsWith('Time to stretch'));
    });

    test('a break with no message is a quiet break, not a broken one', () {
      // A parent who saved no lines gets silence. If this threw, or invented
      // a line, the app would be speaking for them.
      for (final j in [
        {'id': 'brk_2', 'kid_id': 'k1', 'seconds_left': 60},
        {'id': 'brk_2', 'kid_id': 'k1', 'seconds_left': 60, 'message': null},
      ]) {
        final b = BreakPeriod.fromJson(j);
        expect(b.message, isNull, reason: '$j');
        expect(b.secondsLeft, 60);
      }
    });

    test('a message with no spoken line is still said out loud', () {
      // Band 4_6 sees nothing, so a line that is text-only would be a break
      // where a pre-reader is told nothing at all.
      const m = BreakMessage(text: 'Go and stretch your legs.');
      expect(m.speech, 'Go and stretch your legs.');
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
      expect(s.activeBreak!.message!.text, startsWith('Time to stretch'));
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
      expect(back.activeBreak!.message!.text, s.activeBreak!.message!.text);
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
            'message': {
              'id': 'msg_2',
              'text': 'Break time. Go say salaam to Nano.',
            },
          },
        }),
      );
      expect(m, isA<BreakStartedMessage>());
      final b = (m as BreakStartedMessage).movementBreak;
      expect(b.secondsLeft, 300);
      expect(b.message!.text, 'Break time. Go say salaam to Nano.');
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
      'message': {'id': 'msg_3', 'text': 'Break time. Drink some water.'},
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
          breakFromErrorBody(body)?.message?.text,
          'Break time. Drink some water.',
          reason: body,
        );
      }
    });

    test('a quiet break in a 409 is still found', () async {
      // No message on it, because the parent saved no lines. The child is
      // still on a break, and the app must not shrug and start the video.
      final api = clientAnswering(409, {
        'break': {'id': 'brk_9', 'kid_id': 'k1', 'seconds_left': 180},
      });
      final r = await api.startSession(
        kidId: 'k1',
        videoId: 'v1',
        device: 'android',
      );
      expect(r, isA<SessionBlockedByBreak>());
      expect((r as SessionBlockedByBreak).activeBreak.message, isNull);
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

  group('the break-message endpoints, against the wire', () {
    // The gateway names the two lists differently on purpose — drafts are
    // "suggestions", saved lines are "messages" — and reading the wrong key
    // fails silently: the parent taps Ideas and nothing appears. That is
    // exactly what happened, so both envelopes are pinned here.
    late http.Request seen;

    ApiClient clientAnswering(Object body) => ApiClient(
      baseUrl: 'http://gateway',
      token: 't',
      client: MockClient((r) async {
        seen = r;
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    test('suggestions are read from "suggestions"', () async {
      final api = clientAnswering({
        'suggestions': [
          {'id': 'draft_1', 'text': 'Break time.', 'spoken': 'Break time!'},
        ],
        'rejected': [],
        'based_on': ['Every Kind of Volcano'],
      });
      final drafts = await api.suggestBreakMessages('k1');
      expect(seen.url.path, '/kids/k1/break-messages/suggest');
      expect(drafts.single.text, 'Break time.');
      expect(drafts.single.spoken, 'Break time!');
    });

    test('a gateway with no ideas to offer is empty, not an error', () async {
      final api = clientAnswering({'suggestions': [], 'rejected': []});
      expect(await api.suggestBreakMessages('k1'), isEmpty);
    });

    test('saved lines are PUT under "messages"', () async {
      final api = clientAnswering({
        'id': 'k1',
        'nickname': 'Zoya',
        'age': 8,
        'break_messages': [
          {'id': 'msg_1', 'text': 'Break time.', 'spoken': ''},
        ],
      });
      final kid = await api.saveBreakMessages('k1', const [
        BreakMessage(text: 'Break time.'),
      ]);
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/kids/k1/break-messages');
      final sent = jsonDecode(seen.body) as Map<String, dynamic>;
      expect((sent['messages'] as List).single, {
        'id': '',
        'text': 'Break time.',
        'spoken': '',
      });
      expect(kid.breakMessages.single.id, 'msg_1');
    });

    test('clearing the lines sends an empty list, not nothing', () async {
      // A PUT with no messages is how "quiet break" is saved. If this sent
      // null the gateway would keep the old lines and the parent's change
      // would silently not take.
      final api = clientAnswering({'id': 'k1', 'nickname': 'Zoya', 'age': 8});
      await api.saveBreakMessages('k1', const []);
      expect(jsonDecode(seen.body), {'messages': <Object>[]});
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

    test(
      'a triggered break blocks watching and blocks POST /sessions',
      () async {
        await gateway.saveBreakMessages(kid.id, const [
          BreakMessage(text: 'Break time. Go and stretch your legs.'),
        ]);
        gateway.startDemoBreak(kid.id);

        final state = await gateway.watchState(kid.id);
        expect(state.watchingAllowed, isFalse);
        expect(state.blockedReason, BlockedReason.movementBreak);
        expect(
          state.activeBreak!.message!.text,
          'Break time. Go and stretch your legs.',
        );

        final start = await gateway.startSession(
          kidId: kid.id,
          videoId: 'pZw9veQ76fo',
          device: 'test',
        );
        expect(start, isA<SessionBlockedByBreak>());
      },
    );

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

    test('a break reads the line the parent saved, and no other', () async {
      await gateway.saveBreakMessages(kid.id, const [
        BreakMessage(text: 'Break time. Go and say salaam to Nano.'),
      ]);
      final b = gateway.startDemoBreak(kid.id);
      expect(b.message!.text, 'Break time. Go and say salaam to Nano.');
    });

    test(
      'saved lines are rotated, so the same one is not read every time',
      () async {
        await gateway.saveBreakMessages(kid.id, const [
          BreakMessage(text: 'First line.'),
          BreakMessage(text: 'Second line.'),
        ]);
        final heard = <String>[];
        for (var i = 0; i < 3; i++) {
          heard.add(gateway.startDemoBreak(kid.id).message!.text);
          gateway.clearDemoLimits(kid.id);
        }
        expect(heard, ['First line.', 'Second line.', 'First line.']);
      },
    );

    test('a parent who saved nothing gets a quiet break', () {
      // Not a fallback line, not a generated one: silence is the answer when
      // a parent has not written anything for Gilli to say.
      expect(gateway.startDemoBreak(kid.id).message, isNull);
    });

    test('clearing the lines goes back to a quiet break', () async {
      await gateway.saveBreakMessages(kid.id, const [
        BreakMessage(text: 'Break time.'),
      ]);
      await gateway.saveBreakMessages(kid.id, const []);
      expect((await gateway.kids()).single.breakMessages, isEmpty);
      expect(gateway.startDemoBreak(kid.id).message, isNull);
    });

    test(
      'suggestions are drafts and reach no child until they are saved',
      () async {
        final drafts = await gateway.suggestBreakMessages(kid.id);
        expect(drafts, isNotEmpty);
        // Suggesting changed nothing about what this child will hear.
        expect((await gateway.kids()).single.breakMessages, isEmpty);
        expect(gateway.startDemoBreak(kid.id).message, isNull);
        gateway.clearDemoLimits(kid.id);

        // Only the parent's save puts one in front of a child.
        await gateway.saveBreakMessages(kid.id, [drafts.first]);
        expect(gateway.startDemoBreak(kid.id).message!.text, drafts.first.text);
      },
    );

    test('every saved line is something Gilli can say out loud', () async {
      // Band 4_6 sees no text, so a line with nothing to speak would be a
      // break where a pre-reader is told nothing at all.
      final drafts = await gateway.suggestBreakMessages(kid.id);
      for (final d in drafts) {
        expect(d.speech, isNotEmpty, reason: d.text);
      }
    });

    test('a firm break is the default and a parent can soften it', () async {
      expect(gateway.startDemoBreak(kid.id).isFirm, isTrue);
      gateway.clearDemoLimits(kid.id);
      await gateway.updateLimits(kid.id, breakIsFirm: false);
      expect(gateway.startDemoBreak(kid.id).isFirm, isFalse);
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

    /// A break carrying [message], which is the parent's own line. Passing
    /// null is a parent who saved nothing: a quiet break.
    BreakPeriod aBreak(
      String kidId, {
      int seconds = 4,
      bool isFirm = true,
      BreakMessage? message = const BreakMessage(
        id: 'msg_1',
        text: 'Break time. Go and stretch your legs.',
        spoken: 'Break time! Go and stretch your legs.',
      ),
    }) => BreakPeriod(
      id: 'brk_test',
      kidId: kidId,
      startedAt: DateTime.now().toIso8601String(),
      endsAt: DateTime.now().add(Duration(seconds: seconds)).toIso8601String(),
      secondsLeft: seconds,
      isFirm: isFirm,
      message: message,
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
      bool isFirm = true,
      bool quiet = false,
      VoidCallback? onFinished,
    }) async {
      await tester.pumpWidget(
        host(
          BreakScreen(
            kid: kid,
            breakPeriod: quiet
                ? aBreak(
                    kid.id,
                    seconds: seconds,
                    isFirm: isFirm,
                    message: null,
                  )
                : aBreak(kid.id, seconds: seconds, isFirm: isFirm),
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
      // The parent's line still reaches them: it is spoken, and there is a
      // way to say "I did it".
      expect(find.bySemanticsLabel('I did it'), findsOneWidget);
      await runOut(tester, 31);
    });

    testWidgets("bands 7+ read the parent's line, word for word", (
      tester,
    ) async {
      await pumpBreak(tester, reader, seconds: 30);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.text('Break time. Go and stretch your legs.'),
        findsOneWidget,
      );
      // The countdown, and an honest line about what the button does.
      expect(find.textContaining(RegExp(r'^\d+:\d\d$')), findsOneWidget);
      expect(
        find.text('The video comes back when the timer runs out.'),
        findsOneWidget,
      );
      await runOut(tester, 31);
    });

    testWidgets('the countdown running out releases the child', (tester) async {
      var finished = 0;
      await pumpBreak(tester, reader, seconds: 3, onFinished: () => finished++);
      expect(finished, 0, reason: 'released before the timer ran');

      await runOut(tester, 4);
      expect(finished, 1, reason: 'the timer ran out and nothing happened');
    });

    testWidgets('"I did it" praises but does not shorten the timer', (
      tester,
    ) async {
      var finished = 0;
      await pumpBreak(tester, reader, seconds: 8, onFinished: () => finished++);
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
      // Warm, and honest about what just happened: the tap was heard, and
      // it bought nothing back sooner.
      expect(find.text('Nice one'), findsOneWidget);
      expect(
        find.text('Nice one. Gilli will call you when the time is up.'),
        findsOneWidget,
      );

      // It still ends on its own clock, a little later.
      await runOut(tester, 9);
      expect(finished, 1);
    });

    testWidgets('a quiet break says only that it is break time', (
      tester,
    ) async {
      // The parent saved nothing. Gilli must not fill the gap with an
      // instruction of its own, so all that is left is the fact of the break.
      await pumpBreak(tester, reader, seconds: 30, quiet: true);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('Break time'), findsWidgets);
      expect(
        find.text('Break time. Go and stretch your legs.'),
        findsNothing,
        reason: 'a line no parent wrote was shown',
      );
      await runOut(tester, 31);
    });

    testWidgets('on a soft break "I did it" lets them back', (tester) async {
      // The household chose to ask rather than hold the line, and the wording
      // says what will happen before the child taps.
      var finished = 0;
      await pumpBreak(
        tester,
        reader,
        seconds: 30,
        isFirm: false,
        onFinished: () => finished++,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text('Tap when you are done and the video comes back.'),
        findsOneWidget,
      );

      await tester.tap(find.text('I did it'));
      // Long enough for the ack round-trip: the release waits on it, and
      // FakeGateway's simulated lag runs on the tester's clock.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(finished, 1, reason: 'a soft break held the child anyway');
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
      await tester.pumpWidget(host(Scaffold(body: DayDoneScreen(kid: reader))));
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
