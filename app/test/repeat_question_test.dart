import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hearing the question again.
///
/// A child who missed it had nothing to do about it: the window ran out, Gilli
/// said "no worries", and the video started again — which reads to a child as
/// being told their answer did not matter. The repeat goes to the server
/// rather than being replayed on the device, because the server holds the
/// deadline for the question; these pin the demo socket to the same contract
/// the gateway keeps, so the demo and the real thing behave alike.
void main() {
  late FakeGateway gateway;
  late FakeSession socket;
  late List<ServerMessage> seen;
  late StreamSubscription<ServerMessage> sub;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    await gateway.signInDev('parent');
    final kid = await gateway.createKid(
      nickname: 'Zara',
      age: 8,
      languages: const ['en'],
    );
    final video = (await gateway.home(kid.id)).first.videos.first;
    final started =
        await gateway.startSession(
              kidId: kid.id,
              videoId: video.id,
              device: 'test',
            )
            as SessionStarted;
    socket =
        await gateway.openSession(started.session.sessionId) as FakeSession;
    seen = [];
    sub = socket.messages.listen(seen.add);
  });

  tearDown(() async {
    await socket.close();
    await sub.cancel();
  });

  /// Drive the socket to the first question and hand it back.
  Future<AskMessage> firstAsk() async {
    socket.send(const HelloMessage());
    for (var t = 0; t < 600 && !seen.any((m) => m is AskMessage); t += 10) {
      socket.send(PositionMessage(t.toDouble()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return seen.whereType<AskMessage>().single;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  test('asking again sends the same question back down', () async {
    final ask = await firstAsk();
    seen.clear();

    socket.send(RepeatMessage(ask.q));
    await settle();

    final again = seen.whereType<AskMessage>().toList();
    expect(again, hasLength(1), reason: 'the child heard nothing back');
    expect(again.single.q, ask.q);
    expect(again.single.text, ask.text);
    // Asking decided nothing: no reply, and the video has not started again.
    expect(seen.whereType<ReplyMessage>(), isEmpty);
    expect(seen.whereType<ResumeMessage>(), isEmpty);
  });

  test('a second ask is refused, so a session cannot be held open', () async {
    // SPEC 7.4: never repeat a question more than once, in any band. It is
    // also what stops a child with a finger on the button pausing for ever.
    final ask = await firstAsk();
    socket.send(RepeatMessage(ask.q));
    await settle();
    seen.clear();

    socket.send(RepeatMessage(ask.q));
    socket.send(RepeatMessage(ask.q));
    await settle();

    expect(seen.whereType<AskMessage>(), isEmpty);
  });

  test(
    'asking again for a question that is not the live one does nothing',
    () async {
      final ask = await firstAsk();
      seen.clear();

      socket.send(RepeatMessage(ask.q + 5));
      await settle();

      expect(
        seen.whereType<AskMessage>(),
        isEmpty,
        reason: 'a stale tap re-asked the question in front of the child',
      );
    },
  );

  test('the answer after a repeat is scored as a first answer', () async {
    // A repeat that quietly counted as a miss would be worse than no repeat.
    final ask = await firstAsk();
    socket.send(RepeatMessage(ask.q));
    await settle();
    seen.clear();

    socket.send(AnswerMessage.voice(ask.q, 'the sun warmed it up'));
    await settle();

    expect(seen.whereType<ReplyMessage>(), hasLength(1));
  });

  _clockTests();
}

/// The window has to start again, not carry on with whatever was left.
///
/// A child asks to hear it again precisely because they are stuck, which is to
/// say late. Topping it up by nothing would read them the question a second
/// time and then cut them off while they were still thinking — the same
/// failure, with an extra reading of the question in the middle of it.
///
/// Run against a window shortened to a fraction of a second, which is the only
/// way to see the difference without sitting through the real twenty-five.
void _clockTests() {
  test('asking again starts the clock over', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    final kid = await gateway.createKid(
      nickname: 'Zara',
      age: 8,
      languages: const ['en'],
    );
    final video = (await gateway.home(kid.id)).first.videos.first;
    final socket = FakeSession(
      kid: kid,
      video: video,
      plan: [
        PlannedAsk(
          atS: 1,
          type: 'why',
          input: QuestionInput.voice,
          text: 'Why did it melt?',
          textUr: '',
          expected: const ['the sun'],
        ),
      ],
      answerWindow: const Duration(milliseconds: 400),
    );
    final seen = <ServerMessage>[];
    final sub = socket.messages.listen(seen.add);
    addTearDown(() async {
      await socket.close();
      await sub.cancel();
    });

    socket.send(const HelloMessage());
    for (var t = 0; t < 400 && !seen.any((m) => m is AskMessage); t += 1) {
      socket.send(PositionMessage(t.toDouble()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final ask = seen.whereType<AskMessage>().single;

    // Near the end of the original window, ask to hear it again.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    socket.send(RepeatMessage(ask.q));
    // Past where the original deadline was, inside the restarted one.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(
      seen.whereType<ReplyMessage>(),
      isEmpty,
      reason: 'the child was cut off mid-thought after asking to hear it again',
    );
  });
}
