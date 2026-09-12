import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hint for a child who has gone quiet.
///
/// The window used to run out in silence and the video started again, which
/// reads to a child as "your answer did not matter". Now Gilli nudges once —
/// back to the moment in the video, never the answer — and the window starts
/// over. These pin the demo socket to the contract the gateway keeps.
void main() {
  Future<({FakeSession socket, List<ServerMessage> seen})> start({
    required PlannedAsk ask,
    int age = 8,
    Duration hintAfter = const Duration(milliseconds: 150),
    Duration answerWindow = const Duration(milliseconds: 400),
  }) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    final kid = await gateway.createKid(
      nickname: 'Zara',
      age: age,
      languages: const ['en'],
    );
    final video = (await gateway.home(kid.id)).first.videos.first;
    final socket = FakeSession(
      kid: kid,
      video: video,
      plan: [ask],
      answerWindow: answerWindow,
      hintAfter: hintAfter,
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
    expect(seen.whereType<AskMessage>(), hasLength(1));
    return (socket: socket, seen: seen);
  }

  final why = PlannedAsk(
    atS: 1,
    type: 'why',
    input: QuestionInput.voice,
    text: 'Why did it melt?',
    textUr: '',
    expected: const ['the sun'],
    hint: 'Think about where the ice was sitting.',
  );

  test('a quiet child gets the hint, once, and the window again', () async {
    final s = await start(ask: why);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final hints = s.seen.whereType<HintMessage>().toList();
    expect(hints, hasLength(1));
    expect(hints.single.q, 0);
    expect(hints.single.text, 'Think about where the ice was sitting.');
    expect(hints.single.speak, hints.single.text);
    expect(
      s.seen.whereType<ReplyMessage>(),
      isEmpty,
      reason: 'the hint ended the question',
    );

    // Past where the original window would have run out, inside the new one.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(s.seen.whereType<ReplyMessage>(), isEmpty);
    s.socket.send(AnswerMessage.voice(0, 'the sun warmed it up'));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final reply = s.seen.whereType<ReplyMessage>().single;
    expect(reply.result, AnswerResult.correct);
    expect(s.seen.whereType<HintMessage>(), hasLength(1));
  });

  test('an answer before the hint is due gets no hint', () async {
    final s = await start(
      ask: why,
      hintAfter: const Duration(milliseconds: 300),
    );
    s.socket.send(AnswerMessage.voice(0, 'the sun'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(s.seen.whereType<HintMessage>(), isEmpty);
    expect(s.seen.whereType<ReplyMessage>(), hasLength(1));
  });

  test('a pre-reader hears the hint but is shown nothing', () async {
    final s = await start(
      age: 5,
      ask: PlannedAsk(
        atS: 1,
        type: 'name_it',
        input: QuestionInput.voice,
        text: 'What animal is that?',
        textUr: '',
        expected: const ['duck'],
        hint: 'It goes quack.',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final hint = s.seen.whereType<HintMessage>().single;
    expect(hint.text, isNull);
    expect(hint.speak, 'It goes quack.');
  });

  test('a copy-it has nothing to hint at', () async {
    final s = await start(
      age: 5,
      ask: PlannedAsk(
        atS: 1,
        type: 'copy_it',
        input: QuestionInput.copy,
        text: 'Can you quack?',
        textUr: '',
        hint: 'should never be sent',
      ),
      answerWindow: const Duration(milliseconds: 250),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(s.seen.whereType<HintMessage>(), isEmpty);
    expect(s.seen.whereType<ReplyMessage>(), hasLength(1));
  });

  test('the wire shape round-trips', () {
    final m = ServerMessage.fromJson({
      't': 'hint',
      'q': 2,
      'text': 'Look at the tree.',
      'speak': 'Look at the tree.',
      'tts_url': '',
      'listen_ms': 20000,
      'gesture': 'think',
    });
    expect(m, isA<HintMessage>());
    final hint = m as HintMessage;
    expect(hint.q, 2);
    expect(hint.listenMs, 20000);
    expect(hint.gesture, Gesture.think);
    expect(hint.fallbackSpeech, 'Look at the tree.');
  });
}
