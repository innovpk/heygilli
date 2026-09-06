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
    this.dailyMinutes = defaultDailyMinutes,
    this.breakAfterMinutes = defaultBreakAfterMinutes,
    this.breakMinutes = defaultBreakMinutes,
    this.maxVideoMinutes = defaultMaxVideoMinutes,
  });

  /// PROTOCOL "Time limits and movement breaks" defaults. A gateway that has
  /// not been upgraded yet omits the four fields, and these are what it means.
  static const defaultDailyMinutes = 60;
  static const defaultBreakAfterMinutes = 25;
  static const defaultBreakMinutes = 5;
  static const defaultMaxVideoMinutes = 0;

  final String id;
  final String nickname;
  final int age;
  final AgeBand band;
  final List<String> languages;
  final String avatar;

  /// Total watching allowed per day. 0 = no limit.
  final int dailyMinutes;

  /// Continuous watching before Gilli calls a movement break. 0 = never.
  final int breakAfterMinutes;

  /// How long a movement break lasts. Always at least a minute: a break of
  /// zero is not a break, so the protocol gives it no "off" value.
  final int breakMinutes;

  /// Longest single video offered. 0 = no limit.
  final int maxVideoMinutes;

  bool get speaksUrdu => languages.contains('ur');

  bool get hasDailyLimit => dailyMinutes > 0;
  bool get takesBreaks => breakAfterMinutes > 0;

  Kid copyWith({
    int? dailyMinutes,
    int? breakAfterMinutes,
    int? breakMinutes,
    int? maxVideoMinutes,
  }) => Kid(
    id: id,
    nickname: nickname,
    age: age,
    band: band,
    languages: languages,
    avatar: avatar,
    dailyMinutes: dailyMinutes ?? this.dailyMinutes,
    breakAfterMinutes: breakAfterMinutes ?? this.breakAfterMinutes,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    maxVideoMinutes: maxVideoMinutes ?? this.maxVideoMinutes,
  );

  factory Kid.fromJson(Map<String, dynamic> j) => Kid(
    id: '${j['id']}',
    nickname: j['nickname'] as String? ?? '',
    age: (j['age'] as num?)?.toInt() ?? 4,
    band: j['age_band'] != null
        ? AgeBand.fromWire(j['age_band'] as String)
        : AgeBand.forAge((j['age'] as num?)?.toInt() ?? 4),
    languages: (j['languages'] as List?)?.cast<String>() ?? const ['en'],
    avatar: j['avatar'] as String? ?? '',
    // A missing limit is the protocol default, never "unlimited": a client
    // that guessed 0 here would quietly switch a household's limits off.
    dailyMinutes: (j['daily_minutes'] as num?)?.toInt() ?? defaultDailyMinutes,
    breakAfterMinutes:
        (j['break_after_minutes'] as num?)?.toInt() ?? defaultBreakAfterMinutes,
    breakMinutes: (j['break_minutes'] as num?)?.toInt() ?? defaultBreakMinutes,
    maxVideoMinutes:
        (j['max_video_minutes'] as num?)?.toInt() ?? defaultMaxVideoMinutes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nickname': nickname,
    'age': age,
    'age_band': band.wire,
    'languages': languages,
    'avatar': avatar,
    'daily_minutes': dailyMinutes,
    'break_after_minutes': breakAfterMinutes,
    'break_minutes': breakMinutes,
    'max_video_minutes': maxVideoMinutes,
  };
}

/// One thing to do during a movement break.
///
/// PROTOCOL: built from what the child just watched, doable indoors on the
/// spot, 1 to 3 minutes. [spoken] is what Gilli says, and is the whole task
/// for band 4_6, which sees no text at all.
class BreakTask {
  const BreakTask({
    this.title = '',
    this.steps = const [],
    this.seconds = 0,
    this.spoken = '',
  });

  final String title;
  final List<String> steps;
  final int seconds;
  final String spoken;

  /// What Gilli says out loud. Falls back to the title so a task with no
  /// `spoken` is still never silent for a pre-reader.
  String get speech => spoken.isNotEmpty ? spoken : title;

  factory BreakTask.fromJson(Map<String, dynamic> j) => BreakTask(
    title: j['title'] as String? ?? '',
    steps: _strings(j['steps']),
    seconds: (j['seconds'] as num?)?.toInt() ?? 0,
    spoken: j['spoken'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'steps': steps,
    'seconds': seconds,
    'spoken': spoken,
  };
}

/// An active movement break. Nothing plays while one of these exists.
class MovementBreak {
  const MovementBreak({
    required this.id,
    required this.kidId,
    required this.task,
    this.startedAt = '',
    this.endsAt = '',
    this.secondsLeft = 0,
    this.sourceTitles = const [],
    this.acked = false,
  });

  final String id;
  final String kidId;
  final String startedAt;
  final String endsAt;

  /// Seconds still to run when the server sent this. The client counts down
  /// from here rather than from [endsAt], so a device clock that is minutes
  /// off does not end a break early or hold a child in one.
  final int secondsLeft;
  final BreakTask task;

  /// The videos the task was built from. Shown to the parent, never the kid.
  final List<String> sourceTitles;

  /// The child has said they did it. Recorded only: it never shortens the
  /// break (PROTOCOL).
  final bool acked;

  MovementBreak copyWith({int? secondsLeft, bool? acked}) => MovementBreak(
    id: id,
    kidId: kidId,
    startedAt: startedAt,
    endsAt: endsAt,
    secondsLeft: secondsLeft ?? this.secondsLeft,
    task: task,
    sourceTitles: sourceTitles,
    acked: acked ?? this.acked,
  );

  factory MovementBreak.fromJson(Map<String, dynamic> j) => MovementBreak(
    id: '${j['id'] ?? ''}',
    kidId: '${j['kid_id'] ?? ''}',
    startedAt: j['started_at'] as String? ?? '',
    endsAt: j['ends_at'] as String? ?? '',
    secondsLeft: (j['seconds_left'] as num?)?.toInt() ?? 0,
    task: BreakTask.fromJson(
      (j['task'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    sourceTitles: _strings(j['source_titles']),
    acked: j['acked'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kid_id': kidId,
    'started_at': startedAt,
    'ends_at': endsAt,
    'seconds_left': secondsLeft,
    'task': task.toJson(),
    'source_titles': sourceTitles,
    'acked': acked,
  };
}

/// Why a child cannot watch right now. `null` on the wire means they can.
enum BlockedReason {
  dailyLimit('daily_limit'),
  movementBreak('break');

  const BlockedReason(this.wire);

  final String wire;

  /// Unknown or absent reasons are not invented: the caller sees null and
  /// falls back to [WatchState.watchingAllowed].
  static BlockedReason? fromWire(String? s) =>
      BlockedReason.values.where((r) => r.wire == s).firstOrNull;
}

/// `GET /kids/{id}/state`: what the client checks before offering anything.
class WatchState {
  const WatchState({
    this.minutesToday = 0,
    this.minutesLeftToday = 0,
    this.continuousMinutes = 0,
    this.watchingAllowed = true,
    this.blockedReason,
    this.activeBreak,
  });

  final int minutesToday;
  final int minutesLeftToday;

  /// Since the last break, or a 10-minute gap.
  final int continuousMinutes;
  final bool watchingAllowed;
  final BlockedReason? blockedReason;
  final MovementBreak? activeBreak;

  /// A break is only "on" when the server sent one to run. A blocked_reason
  /// of "break" with no break attached is treated as no break rather than as
  /// an empty screen the child cannot leave.
  bool get isOnBreak => !watchingAllowed && activeBreak != null;

  bool get isDayDone =>
      !watchingAllowed && blockedReason == BlockedReason.dailyLimit;

  factory WatchState.fromJson(Map<String, dynamic> j) => WatchState(
    minutesToday: (j['minutes_today'] as num?)?.toInt() ?? 0,
    minutesLeftToday: (j['minutes_left_today'] as num?)?.toInt() ?? 0,
    continuousMinutes: (j['continuous_minutes'] as num?)?.toInt() ?? 0,
    // Absent means allowed: a gateway that has not shipped limits yet must
    // not lock every child out.
    watchingAllowed: j['watching_allowed'] as bool? ?? true,
    blockedReason: BlockedReason.fromWire(j['blocked_reason'] as String?),
    activeBreak: j['active_break'] == null
        ? null
        : MovementBreak.fromJson(
            (j['active_break'] as Map).cast<String, dynamic>(),
          ),
  );

  Map<String, dynamic> toJson() => {
    'minutes_today': minutesToday,
    'minutes_left_today': minutesLeftToday,
    'continuous_minutes': continuousMinutes,
    'watching_allowed': watchingAllowed,
    'blocked_reason': blockedReason?.wire,
    'active_break': activeBreak?.toJson(),
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

/// What `POST /auth/dev` and `POST /auth/google` hand back.
///
/// PROTOCOL "Google sign-in and subscription import": the gateway exchanges the
/// server auth code and keeps the refresh token. Nothing here is a refresh
/// token, and the device never asks for one.
class Session {
  const Session({
    required this.token,
    required this.householdId,
    this.email = '',
    this.youtubeLinked = false,
  });

  final String token;
  final String householdId;
  final String email;
  final bool youtubeLinked;

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    token: j['token'] as String? ?? '',
    householdId: '${j['household_id'] ?? ''}',
    email: j['email'] as String? ?? '',
    youtubeLinked: j['youtube_linked'] as bool? ?? false,
  );
}

/// `GET /me/youtube`. `linked: false` is a normal state, not an error.
class YouTubeStatus {
  const YouTubeStatus({required this.linked, this.email = ''});

  final bool linked;
  final String email;

  factory YouTubeStatus.fromJson(Map<String, dynamic> j) => YouTubeStatus(
    linked: j['linked'] as bool? ?? false,
    email: j['email'] as String? ?? '',
  );
}

/// One channel the signed-in parent follows on YouTube, with the kids it has
/// already been approved for so the import list can show them as done.
class Subscription {
  const Subscription({
    required this.channelId,
    required this.title,
    this.thumbUrl = '',
    this.approvedFor = const [],
  });

  final String channelId;
  final String title;
  final String thumbUrl;
  final List<String> approvedFor;

  /// Already approved for this kid: shown as such and never sent again.
  bool isApprovedFor(String kidId) => approvedFor.contains(kidId);

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
    channelId: '${j['channel_id'] ?? ''}',
    title: j['title'] as String? ?? '',
    thumbUrl: j['thumb_url'] as String? ?? '',
    approvedFor: _strings(j['approved_for']),
  );

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'title': title,
    'thumb_url': thumbUrl,
    'approved_for': approvedFor,
  };
}

/// `GET /me/youtube/subscriptions`.
class SubscriptionList {
  const SubscriptionList({required this.linked, this.subscriptions = const []});

  final bool linked;
  final List<Subscription> subscriptions;

  factory SubscriptionList.fromJson(Map<String, dynamic> j) => SubscriptionList(
    linked: j['linked'] as bool? ?? false,
    subscriptions: (j['subscriptions'] as List? ?? const [])
        .map((s) => Subscription.fromJson(s as Map<String, dynamic>))
        .toList(),
  );
}

/// `POST /kids/{kid_id}/channels/import`.
class ImportResult {
  const ImportResult({this.added = const [], this.already = const []});

  final List<Channel> added;

  /// Channel ids that were already approved for this kid.
  final List<String> already;

  factory ImportResult.fromJson(Map<String, dynamic> j) => ImportResult(
    added: (j['added'] as List? ?? const [])
        .map((c) => Channel.fromJson(c as Map<String, dynamic>))
        .toList(),
    // The gateway may send bare ids or whole channel objects; accept both.
    already: (j['already'] as List? ?? const [])
        .map((e) => e is Map ? '${e['channel_id'] ?? e['id'] ?? ''}' : '$e')
        .toList(),
  );
}

/// One channel row inside a Takeout `subscriptions.csv`
/// (`Channel ID,Channel URL,Channel title`).
class TakeoutChannel {
  const TakeoutChannel({
    required this.channelId,
    required this.title,
    this.url = '',
  });

  final String channelId;
  final String title;
  final String url;

  factory TakeoutChannel.fromJson(Map<String, dynamic> j) => TakeoutChannel(
    channelId: '${j['channel_id'] ?? ''}',
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'title': title,
    'url': url,
  };
}

/// One YouTube Kids profile found in the export, or the parent's own list.
///
/// The profile name is the folder name under `children/`; the parent block
/// carries no name, so [name] is empty there.
class TakeoutProfile {
  const TakeoutProfile({
    this.name = '',
    required this.channelCount,
    this.channels = const [],
  });

  final String name;
  final int channelCount;
  final List<TakeoutChannel> channels;

  List<String> get channelIds => [for (final c in channels) c.channelId];

  factory TakeoutProfile.fromJson(Map<String, dynamic> j) {
    final channels = (j['channels'] as List? ?? const [])
        .map((c) => TakeoutChannel.fromJson(c as Map<String, dynamic>))
        .toList();
    return TakeoutProfile(
      name: j['name'] as String? ?? '',
      // The count is the server's; fall back to what we can actually see so a
      // card never says "0 channels" over a list of them.
      channelCount: (j['channel_count'] as num?)?.toInt() ?? channels.length,
      channels: channels,
    );
  }

  Map<String, dynamic> toJson() => {
    if (name.isNotEmpty) 'name': name,
    'channel_count': channelCount,
    'channels': [for (final c in channels) c.toJson()],
  };
}

/// `POST /import/takeout`.
///
/// PROTOCOL: only the subscription CSVs are read. Watch history and search
/// history are ignored and never uploaded, stored or sent to a model, so
/// nothing in this shape can carry them.
class TakeoutPreview {
  const TakeoutPreview({this.profiles = const [], this.parent});

  /// One per YouTube Kids profile found under `children/`.
  final List<TakeoutProfile> profiles;

  /// The signed-in account's own subscriptions, or null when the export has
  /// no `subscriptions/` folder.
  final TakeoutProfile? parent;

  bool get isEmpty => profiles.isEmpty && parent == null;

  factory TakeoutPreview.fromJson(Map<String, dynamic> j) => TakeoutPreview(
    profiles: (j['profiles'] as List? ?? const [])
        .map((p) => TakeoutProfile.fromJson(p as Map<String, dynamic>))
        .toList(),
    parent: j['parent'] == null
        ? null
        : TakeoutProfile.fromJson(j['parent'] as Map<String, dynamic>),
  );
}

/// What an AI review says about a channel.
///
/// PROTOCOL: the review is advice, not a verdict on a creator, and `unknown`
/// means there was too little recent material to read, never a warning. Both
/// rules are carried in the wording below, not just in the docs.
enum ReviewVerdict {
  good('good'),
  mixed('mixed'),
  concern('concern'),
  unknown('unknown');

  const ReviewVerdict(this.wire);

  final String wire;

  /// Anything unrecognised is `unknown`: never guess a verdict.
  static ReviewVerdict fromWire(String? s) => switch (s) {
    'good' => ReviewVerdict.good,
    'mixed' => ReviewVerdict.mixed,
    'concern' => ReviewVerdict.concern,
    _ => ReviewVerdict.unknown,
  };

  /// Chip text. Every chip is labelled, so colour is never the only signal.
  String get label => switch (this) {
    ReviewVerdict.good => 'Looks fine',
    ReviewVerdict.mixed => 'Mixed',
    ReviewVerdict.concern => 'Worth a look',
    ReviewVerdict.unknown => 'Not enough yet',
  };

  /// One line under the chip on the full review. Hedged on purpose: this is
  /// what recent uploads suggest, not a ruling.
  String get blurb => switch (this) {
    ReviewVerdict.good =>
      'Recent uploads look like what you would expect from this channel.',
    ReviewVerdict.mixed =>
      'Most of it is fine, but some recent uploads are worth your eye.',
    ReviewVerdict.concern =>
      'Something in the recent uploads is worth reading before you decide.',
    ReviewVerdict.unknown =>
      'Not enough recent uploads to judge. This is not a warning.',
  };

  /// Rows the "Needs a look" filter keeps. `unknown` is deliberately not one:
  /// too little to read is not the same as something to worry about.
  bool get needsALook =>
      this == ReviewVerdict.concern || this == ReviewVerdict.mixed;
}

/// One thing the review noticed, with the reviewer's own note about it.
class ReviewFlag {
  const ReviewFlag({required this.kind, this.note = ''});

  final String kind;
  final String note;

  /// Plain English for the wire kind. An unknown kind is shown as-is rather
  /// than dropped, so a new server-side kind still reaches the parent.
  String get label => switch (kind) {
    'ads_or_merch' => 'Ads or merch',
    'consumerism' => 'Buy-me pressure',
    'scary' => 'Scary moments',
    'mature_language' => 'Grown-up language',
    'low_quality' => 'Thin content',
    'off_topic' => 'Off topic',
    'not_for_kids' => 'Not made for kids',
    'unclear' => 'Hard to tell',
    _ => kind.replaceAll('_', ' '),
  };

  factory ReviewFlag.fromJson(Map<String, dynamic> j) => ReviewFlag(
    kind: j['kind'] as String? ?? 'unclear',
    note: j['note'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'kind': kind, 'note': note};
}

/// `POST /channels/reviews` / `GET /channels/{id}/review`.
class ChannelReview {
  const ChannelReview({
    required this.channelId,
    required this.title,
    this.thumbUrl = '',
    this.verdict = ReviewVerdict.unknown,
    this.summary = '',
    this.flags = const [],
    this.goodFor = const [],
    this.sampleTitles = const [],
    this.reviewedAt = '',
    this.model = '',
  });

  final String channelId;
  final String title;
  final String thumbUrl;
  final ReviewVerdict verdict;
  final String summary;
  final List<ReviewFlag> flags;

  /// Age bands on the wire ("4_6"). Kept as wire strings so an unknown band
  /// is never silently turned into 4 to 6.
  final List<String> goodFor;

  /// The uploads the review was actually based on. Shown to the parent so the
  /// advice can be checked rather than trusted.
  final List<String> sampleTitles;
  final String reviewedAt;
  final String model;

  bool suits(AgeBand band) => goodFor.contains(band.wire);

  /// "4 to 6, 7 to 8". Empty when the review named no band.
  String get goodForLabel => AgeBand.values
      .where((b) => goodFor.contains(b.wire))
      .map((b) => b.label)
      .join(', ');

  factory ChannelReview.fromJson(Map<String, dynamic> j) => ChannelReview(
    channelId: '${j['channel_id'] ?? ''}',
    title: j['title'] as String? ?? '',
    thumbUrl: j['thumb_url'] as String? ?? '',
    verdict: ReviewVerdict.fromWire(j['verdict'] as String?),
    summary: j['summary'] as String? ?? '',
    flags: (j['flags'] as List? ?? const [])
        .map((f) => ReviewFlag.fromJson(f as Map<String, dynamic>))
        .toList(),
    goodFor: _strings(j['good_for']),
    sampleTitles: _strings(j['sample_titles']),
    reviewedAt: j['reviewed_at'] as String? ?? '',
    model: j['model'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'title': title,
    'thumb_url': thumbUrl,
    'verdict': verdict.wire,
    'summary': summary,
    'flags': [for (final f in flags) f.toJson()],
    'good_for': goodFor,
    'sample_titles': sampleTitles,
    'reviewed_at': reviewedAt,
    'model': model,
  };
}

/// One answer from `POST /channels/reviews`: whatever was cached, plus the
/// ids still being reviewed. The client polls until `pending` is empty.
class ChannelReviewBatch {
  const ChannelReviewBatch({this.reviews = const [], this.pending = const []});

  final List<ChannelReview> reviews;
  final List<String> pending;

  factory ChannelReviewBatch.fromJson(Map<String, dynamic> j) =>
      ChannelReviewBatch(
        reviews: (j['reviews'] as List? ?? const [])
            .map((r) => ChannelReview.fromJson(r as Map<String, dynamic>))
            .toList(),
        // Bare ids per PROTOCOL, but accept objects the way ImportResult does.
        pending: (j['pending'] as List? ?? const [])
            .map((e) => e is Map ? '${e['channel_id'] ?? e['id'] ?? ''}' : '$e')
            .toList(),
      );
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

/// What `POST /sessions` answers with.
///
/// PROTOCOL: no video plays during a break, so the endpoint can answer 409
/// with the break that is running. That is a normal state of the product, not
/// a failure, so it is a value the caller switches on rather than an
/// exception with a status code in it that some screen would print at a child.
sealed class SessionStartResult {
  const SessionStartResult();
}

class SessionStarted extends SessionStartResult {
  const SessionStarted(this.session);
  final SessionStart session;
}

class SessionBlockedByBreak extends SessionStartResult {
  const SessionBlockedByBreak(this.activeBreak);
  final MovementBreak activeBreak;
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
