/// Typed WebSocket messages mirroring docs/PROTOCOL.md (v1).
///
/// Every message is `{"t": "<type>", ...}`. Unknown server types decode to
/// [UnknownMessage] instead of throwing, so a newer gateway never crashes an
/// older client mid-session.
library;

import 'dart:convert';

import 'models.dart';

// ---------------------------------------------------------------- helpers

/// True when [s] contains Arabic-script letters (Urdu is written in it).
/// Used to pick the TTS voice and text direction for a line.
bool isUrduScript(String s) => RegExp(r'[\u0600-\u06FF]').hasMatch(s);

// ---------------------------------------------------------------- enums

enum Gesture {
  idle,
  stretch,
  shrink,
  spin,
  point,
  roar,
  think,
  cheer;

  static Gesture fromWire(String? s) =>
      Gesture.values.where((g) => g.name == s).firstOrNull ?? Gesture.idle;
}

/// How the kid answers this question.
enum QuestionInput {
  voice,
  pick,
  copy;

  static QuestionInput fromWire(String? s) =>
      QuestionInput.values.where((g) => g.name == s).firstOrNull ??
      QuestionInput.voice;
}

enum AnswerResult {
  correct,
  partial,
  offTopic('off_topic'),
  unclear,
  silence;

  const AnswerResult([String? wire]) : _wire = wire;
  final String? _wire;
  String get wire => _wire ?? name;

  static AnswerResult fromWire(String? s) =>
      AnswerResult.values.where((r) => r.wire == s).firstOrNull ??
      AnswerResult.unclear;
}

// ---------------------------------------------------------------- server → client

sealed class ServerMessage {
  const ServerMessage();

  /// Decodes one WebSocket frame. Tolerant: missing fields get defaults.
  static ServerMessage decode(String frame) {
    final j = jsonDecode(frame) as Map<String, dynamic>;
    return ServerMessage.fromJson(j);
  }

  static ServerMessage fromJson(Map<String, dynamic> j) {
    switch (j['t']) {
      case 'ready':
        return ReadyMessage(
          planQuestions: (j['plan_questions'] as num?)?.toInt() ?? 0,
          ageBand: j['age_band'] as String? ?? '4_6',
          language: j['language'] as String? ?? 'en',
        );
      case 'pause':
        return const PauseMessage();
      case 'ask':
        return AskMessage(
          q: (j['q'] as num?)?.toInt() ?? 0,
          type: j['type'] as String? ?? 'name_it',
          input: QuestionInput.fromWire(j['input'] as String?),
          text: j['text'] as String?,
          textUr: j['text_ur'] as String?,
          speak: j['speak'] as String?,
          ttsUrl: j['tts_url'] as String? ?? '',
          listenMs: (j['listen_ms'] as num?)?.toInt() ?? 5000,
          options: (j['options'] as List? ?? const [])
              .map((o) => PickOption.fromJson(o as Map<String, dynamic>))
              .toList(),
          gesture: Gesture.fromWire(j['gesture'] as String?),
          revisit: QuestionRevisit.fromJson(j['revisit']),
        );
      case 'reply':
        return ReplyMessage(
          text: j['text'] as String?,
          ttsUrl: j['tts_url'] as String? ?? '',
          result: AnswerResult.fromWire(j['result'] as String?),
          gesture: Gesture.fromWire(j['gesture'] as String?),
          modelWord: j['model_word'] as String?,
        );
      case 'resume':
        return const ResumeMessage();
      case 'break':
        // PROTOCOL "Time limits and movement breaks": stop playback now. A
        // frame with no break in it is dropped rather than opening an empty
        // break screen a child could not leave.
        final b = (j['break'] as Map?)?.cast<String, dynamic>();
        if (b == null) return UnknownMessage('break', j);
        return BreakStartedMessage(BreakPeriod.fromJson(b));
      case 'end':
        return EndMessage(
          summaryTtsUrl: j['summary_tts_url'] as String? ?? '',
          wordsSaid: (j['words_said'] as List? ?? const [])
              .map((e) => '$e')
              .toList(),
          // Not in v1 of the protocol; read if present so the fallback TTS
          // has something to say when summary_tts_url is empty.
          summaryText: j['summary_text'] as String?,
        );
      case 'error':
        return ErrorMessage(j['message'] as String? ?? 'unknown error');
      default:
        return UnknownMessage(j['t']?.toString() ?? '', j);
    }
  }
}

class ReadyMessage extends ServerMessage {
  const ReadyMessage({
    required this.planQuestions,
    required this.ageBand,
    required this.language,
  });
  final int planQuestions;
  final String ageBand;
  final String language;
}

class PauseMessage extends ServerMessage {
  const PauseMessage();
}

class PickOption {
  const PickOption({required this.iconId, required this.label});
  final String iconId;
  final String label;

  factory PickOption.fromJson(Map<String, dynamic> j) => PickOption(
    iconId: j['icon_id'] as String? ?? '',
    label: j['label'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'icon_id': iconId, 'label': label};
}

/// Bookkeeping saying this question is quietly coming back to an earlier
/// concept (PROTOCOL "Revisiting a shaky concept").
///
/// **Nothing here is ever shown or spoken to a child.** A revisit is asked as
/// a fresh question about the video they are watching now; a child noticing
/// they are being retested is the failure mode the whole design avoids. The
/// only screen this reaches is the parent's.
class QuestionRevisit {
  const QuestionRevisit({required this.concept, this.lastSeen = ''});

  final String concept;
  final String lastSeen;

  /// Null for all but at most one question per plan, and null is the norm.
  static QuestionRevisit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final concept = j['concept'] as String? ?? '';
    if (concept.isEmpty) return null;
    return QuestionRevisit(
      concept: concept,
      lastSeen: j['last_seen'] as String? ?? '',
    );
  }
}

class AskMessage extends ServerMessage {
  const AskMessage({
    required this.q,
    required this.type,
    required this.input,
    required this.text,
    this.textUr,
    this.speak,
    required this.ttsUrl,
    required this.listenMs,
    required this.options,
    required this.gesture,
    this.revisit,
  });

  final int q;
  final String type;
  final QuestionInput input;

  /// Omitted by the server for band 4_6. Even when present the client never
  /// renders it for that band; it is only a TTS fallback.
  final String? text;

  /// Proposed v1.1 field: the same question in Urdu, shown as a second line
  /// under the English text for bilingual kids aged 7+ (design/TVOlder).
  /// Never rendered for band 4_6.
  final String? textUr;

  /// Proposed v1.1 field: the spoken line for on-device TTS fallback when
  /// `tts_url` is empty and `text` is omitted (band 4_6). Never rendered.
  final String? speak;
  final String ttsUrl;

  /// What on-device TTS should say if `tts_url` cannot be played.
  String? get fallbackSpeech => speak ?? text;
  final int listenMs;
  final List<PickOption> options;
  final Gesture gesture;

  /// Set on at most one question per plan. Read so the client understands the
  /// frame, and used by nothing on the kid side: it changes no word Gilli
  /// says, nothing on screen, and no timing (PROTOCOL "Revisiting a shaky
  /// concept"). Anything that made a revisit look or sound different would
  /// tell the child they are being retested.
  final QuestionRevisit? revisit;
}

class ReplyMessage extends ServerMessage {
  const ReplyMessage({
    required this.text,
    required this.ttsUrl,
    required this.result,
    required this.gesture,
    required this.modelWord,
  });

  final String? text;
  final String ttsUrl;
  final AnswerResult result;
  final Gesture gesture;

  /// The word Gilli models for pre-readers ("giraffe"). Used for fallback TTS
  /// and, in the future, the digest's words_heard list.
  final String? modelWord;
}

class ResumeMessage extends ServerMessage {
  const ResumeMessage();
}

class EndMessage extends ServerMessage {
  const EndMessage({
    required this.summaryTtsUrl,
    required this.wordsSaid,
    this.summaryText,
  });
  final String summaryTtsUrl;
  final List<String> wordsSaid;
  final String? summaryText;
}

/// `{t: "break", break: BreakPeriod}`. The video stops here and does not
/// come back until the break's own timer runs out.
class BreakStartedMessage extends ServerMessage {
  const BreakStartedMessage(this.movementBreak);
  final BreakPeriod movementBreak;
}

class ErrorMessage extends ServerMessage {
  const ErrorMessage(this.message);
  final String message;
}

class UnknownMessage extends ServerMessage {
  const UnknownMessage(this.type, this.raw);
  final String type;
  final Map<String, dynamic> raw;
}

// ---------------------------------------------------------------- client → server

sealed class ClientMessage {
  const ClientMessage();
  Map<String, dynamic> toJson();
  String encode() => jsonEncode(toJson());
}

class HelloMessage extends ClientMessage {
  const HelloMessage();
  @override
  Map<String, dynamic> toJson() => {'t': 'hello'};
}

class PositionMessage extends ClientMessage {
  const PositionMessage(this.seconds);
  final double seconds;
  @override
  Map<String, dynamic> toJson() => {'t': 'position', 'seconds': seconds};
}

/// One class for all four answer shapes; only the fields for [input] are sent.
class AnswerMessage extends ClientMessage {
  const AnswerMessage.voice(this.q, this.transcript)
    : input = 'voice',
      option = null;
  const AnswerMessage.pick(this.q, this.option)
    : input = 'pick',
      transcript = null;
  const AnswerMessage.copy(this.q)
    : input = 'copy',
      transcript = null,
      option = null;
  const AnswerMessage.none(this.q)
    : input = 'none',
      transcript = null,
      option = null;

  final int q;
  final String input;
  final String? transcript;
  final int? option;

  @override
  Map<String, dynamic> toJson() => {
    't': 'answer',
    'q': q,
    'input': input,
    if (transcript != null) 'transcript': transcript,
    if (option != null) 'option': option,
  };
}

class ResumedMessage extends ClientMessage {
  const ResumedMessage();
  @override
  Map<String, dynamic> toJson() => {'t': 'resumed'};
}

class ByeMessage extends ClientMessage {
  const ByeMessage();
  @override
  Map<String, dynamic> toJson() => {'t': 'bye'};
}
