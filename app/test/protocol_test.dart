import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/protocol.dart';

/// Every message type in docs/PROTOCOL.md, decoded from the wire shape the
/// gateway sends and encoded to the shape it expects.
void main() {
  group('server → client', () {
    test('ready', () {
      final m = ServerMessage.decode(
        '{"t":"ready","plan_questions":2,"age_band":"9_11","language":"ur"}',
      );
      expect(m, isA<ReadyMessage>());
      final r = m as ReadyMessage;
      expect(r.planQuestions, 2);
      expect(r.ageBand, '9_11');
      expect(r.language, 'ur');
    });

    test('pause and resume carry no fields', () {
      expect(ServerMessage.decode('{"t":"pause"}'), isA<PauseMessage>());
      expect(ServerMessage.decode('{"t":"resume"}'), isA<ResumeMessage>());
    });

    test('ask with pick options', () {
      final m = ServerMessage.decode(
        jsonEncode({
          't': 'ask',
          'q': 0,
          'type': 'pick_it',
          'input': 'pick',
          'tts_url': 'http://h/tts/abc.mp3',
          'listen_ms': 5000,
          'options': [
            {'icon_id': 'icon_fish', 'label': 'fish'},
            {'icon_id': 'icon_duck', 'label': 'duck'},
            {'icon_id': 'icon_car', 'label': 'car'},
          ],
          'gesture': 'point',
        }),
      );
      final a = m as AskMessage;
      expect(a.q, 0);
      expect(a.type, 'pick_it');
      expect(a.input, QuestionInput.pick);
      expect(a.text, isNull, reason: 'text omitted for band 4_6');
      expect(a.ttsUrl, 'http://h/tts/abc.mp3');
      expect(a.listenMs, 5000);
      expect(a.options.map((o) => o.iconId), [
        'icon_fish',
        'icon_duck',
        'icon_car',
      ]);
      expect(a.gesture, Gesture.point);
    });

    test('ask with text for 7+ and optional Urdu line', () {
      final a =
          ServerMessage.decode(
                jsonEncode({
                  't': 'ask',
                  'q': 1,
                  'type': 'why',
                  'input': 'voice',
                  'text': 'Why did the lava come out?',
                  'text_ur': 'لاوا باہر کیوں نکلا؟',
                  'tts_url': '',
                  'listen_ms': 8000,
                  'gesture': 'think',
                }),
              )
              as AskMessage;
      expect(a.text, 'Why did the lava come out?');
      expect(a.textUr, isNotNull);
      expect(isUrduScript(a.textUr!), isTrue);
      expect(a.fallbackSpeech, a.text);
      expect(a.options, isEmpty);
    });

    test('reply', () {
      final r =
          ServerMessage.decode(
                jsonEncode({
                  't': 'reply',
                  'text': 'Yes! A duck. Du-ck!',
                  'tts_url': '',
                  'result': 'partial',
                  'gesture': 'cheer',
                  'model_word': 'duck',
                }),
              )
              as ReplyMessage;
      expect(r.result, AnswerResult.partial);
      expect(r.gesture, Gesture.cheer);
      expect(r.modelWord, 'duck');
    });

    test('reply result off_topic uses the underscore wire name', () {
      final r =
          ServerMessage.decode(
                '{"t":"reply","tts_url":"","result":"off_topic","gesture":"think"}',
              )
              as ReplyMessage;
      expect(r.result, AnswerResult.offTopic);
      expect(AnswerResult.offTopic.wire, 'off_topic');
    });

    test('end', () {
      final e =
          ServerMessage.decode(
                '{"t":"end","summary_tts_url":"http://h/tts/x.mp3","words_said":["duck","star"]}',
              )
              as EndMessage;
      expect(e.summaryTtsUrl, 'http://h/tts/x.mp3');
      expect(e.wordsSaid, ['duck', 'star']);
    });

    test('error', () {
      final e =
          ServerMessage.decode('{"t":"error","message":"planner timeout"}')
              as ErrorMessage;
      expect(e.message, 'planner timeout');
    });

    test('unknown type does not throw', () {
      final u = ServerMessage.decode('{"t":"confetti","x":1}');
      expect(u, isA<UnknownMessage>());
      expect((u as UnknownMessage).type, 'confetti');
    });

    test('unknown gesture and result fall back safely', () {
      final a =
          ServerMessage.decode(
                '{"t":"ask","q":0,"type":"name_it","input":"voice","tts_url":"","listen_ms":5000,"gesture":"moonwalk"}',
              )
              as AskMessage;
      expect(a.gesture, Gesture.idle);
      final r =
          ServerMessage.decode(
                '{"t":"reply","tts_url":"","result":"weird","gesture":"idle"}',
              )
              as ReplyMessage;
      expect(r.result, AnswerResult.unclear);
    });
  });

  group('client → server', () {
    Map<String, dynamic> wire(ClientMessage m) =>
        jsonDecode(m.encode()) as Map<String, dynamic>;

    test('hello, resumed, bye', () {
      // `can_listen` is always sent and defaults true, so a device that says
      // nothing about its microphone is treated as having one — which is what
      // every client did before the field existed.
      expect(wire(const HelloMessage()), {'t': 'hello', 'can_listen': true});
      expect(wire(const ResumedMessage()), {'t': 'resumed'});
      expect(wire(const ByeMessage()), {'t': 'bye'});
    });

    test('hello says when this device cannot hear an answer', () {
      // The server turns the whole session to pick-it on this, at any age.
      // Without it a voice question on a device with no microphone is a child
      // sitting in front of something they have no way to answer.
      expect(wire(const HelloMessage(canListen: false)), {
        't': 'hello',
        'can_listen': false,
      });
    });

    test('position', () {
      expect(wire(const PositionMessage(12.5)), {
        't': 'position',
        'seconds': 12.5,
      });
    });

    test('answer voice', () {
      expect(wire(const AnswerMessage.voice(1, 'a duck')), {
        't': 'answer',
        'q': 1,
        'input': 'voice',
        'transcript': 'a duck',
      });
    });

    test('answer pick sends option only', () {
      final j = wire(const AnswerMessage.pick(0, 2));
      expect(j, {'t': 'answer', 'q': 0, 'input': 'pick', 'option': 2});
      expect(j.containsKey('transcript'), isFalse);
    });

    test('answer copy and none carry no payload', () {
      expect(wire(const AnswerMessage.copy(3)), {
        't': 'answer',
        'q': 3,
        'input': 'copy',
      });
      expect(wire(const AnswerMessage.none(3)), {
        't': 'answer',
        'q': 3,
        'input': 'none',
      });
    });
  });

  test('isUrduScript', () {
    expect(isUrduScript('مجھے بطخ دکھاؤ'), isTrue);
    expect(isUrduScript('Show me the duck'), isFalse);
    expect(isUrduScript(''), isFalse);
  });
}
