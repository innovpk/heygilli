import 'dart:async';

import 'gateway.dart';
import 'models.dart';
import 'protocol.dart';
import 'session_socket.dart';

/// In-app stand-in for the Python gateway.
///
/// Used when the gateway is unreachable at startup or when built with
/// `--dart-define=HEYGILLI_DEMO=true`. It implements the same REST and
/// WebSocket surface with canned data so every screen can be exercised
/// offline. A visible "demo" badge is shown whenever this class is active so
/// nobody mistakes it for the live agents.
class FakeGateway implements Gateway {
  FakeGateway();

  @override
  bool get isDemo => true;

  bool _signedIn = false;

  @override
  bool get signedIn => _signedIn;

  // ---------------------------------------------------------------- canned data

  final _kids = <Kid>[
    const Kid(
      id: 'kid_zara',
      nickname: 'Zara',
      age: 4,
      band: AgeBand.b4to6,
      languages: ['en', 'ur'],
    ),
    const Kid(
      id: 'kid_ayaan',
      nickname: 'Ayaan',
      age: 9,
      band: AgeBand.b9to11,
      languages: ['en', 'ur'],
    ),
  ];

  static const _sss = Channel(
    id: 'ch_supersimple',
    title: 'Super Simple Songs',
    thumbUrl: 'https://i.ytimg.com/vi/pZw9veQ76fo/hqdefault.jpg',
    approved: true,
  );
  static const _ssk = Channel(
    id: 'ch_scishowkids',
    title: 'SciShow Kids',
    thumbUrl: 'https://i.ytimg.com/vi/0jKoOUZ1GBM/hqdefault.jpg',
    approved: true,
  );

  final _channels = <String, List<Channel>>{
    'kid_zara': [_sss, _ssk],
    'kid_ayaan': [_ssk, _sss],
  };

  // Real, public, embeddable videos from well-known kids' channels.
  static const _ducks = Video(
    id: 'pZw9veQ76fo',
    channelId: 'ch_supersimple',
    title: 'Five Little Ducks',
    durationS: 172,
    planReady: true,
  );
  static const _twinkle = Video(
    id: 'yCjJyiqpAuU',
    channelId: 'ch_supersimple',
    title: 'Twinkle Twinkle Little Star',
    durationS: 171,
    planReady: true,
  );
  static const _volcano = Video(
    id: '0jKoOUZ1GBM',
    channelId: 'ch_scishowkids',
    title: 'Every Kind of Volcano',
    durationS: 330,
    planReady: true,
  );
  static const _ears = Video(
    id: '6WNHyAXIN8c',
    channelId: 'ch_scishowkids',
    title: 'How Ears Let Us Hear the World',
    durationS: 300,
    planReady: true,
  );

  /// Demo plans fire early (seconds, not minutes) so a judge sees the loop
  /// inside a 5-minute video. The live Planner follows SPEC 7.3 timing.
  static final _plans = <String, List<PlannedAsk>>{
    _ducks.id: [
      PlannedAsk(
        atS: 12,
        type: 'pick_it',
        input: QuestionInput.pick,
        text: 'Show me the duck!',
        textUr: 'مجھے بطخ دکھاؤ',
        options: const [
          PickOption(iconId: 'icon_fish', label: 'fish'),
          PickOption(iconId: 'icon_duck', label: 'duck'),
          PickOption(iconId: 'icon_car', label: 'car'),
        ],
        correctOption: 1,
        modelWord: 'duck',
      ),
      PlannedAsk(
        atS: 40,
        type: 'name_it',
        input: QuestionInput.voice,
        text: 'What animal is that?',
        textUr: 'یہ کون سا جانور ہے؟',
        expected: const ['duck', 'ducks', 'duckling'],
        modelWord: 'duck',
      ),
    ],
    _twinkle.id: [
      PlannedAsk(
        atS: 12,
        type: 'name_it',
        input: QuestionInput.voice,
        text: 'What is shining in the sky?',
        textUr: 'آسمان میں کیا چمک رہا ہے؟',
        expected: const ['star', 'stars', 'twinkle'],
        modelWord: 'star',
      ),
      PlannedAsk(
        atS: 40,
        type: 'pick_it',
        input: QuestionInput.pick,
        text: 'Show me the star!',
        textUr: 'مجھے ستارہ دکھاؤ',
        options: const [
          PickOption(iconId: 'icon_star', label: 'star'),
          PickOption(iconId: 'icon_apple', label: 'apple'),
          PickOption(iconId: 'icon_ball', label: 'ball'),
        ],
        correctOption: 0,
        modelWord: 'star',
      ),
    ],
    _volcano.id: [
      PlannedAsk(
        atS: 15,
        type: 'recall',
        input: QuestionInput.voice,
        text: 'What comes out of a volcano when it erupts?',
        textUr: 'جب آتش فشاں پھٹتا ہے تو اس سے کیا نکلتا ہے؟',
        expected: const ['lava', 'ash', 'magma', 'rock', 'gas'],
      ),
      PlannedAsk(
        atS: 50,
        type: 'why',
        input: QuestionInput.voice,
        text: 'Why did the lava come out?',
        textUr: 'لاوا باہر کیوں نکلا؟',
        expected: const ['pressure', 'push', 'hot', 'gas', 'build'],
      ),
    ],
    _ears.id: [
      PlannedAsk(
        atS: 15,
        type: 'recall',
        input: QuestionInput.voice,
        text: 'What part of the ear catches the sound first?',
        textUr: 'کان کا کون سا حصہ آواز کو سب سے پہلے پکڑتا ہے؟',
        expected: const ['outer', 'outside', 'flap', 'pinna', 'ear'],
      ),
      PlannedAsk(
        atS: 50,
        type: 'why',
        input: QuestionInput.voice,
        text: 'Why do we have two ears and not one?',
        textUr: 'ہمارے دو کان کیوں ہیں، ایک کیوں نہیں؟',
        expected: const ['where', 'direction', 'side', 'find', 'both'],
      ),
    ],
  };

  final _inbox = <ParentPrompt>[
    const ParentPrompt(
      id: 'prompt_1',
      kidId: 'kid_ayaan',
      video: Video(
        id: 'WX_E1CAZjaQ',
        channelId: 'ch_scishowkids',
        title: 'KABOOM! All About Volcanoes (compilation)',
        durationS: 1560,
        ageOk: true,
        planReady: false,
      ),
      reason:
          'A 26-minute compilation: longer than Ayaan\'s usual videos and it '
          'shows a real eruption. Fine for 9 to 11 in my view, but you decide.',
      createdAt: '2026-09-05T07:30:00Z',
    ),
  ];

  final _digests = <String, Digest>{
    'kid_zara': const Digest(
      kidId: 'kid_zara',
      date: '',
      minutes: 35,
      videos: 5,
      asked: 6,
      answered: 6,
      understood: [],
      shaky: [],
      wordsSaid: ['duck', 'star', 'three', 'truck'],
      wordsHeard: ['hippo', 'purple'],
      dinnerPrompt: 'Count the cars on the way to school. Stop at five.',
      kind: 'prereader',
    ),
    'kid_ayaan': const Digest(
      kidId: 'kid_ayaan',
      date: '',
      minutes: 42,
      videos: 4,
      asked: 9,
      answered: 6,
      understood: ['Volcanoes erupt when pressure builds up underground.'],
      shaky: ['Why the moon changes shape.'],
      wordsSaid: [],
      wordsHeard: [],
      dinnerPrompt:
          'What would happen if you shook a fizzy drink and opened it?',
      kind: 'older',
    ),
  };

  // ---------------------------------------------------------------- REST

  @override
  Future<void> signInDev(String name) async {
    await _lag();
    _signedIn = true;
  }

  @override
  Future<List<Kid>> kids() async {
    await _lag();
    return List.unmodifiable(_kids);
  }

  @override
  Future<Kid> createKid({
    required String nickname,
    required int age,
    required List<String> languages,
  }) async {
    await _lag();
    final kid = Kid(
      id: 'kid_${DateTime.now().millisecondsSinceEpoch}',
      nickname: nickname,
      age: age,
      band: AgeBand.forAge(age),
      languages: languages,
    );
    _kids.add(kid);
    _channels[kid.id] = [];
    return kid;
  }

  @override
  Future<List<Channel>> channels(String kidId) async {
    await _lag();
    return List.unmodifiable(_channels[kidId] ?? const []);
  }

  @override
  Future<Channel> addChannel(String kidId, String url) async {
    await _lag();
    // The live gateway resolves handles and video URLs; the demo just names
    // the channel after the URL's last path segment.
    final handle = Uri.tryParse(url)?.pathSegments.lastOrNull ?? url;
    final ch = Channel(
      id: 'ch_${handle.hashCode.abs()}',
      title: handle.replaceFirst('@', ''),
      thumbUrl: '',
      approved: true,
    );
    (_channels[kidId] ??= []).add(ch);
    return ch;
  }

  @override
  Future<List<HomeRow>> home(String kidId) async {
    await _lag();
    final kid = _kids.where((k) => k.id == kidId).firstOrNull;
    if (kid == null) return const [];
    if (kid.band == AgeBand.b4to6) {
      return const [
        HomeRow(title: 'New from your channels', videos: [_ducks, _twinkle]),
        HomeRow(title: 'Keep watching', videos: [_ears, _volcano]),
      ];
    }
    return const [
      HomeRow(title: 'New from your channels', videos: [_volcano, _ears]),
      HomeRow(title: 'Keep watching', videos: [_twinkle, _ducks]),
    ];
  }

  final _sessions = <String, _FakeSessionInfo>{};

  @override
  Future<SessionStart> startSession({
    required String kidId,
    required String videoId,
    required String device,
  }) async {
    await _lag();
    final kid = _kids.firstWhere((k) => k.id == kidId);
    final video = [_ducks, _twinkle, _volcano, _ears].firstWhere(
      (v) => v.id == videoId,
      orElse: () => Video(
        id: videoId,
        channelId: '',
        title: videoId,
        durationS: 0,
        planReady: false,
      ),
    );
    final id = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    _sessions[id] = _FakeSessionInfo(kid: kid, video: video);
    return SessionStart(sessionId: id, video: video, planReady: true);
  }

  @override
  Future<SessionSocket> openSession(String sessionId) async {
    final info = _sessions[sessionId]!;
    return FakeSession(
      kid: info.kid,
      video: info.video,
      plan: _plans[info.video.id] ?? const [],
    );
  }

  @override
  Future<void> endSession(String sessionId) async {
    _sessions.remove(sessionId);
  }

  @override
  Future<Digest> digest(String kidId, String date) async {
    await _lag();
    final d = _digests[kidId];
    if (d == null) {
      return Digest(
        kidId: kidId,
        date: date,
        minutes: 0,
        videos: 0,
        asked: 0,
        answered: 0,
        understood: const [],
        shaky: const [],
        wordsSaid: const [],
        wordsHeard: const [],
        dinnerPrompt: '',
        kind:
            _kids.where((k) => k.id == kidId).firstOrNull?.band == AgeBand.b4to6
            ? 'prereader'
            : 'older',
      );
    }
    return Digest.fromJson({...d.toJson(), 'date': date});
  }

  @override
  Future<Digest> runDigest(String kidId) =>
      digest(kidId, DateTime.now().toIso8601String().substring(0, 10));

  @override
  Future<List<ParentPrompt>> inbox() async {
    await _lag();
    return List.unmodifiable(_inbox);
  }

  @override
  Future<void> decide(String promptId, String decision) async {
    await _lag();
    _inbox.removeWhere((p) => p.id == promptId);
  }

  Future<void> _lag() =>
      Future<void>.delayed(const Duration(milliseconds: 250));
}

class _FakeSessionInfo {
  _FakeSessionInfo({required this.kid, required this.video});
  final Kid kid;
  final Video video;
}

class PlannedAsk {
  PlannedAsk({
    required this.atS,
    required this.type,
    required this.input,
    required this.text,
    required this.textUr,
    this.options = const [],
    this.correctOption,
    this.expected = const [],
    this.modelWord,
  });

  final int atS;
  final String type;
  final QuestionInput input;
  final String text;
  final String textUr;
  final List<PickOption> options;
  final int? correctOption;
  final List<String> expected;
  final String? modelWord;
}

/// Scripted server side of one session. Watches `position` messages and runs
/// pause → ask → (answer) → reply → resume for each planned question, scoring
/// answers the way SPEC 7.4 describes (forgiving for pre-readers).
class FakeSession implements SessionSocket {
  FakeSession({required this.kid, required this.video, required this.plan}) {
    _out = StreamController<ServerMessage>.broadcast();
  }

  final Kid kid;
  final Video video;
  final List<PlannedAsk> plan;

  late final StreamController<ServerMessage> _out;
  int _nextQ = 0;
  bool _busy = false;
  bool _closed = false;
  Completer<ClientMessage?>? _awaitingAnswer;
  Timer? _answerTimeout;

  /// The language Gilli speaks in this session. Demo rule: Urdu if the kid's
  /// profile lists it, else English.
  String get language => kid.speaksUrdu ? 'ur' : 'en';

  @override
  Stream<ServerMessage> get messages => _out.stream;

  @override
  void send(ClientMessage message) {
    if (_closed) return;
    switch (message) {
      case HelloMessage():
        _emit(
          ReadyMessage(
            planQuestions: plan.length,
            ageBand: kid.band.wire,
            language: language,
          ),
        );
      case PositionMessage(:final seconds):
        if (_busy) return;
        if (_nextQ < plan.length && seconds >= plan[_nextQ].atS) {
          _runQuestion(_nextQ);
        } else if (video.durationS > 0 && seconds >= video.durationS - 1) {
          // The live gateway sends `end` when the video finishes; so do we.
          _end();
        }
      case AnswerMessage():
        _awaitingAnswer?.complete(message);
      case ResumedMessage():
        break;
      case ByeMessage():
        close();
    }
  }

  Future<void> _runQuestion(int index) async {
    _busy = true;
    final ask = plan[index];
    _emit(const PauseMessage());
    await _wait(400);

    final band = kid.band;
    final urdu = language == 'ur';
    _emit(
      AskMessage(
        q: index,
        type: ask.type,
        input: ask.input,
        // Text is omitted for 4_6 exactly like the live gateway. The client
        // then relies on tts_url or, in demo, on-device TTS of `speak`.
        text: band == AgeBand.b4to6 ? null : ask.text,
        // Bilingual kids 7+ get the Urdu line under the English question.
        textUr: band == AgeBand.b4to6 || !urdu ? null : ask.textUr,
        // Demo has no cloud TTS, so the client falls back to on-device TTS.
        // `speak` carries the spoken line for 4_6 (proposed v1.1 field). It
        // is English because most demo devices only ship an English voice.
        speak: ask.text,
        ttsUrl: '',
        listenMs: band.defaultListenMs,
        options: ask.options,
        gesture: ask.input == QuestionInput.pick
            ? Gesture.point
            : Gesture.think,
      ),
    );

    // PROTOCOL: if no answer within listen_ms + 1500 ms, treat as none.
    // The demo allows extra time for the question TTS to finish first.
    _awaitingAnswer = Completer<ClientMessage?>();
    _answerTimeout = Timer(
      Duration(milliseconds: band.defaultListenMs + 1500 + 4000),
      () => _awaitingAnswer?.complete(null),
    );
    final answer = await _awaitingAnswer!.future;
    _answerTimeout?.cancel();
    if (_closed) return;

    final reply = _score(ask, answer is AnswerMessage ? answer : null);
    _emit(reply);
    // Give the client time to speak the reply, then resume.
    await _wait(reply.result == AnswerResult.correct ? 3500 : 5000);
    if (_closed) return;
    _emit(const ResumeMessage());
    _nextQ = index + 1;
    _busy = false;
  }

  ReplyMessage _score(PlannedAsk ask, AnswerMessage? a) {
    // SPEC 7.5: Gilli code-switches. The reply is in Urdu only when the kid
    // answered in Urdu; the default demo voice is English.
    final urdu = language == 'ur' && isUrduScript(a?.transcript ?? '');
    final word = ask.modelWord ?? '';
    final wordUr = _urduWord(word);
    final pre = kid.band == AgeBand.b4to6;

    if (ask.input == QuestionInput.pick) {
      final correct = a?.input == 'pick' && a?.option == ask.correctOption;
      if (correct) {
        return ReplyMessage(
          text: urdu
              ? 'واہ! یہ $wordUr ہے۔ $wordUr!'
              : 'Yes! That is the $word. ${_stretch(word)}!',
          ttsUrl: '',
          result: AnswerResult.correct,
          gesture: Gesture.cheer,
          modelWord: word,
        );
      }
      return ReplyMessage(
        text: urdu
            ? 'یہ $wordUr ہے! $wordUr۔ کیا تم $wordUr کہہ سکتے ہو؟'
            : 'This one is the $word! ${_stretch(word)}. Can you say $word?',
        ttsUrl: '',
        result: a == null ? AnswerResult.silence : AnswerResult.offTopic,
        gesture: Gesture.point,
        modelWord: word,
      );
    }

    if (ask.input == QuestionInput.copy) {
      // Copy-it is never scored (SPEC 7.4).
      return ReplyMessage(
        text: urdu ? 'زبردست!' : 'Great! Listen to mine!',
        ttsUrl: '',
        result: AnswerResult.correct,
        gesture: Gesture.roar,
        modelWord: word,
      );
    }

    final transcript = (a?.transcript ?? '').toLowerCase();
    if (a == null || a.input == 'none' || transcript.isEmpty) {
      if (pre) {
        return ReplyMessage(
          text: urdu
              ? 'یہ $wordUr ہے! $wordUr۔ کیا تم $wordUr کہہ سکتے ہو؟'
              : 'It is a $word! ${_stretch(word)}. Can you say $word?',
          ttsUrl: '',
          result: AnswerResult.silence,
          gesture: Gesture.point,
          modelWord: word,
        );
      }
      return const ReplyMessage(
        text: 'No worries, let\'s keep watching.',
        ttsUrl: '',
        result: AnswerResult.silence,
        gesture: Gesture.idle,
        modelWord: null,
      );
    }

    final hit = ask.expected.any(transcript.contains);
    // Pre-readers: sharing a first sound counts as partial, and partial is
    // treated as success (SPEC 7.4).
    final firstSound =
        pre &&
        word.isNotEmpty &&
        transcript.split(' ').any((w) => w.isNotEmpty && w[0] == word[0]);

    if (hit || firstSound) {
      if (pre) {
        return ReplyMessage(
          text: urdu
              ? 'ہاں! $wordUr۔ $wordUr!'
              : 'Yes! A $word. ${_stretch(word)}!',
          ttsUrl: '',
          result: hit ? AnswerResult.correct : AnswerResult.partial,
          gesture: Gesture.cheer,
          modelWord: word,
        );
      }
      return ReplyMessage(
        text: ask.type == 'why'
            ? 'Right, the pressure underneath pushes it up, like a shaken '
                  'fizzy drink. Let\'s watch what happens next.'
            : 'Exactly. And it is a lot hotter than an oven. Keep watching.',
        ttsUrl: '',
        result: AnswerResult.correct,
        gesture: Gesture.cheer,
        modelWord: null,
      );
    }

    if (pre) {
      return ReplyMessage(
        text: urdu
            ? 'اچھا! میں تو $wordUr دیکھ رہی ہوں۔ $wordUr!'
            : 'A $transcript? I see a $word! ${_stretch(word)}.',
        ttsUrl: '',
        result: AnswerResult.offTopic,
        gesture: Gesture.think,
        modelWord: word,
      );
    }
    return const ReplyMessage(
      text:
          'Interesting! I thought it was the pressure building up '
          'underground. Let\'s watch and see.',
      ttsUrl: '',
      result: AnswerResult.offTopic,
      gesture: Gesture.think,
      modelWord: null,
    );
  }

  /// "giraffe" → "Gi-raffe": the modelled word, said slowly (SPEC 6.3).
  static String _stretch(String w) {
    if (w.length < 4) return w;
    final cut = (w.length / 2).floor();
    return '${w[0].toUpperCase()}${w.substring(1, cut)}-${w.substring(cut)}';
  }

  static String _urduWord(String en) => switch (en) {
    'duck' => 'بطخ',
    'star' => 'ستارہ',
    _ => en,
  };

  bool _ended = false;

  void _end() {
    if (_closed || _ended) return;
    _ended = true;
    final pre = kid.band == AgeBand.b4to6;
    final words = plan.map((p) => p.modelWord).whereType<String>().toList();
    _emit(
      EndMessage(
        summaryTtsUrl: '',
        wordsSaid: words,
        summaryText: pre
            ? 'All done! You saw ${words.join(' and a ')}. Shall we watch one more?'
            : 'You watched a whole video! Want another, or shall we do something?',
      ),
    );
  }

  void _emit(ServerMessage m) {
    if (!_closed) _out.add(m);
  }

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _answerTimeout?.cancel();
    if (_awaitingAnswer != null && !_awaitingAnswer!.isCompleted) {
      _awaitingAnswer!.complete(null);
    }
    await _out.close();
  }
}
