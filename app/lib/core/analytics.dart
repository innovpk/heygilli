/// The Analytics payload from `GET /kids/{id}/analytics?days=N`.
///
/// Shape is fixed by docs/PROTOCOL.md; the gateway is being written in
/// parallel, so every parser here is tolerant: a missing key, a null, or an
/// empty list must never throw. Empty history is a valid response.
library;

import 'models.dart';

class Analytics {
  const Analytics({
    required this.kidId,
    required this.band,
    required this.days,
    required this.generatedAt,
    required this.totals,
    required this.daily,
    required this.vocabulary,
    required this.concepts,
    required this.needsAnotherLook,
    required this.channels,
    required this.note,
  });

  final String kidId;
  final AgeBand band;
  final int days;
  final String generatedAt;
  final AnalyticsTotals totals;

  /// Oldest first, zero days included, so the column chart has one bar per day.
  final List<AnalyticsDay> daily;
  final Vocabulary vocabulary;
  final List<ConceptStat> concepts;
  final List<ShakyConcept> needsAnotherLook;
  final List<ChannelMinutes> channels;
  final AnalyticsNote note;

  /// SPEC 6.5: pre-readers get a vocabulary log, 7+ get a comprehension report.
  /// The band decides which KPI tile and which body section the screen shows.
  bool get isPreReader => band == AgeBand.b4to6;

  /// Empty history is a first-class state: we show one honest line instead of
  /// charts full of zeros.
  bool get hasHistory =>
      totals.minutes > 0 ||
      totals.asked > 0 ||
      daily.any((d) => d.minutes > 0 || d.asked > 0);

  factory Analytics.fromJson(Map<String, dynamic> j) => Analytics(
    kidId: '${j['kid_id'] ?? ''}',
    band: AgeBand.fromWire(j['band'] as String?),
    days: _int(j['days'], 14),
    generatedAt: j['generated_at'] as String? ?? '',
    totals: AnalyticsTotals.fromJson(_map(j['totals'])),
    daily: _list(j['daily']).map(AnalyticsDay.fromJson).toList(),
    vocabulary: Vocabulary.fromJson(_map(j['vocabulary'])),
    concepts: _list(j['concepts']).map(ConceptStat.fromJson).toList(),
    needsAnotherLook: _list(
      j['needs_another_look'],
    ).map(ShakyConcept.fromJson).toList(),
    channels: _list(j['channels']).map(ChannelMinutes.fromJson).toList(),
    note: AnalyticsNote.fromJson(_map(j['note'])),
  );

  Map<String, dynamic> toJson() => {
    'kid_id': kidId,
    'band': band.wire,
    'days': days,
    'generated_at': generatedAt,
    'totals': totals.toJson(),
    'daily': [for (final d in daily) d.toJson()],
    'vocabulary': vocabulary.toJson(),
    'concepts': [for (final c in concepts) c.toJson()],
    'needs_another_look': [for (final s in needsAnotherLook) s.toJson()],
    'channels': [for (final c in channels) c.toJson()],
    'note': note.toJson(),
  };
}

class AnalyticsTotals {
  const AnalyticsTotals({
    this.minutes = 0,
    this.videos = 0,
    this.sessions = 0,
    this.asked = 0,
    this.answered = 0,
    this.answerRate = 0,
  });

  final int minutes;
  final int videos;
  final int sessions;
  final int asked;
  final int answered;

  /// 0.0 - 1.0 on the wire. The screen shows it as a percentage.
  final double answerRate;

  /// Whole percent, clamped, so a gateway that sends 0-100 by mistake or a
  /// stray 1.02 cannot render "102%".
  int get answerPercent => (answerRate.clamp(0.0, 1.0) * 100).round();

  factory AnalyticsTotals.fromJson(Map<String, dynamic> j) => AnalyticsTotals(
    minutes: _int(j['minutes'], 0),
    videos: _int(j['videos'], 0),
    sessions: _int(j['sessions'], 0),
    asked: _int(j['asked'], 0),
    answered: _int(j['answered'], 0),
    answerRate: _double(j['answer_rate'], 0),
  );

  Map<String, dynamic> toJson() => {
    'minutes': minutes,
    'videos': videos,
    'sessions': sessions,
    'asked': asked,
    'answered': answered,
    'answer_rate': answerRate,
  };
}

class AnalyticsDay {
  const AnalyticsDay({
    required this.date,
    this.minutes = 0,
    this.videos = 0,
    this.asked = 0,
    this.answered = 0,
  });

  /// ISO yyyy-MM-dd.
  final String date;
  final int minutes;
  final int videos;
  final int asked;
  final int answered;

  /// Null rather than a throw if the gateway ever sends something odd; the
  /// chart then falls back to the raw string for its axis tick.
  DateTime? get day => DateTime.tryParse(date);

  /// Undefined on a day with no questions, so the caller can skip the bar
  /// instead of drawing a misleading zero.
  double? get answerRate => asked <= 0 ? null : answered / asked;

  factory AnalyticsDay.fromJson(Map<String, dynamic> j) => AnalyticsDay(
    date: j['date'] as String? ?? '',
    minutes: _int(j['minutes'], 0),
    videos: _int(j['videos'], 0),
    asked: _int(j['asked'], 0),
    answered: _int(j['answered'], 0),
  );

  Map<String, dynamic> toJson() => {
    'date': date,
    'minutes': minutes,
    'videos': videos,
    'asked': asked,
    'answered': answered,
  };
}

class Vocabulary {
  const Vocabulary({
    this.totalSaid = 0,
    this.newThisWeek = 0,
    this.said = const [],
    this.emerging = const [],
  });

  final int totalSaid;
  final int newThisWeek;

  /// Most recent first.
  final List<SaidWord> said;

  /// Gilli modelled the word; the kid has not said it back yet.
  final List<EmergingWord> emerging;

  bool get isEmpty => said.isEmpty && emerging.isEmpty && totalSaid == 0;

  factory Vocabulary.fromJson(Map<String, dynamic> j) => Vocabulary(
    totalSaid: _int(j['total_said'], 0),
    newThisWeek: _int(j['new_this_week'], 0),
    said: _list(j['said']).map(SaidWord.fromJson).toList(),
    emerging: _list(j['emerging']).map(EmergingWord.fromJson).toList(),
  );

  Map<String, dynamic> toJson() => {
    'total_said': totalSaid,
    'new_this_week': newThisWeek,
    'said': [for (final w in said) w.toJson()],
    'emerging': [for (final w in emerging) w.toJson()],
  };
}

class SaidWord {
  const SaidWord({required this.word, this.timesSaid = 0, this.firstSaid = ''});

  final String word;
  final int timesSaid;
  final String firstSaid;

  factory SaidWord.fromJson(Map<String, dynamic> j) => SaidWord(
    word: j['word'] as String? ?? '',
    timesSaid: _int(j['times_said'], 0),
    firstSaid: j['first_said'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'word': word,
    'times_said': timesSaid,
    'first_said': firstSaid,
  };
}

class EmergingWord {
  const EmergingWord({required this.word, this.timesHeard = 0});

  final String word;
  final int timesHeard;

  factory EmergingWord.fromJson(Map<String, dynamic> j) => EmergingWord(
    word: j['word'] as String? ?? '',
    timesHeard: _int(j['times_heard'], 0),
  );

  Map<String, dynamic> toJson() => {'word': word, 'times_heard': timesHeard};
}

class ConceptStat {
  const ConceptStat({
    required this.concept,
    this.asked = 0,
    this.understood = 0,
    this.shaky = 0,
    this.lastSeen = '',
  });

  final String concept;
  final int asked;
  final int understood;
  final int shaky;
  final String lastSeen;

  factory ConceptStat.fromJson(Map<String, dynamic> j) => ConceptStat(
    concept: j['concept'] as String? ?? '',
    asked: _int(j['asked'], 0),
    understood: _int(j['understood'], 0),
    shaky: _int(j['shaky'], 0),
    lastSeen: j['last_seen'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'concept': concept,
    'asked': asked,
    'understood': understood,
    'shaky': shaky,
    'last_seen': lastSeen,
  };
}

/// Shaky on two or more separate days: the short list worth a parent's time.
class ShakyConcept {
  const ShakyConcept({
    required this.concept,
    this.timesShaky = 0,
    this.lastSeen = '',
  });

  final String concept;
  final int timesShaky;
  final String lastSeen;

  factory ShakyConcept.fromJson(Map<String, dynamic> j) => ShakyConcept(
    concept: j['concept'] as String? ?? '',
    timesShaky: _int(j['times_shaky'], 0),
    lastSeen: j['last_seen'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'concept': concept,
    'times_shaky': timesShaky,
    'last_seen': lastSeen,
  };
}

class ChannelMinutes {
  const ChannelMinutes({
    required this.channelId,
    required this.title,
    this.minutes = 0,
    this.videos = 0,
  });

  final String channelId;
  final String title;
  final int minutes;
  final int videos;

  factory ChannelMinutes.fromJson(Map<String, dynamic> j) => ChannelMinutes(
    channelId: '${j['channel_id'] ?? ''}',
    title: j['title'] as String? ?? '',
    minutes: _int(j['minutes'], 0),
    videos: _int(j['videos'], 0),
  );

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'title': title,
    'minutes': minutes,
    'videos': videos,
  };
}

/// One or two plain sentences from the Digest agent. `quiet` means there is
/// nothing worth acting on, and the screen renders it small and muted rather
/// than as an alert.
class AnalyticsNote {
  const AnalyticsNote({this.kind = 'quiet', this.text = ''});

  final String kind;
  final String text;

  bool get isQuiet => kind == 'quiet' || text.isEmpty;

  /// Sentence-case heading for the note card.
  String get heading => switch (kind) {
    'praise' => 'Worth knowing',
    'suggestion' => 'One thing to try',
    'watch' => 'Worth a look',
    _ => 'Nothing to act on',
  };

  factory AnalyticsNote.fromJson(Map<String, dynamic> j) => AnalyticsNote(
    kind: j['kind'] as String? ?? 'quiet',
    text: j['text'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'kind': kind, 'text': text};
}

// ------------------------------------------------------------------ helpers

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

List<Map<String, dynamic>> _list(Object? v) => (v as List? ?? const [])
    .whereType<Map>()
    .map((e) => Map<String, dynamic>.from(e))
    .toList();

int _int(Object? v, int fallback) => (v as num?)?.toInt() ?? fallback;

double _double(Object? v, double fallback) =>
    (v as num?)?.toDouble() ?? fallback;
