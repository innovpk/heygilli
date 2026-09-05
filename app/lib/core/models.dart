/// REST objects from docs/PROTOCOL.md plus the age-band rules from SPEC.md 3.
library;

/// The three bands drive everything downstream: question types, whether text
/// is shown, listening window, buddy tone, digest shape.
enum AgeBand {
  b4to6('4_6'),
  b7to8('7_8'),
  b9to11('9_11');

  const AgeBand(this.wire);

  /// Value on the wire, e.g. "4_6".
  final String wire;

  static AgeBand fromWire(String? s) => switch (s) {
    '7_8' => AgeBand.b7to8,
    '9_11' => AgeBand.b9to11,
    _ => AgeBand.b4to6,
  };

  /// SPEC 3: 4 to 6, 7 to 8, 9 to 11. Ages outside the range clamp to the
  /// nearest band so an odd parent input never crashes the kid path.
  static AgeBand forAge(int age) {
    if (age <= 6) return AgeBand.b4to6;
    if (age <= 8) return AgeBand.b7to8;
    return AgeBand.b9to11;
  }

  /// SPEC 5.1: pre-readers see no text at all during a question.
  bool get showsQuestionText => this != AgeBand.b4to6;

  /// SPEC 6.2: question text is large for 7 to 8, normal for 9 to 11.
  double get questionTextSize => switch (this) {
    AgeBand.b4to6 => 0,
    AgeBand.b7to8 => 34,
    AgeBand.b9to11 => 28,
  };

  /// SPEC 6.3: home is pictures only for pre-readers.
  bool get showsVideoTitles => this != AgeBand.b4to6;

  /// SPEC 9.2: the buddy starts listening on its own for pre-readers so a kid
  /// who just talks at the screen is still heard.
  bool get autoListens => this == AgeBand.b4to6;

  /// Listening window fallback when the server omits listen_ms.
  int get defaultListenMs => this == AgeBand.b4to6 ? 5000 : 8000;

  String get label => switch (this) {
    AgeBand.b4to6 => '4 to 6',
    AgeBand.b7to8 => '7 to 8',
    AgeBand.b9to11 => '9 to 11',
  };
}

class Kid {
  const Kid({
    required this.id,
    required this.nickname,
    required this.age,
    required this.band,
    required this.languages,
    this.avatar = '',
  });

  final String id;
  final String nickname;
  final int age;
  final AgeBand band;
  final List<String> languages;
  final String avatar;

  bool get speaksUrdu => languages.contains('ur');

  factory Kid.fromJson(Map<String, dynamic> j) => Kid(
    id: '${j['id']}',
    nickname: j['nickname'] as String? ?? '',
    age: (j['age'] as num?)?.toInt() ?? 4,
    band: j['age_band'] != null
        ? AgeBand.fromWire(j['age_band'] as String)
        : AgeBand.forAge((j['age'] as num?)?.toInt() ?? 4),
    languages: (j['languages'] as List?)?.cast<String>() ?? const ['en'],
    avatar: j['avatar'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nickname': nickname,
    'age': age,
    'age_band': band.wire,
    'languages': languages,
    'avatar': avatar,
  };
}

class Channel {
  const Channel({
    required this.id,
    required this.title,
    required this.thumbUrl,
    required this.approved,
  });

  final String id;
  final String title;
  final String thumbUrl;
  final bool approved;

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
    id: '${j['id']}',
    title: j['title'] as String? ?? '',
    thumbUrl: j['thumb_url'] as String? ?? '',
    approved: j['approved'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'thumb_url': thumbUrl,
    'approved': approved,
  };
}

class Video {
  const Video({
    required this.id,
    required this.channelId,
    required this.title,
    required this.durationS,
    this.thumbUrl = '',
    this.ageOk = true,
    this.planReady = false,
  });

  final String id;
  final String channelId;
  final String title;
  final int durationS;
  final String thumbUrl;
  final bool ageOk;
  final bool planReady;

  /// YouTube's public thumbnail endpoint; used when the server sends no thumb.
  String get thumb => thumbUrl.isNotEmpty
      ? thumbUrl
      : 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  factory Video.fromJson(Map<String, dynamic> j) => Video(
    id: '${j['id']}',
    channelId: '${j['channel_id'] ?? ''}',
    title: j['title'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
    thumbUrl: j['thumb_url'] as String? ?? '',
    ageOk: j['age_ok'] as bool? ?? true,
    planReady: j['plan_ready'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'channel_id': channelId,
    'title': title,
    'duration_s': durationS,
    'thumb_url': thumb,
    'age_ok': ageOk,
    'plan_ready': planReady,
  };
}

class HomeRow {
  const HomeRow({required this.title, required this.videos});

  final String title;
  final List<Video> videos;

  factory HomeRow.fromJson(Map<String, dynamic> j) => HomeRow(
    title: j['title'] as String? ?? '',
    videos: (j['videos'] as List? ?? const [])
        .map((v) => Video.fromJson(v as Map<String, dynamic>))
        .toList(),
  );
}

class SessionStart {
  const SessionStart({
    required this.sessionId,
    required this.video,
    required this.planReady,
  });

  final String sessionId;
  final Video video;
  final bool planReady;

  factory SessionStart.fromJson(Map<String, dynamic> j) => SessionStart(
    sessionId: '${j['session_id']}',
    video: Video.fromJson(j['video'] as Map<String, dynamic>),
    planReady: j['plan_ready'] as bool? ?? false,
  );
}

/// Two shapes (SPEC 6.5): "prereader" is a vocabulary log, "older" is a
/// comprehension report. Fields not used by a shape are empty lists.
class Digest {
  const Digest({
    required this.kidId,
    required this.date,
    required this.minutes,
    required this.videos,
    required this.asked,
    required this.answered,
    required this.understood,
    required this.shaky,
    required this.wordsSaid,
    required this.wordsHeard,
    required this.dinnerPrompt,
    required this.kind,
  });

  final String kidId;
  final String date;
  final int minutes;
  final int videos;
  final int asked;
  final int answered;
  final List<String> understood;
  final List<String> shaky;
  final List<String> wordsSaid;
  final List<String> wordsHeard;
  final String dinnerPrompt;
  final String kind;

  bool get isPreReader => kind == 'prereader';

  factory Digest.fromJson(Map<String, dynamic> j) => Digest(
    kidId: '${j['kid_id']}',
    date: j['date'] as String? ?? '',
    minutes: (j['minutes'] as num?)?.toInt() ?? 0,
    videos: (j['videos'] as num?)?.toInt() ?? 0,
    asked: (j['asked'] as num?)?.toInt() ?? 0,
    answered: (j['answered'] as num?)?.toInt() ?? 0,
    understood: _strings(j['understood']),
    shaky: _strings(j['shaky']),
    wordsSaid: _strings(j['words_said']),
    wordsHeard: _strings(j['words_heard']),
    dinnerPrompt: j['dinner_prompt'] as String? ?? '',
    kind: j['kind'] as String? ?? 'older',
  );

  Map<String, dynamic> toJson() => {
    'kid_id': kidId,
    'date': date,
    'minutes': minutes,
    'videos': videos,
    'asked': asked,
    'answered': answered,
    'understood': understood,
    'shaky': shaky,
    'words_said': wordsSaid,
    'words_heard': wordsHeard,
    'dinner_prompt': dinnerPrompt,
    'kind': kind,
  };
}

class ParentPrompt {
  const ParentPrompt({
    required this.id,
    required this.kidId,
    required this.video,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String kidId;
  final Video video;
  final String reason;
  final String createdAt;

  factory ParentPrompt.fromJson(Map<String, dynamic> j) => ParentPrompt(
    id: '${j['id']}',
    kidId: '${j['kid_id']}',
    video: Video.fromJson(j['video'] as Map<String, dynamic>),
    reason: j['reason'] as String? ?? '',
    createdAt: j['created_at'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kid_id': kidId,
    'video': video.toJson(),
    'reason': reason,
    'created_at': createdAt,
  };
}

List<String> _strings(Object? v) =>
    (v as List? ?? const []).map((e) => '$e').toList();
