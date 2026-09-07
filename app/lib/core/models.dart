/// REST objects from docs/PROTOCOL.md plus the age-band rules from SPEC.md 3.
library;

/// The faces a child may wear.
///
/// Here rather than beside the picker because [Kid] needs it: a value that
/// names no face has to fall back to their initial, and the server's default
/// ("gilli") is exactly that — there is no icon for it, so every child who had
/// not chosen rendered as an empty coloured circle.
///
/// The server checks the same names before storing one; this list is what a
/// child is *offered*, not what is trusted.
const kidAvatars = <String>[
  'cat', 'dog', 'duck', 'frog', 'lion', 'monkey',
  'elephant', 'giraffe', 'bird', 'butterfly', 'fish', 'cow',
  'squirrel', 'rocket', 'star', 'sun', 'moon', 'flower',
  'boat', 'train', 'tree', 'mango',
];

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
    this.breakIsFirm = true,
    this.searchEnabled = false,
    this.breakMessages = const [],
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

  /// Whether [avatar] names a face this build can actually draw.
  ///
  /// The server's default is "gilli", for which there is no icon — so every
  /// child who had not picked a face rendered as an empty coloured circle.
  /// Anything unrecognised falls back to their initial rather than to
  /// nothing, which also covers a face added on the server before this app
  /// has shipped the asset.
  bool get hasDrawableAvatar => kidAvatars.contains(avatar);

  /// Total watching allowed per day. 0 = no limit.
  final int dailyMinutes;

  /// Continuous watching before Gilli calls a movement break. 0 = never.
  final int breakAfterMinutes;

  /// How long a movement break lasts. Always at least a minute: a break of
  /// zero is not a break, so the protocol gives it no "off" value.
  final int breakMinutes;

  /// Longest single video offered. 0 = no limit.
  final int maxVideoMinutes;

  /// Whether the break runs its full length. A soft break lets the child come
  /// back as soon as they say they are done: the household decides whether
  /// HeyGilli holds the line or only asks, and it is never the model's call.
  final bool breakIsFirm;

  /// Whether this child may search. Off unless a parent turned it on, and it
  /// only ever filters the videos already approved for them — PROTOCOL is
  /// explicit that no search reaches YouTube.
  final bool searchEnabled;

  /// The lines this parent wrote for break time, in the order they were saved.
  /// Empty is a real answer, not a gap to fill: it means a quiet break.
  final List<BreakMessage> breakMessages;

  bool get speaksUrdu => languages.contains('ur');

  bool get hasDailyLimit => dailyMinutes > 0;
  bool get takesBreaks => breakAfterMinutes > 0;

  Kid copyWith({
    int? dailyMinutes,
    int? breakAfterMinutes,
    int? breakMinutes,
    int? maxVideoMinutes,
    bool? breakIsFirm,
    bool? searchEnabled,
    List<BreakMessage>? breakMessages,
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
    breakIsFirm: breakIsFirm ?? this.breakIsFirm,
    searchEnabled: searchEnabled ?? this.searchEnabled,
    breakMessages: breakMessages ?? this.breakMessages,
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
    breakIsFirm: j['break_is_firm'] as bool? ?? true,
    // Absent on an older gateway, and absent means off: a search box
    // must never appear because a field was missing.
    searchEnabled: j['search_enabled'] as bool? ?? false,
    breakMessages:
        (j['break_messages'] as List?)
            ?.map((m) => BreakMessage.fromJson(m as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
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
    'break_is_firm': breakIsFirm,
    'break_messages': [for (final m in breakMessages) m.toJson()],
  };
}

/// One line a parent wants Gilli to say when watching pauses.
///
/// Parent-authored. A model may propose these in the parent app, but nothing
/// reaches a child until the parent saves it, so every word Gilli says during
/// a break was written or approved by a parent.
/// One question from the server's written bank, and whether this child is
/// asked it.
///
/// The bank is graded by band, so the list a parent sees changes when they
/// correct the child's age — that is the point of it being graded rather than
/// labelled. Everything is on until the parent turns it off.
/// A channel HeyGilli offers a household that has none yet, and the topics a
/// parent picks from to narrow them.
///
/// Suggestions only. Approving is still the parent's own act, and being on
/// this list buys a channel nothing at screening time.
class StarterChannel {
  const StarterChannel({
    required this.channelId,
    required this.title,
    required this.blurb,
    this.topics = const [],
  });

  final String channelId;
  final String title;

  /// Why a parent might want it, in their words.
  final String blurb;
  final List<String> topics;

  factory StarterChannel.fromJson(Map<String, dynamic> j) => StarterChannel(
    channelId: '${j['channel_id'] ?? ''}',
    title: '${j['title'] ?? ''}',
    blurb: '${j['blurb'] ?? ''}',
    topics: [for (final t in (j['topics'] as List? ?? const [])) '$t'],
  );
}

class StarterTopic {
  const StarterTopic({required this.id, required this.label});
  final String id;
  final String label;

  factory StarterTopic.fromJson(Map<String, dynamic> j) =>
      StarterTopic(id: '${j['id'] ?? ''}', label: '${j['label'] ?? ''}');
}

/// What the setup screen needs in one call: the topics to offer and the
/// channels matching what has been picked so far.
class StarterChannels {
  const StarterChannels({this.topics = const [], this.channels = const []});
  final List<StarterTopic> topics;
  final List<StarterChannel> channels;

  factory StarterChannels.fromJson(Map<String, dynamic> j) => StarterChannels(
    topics: [
      for (final t in (j['topics'] as List? ?? const []))
        StarterTopic.fromJson((t as Map).cast<String, dynamic>()),
    ],
    channels: [
      for (final c in (j['channels'] as List? ?? const []))
        StarterChannel.fromJson((c as Map).cast<String, dynamic>()),
    ],
  );
}

class KidPrompt {
  const KidPrompt({
    required this.id,
    required this.label,
    required this.enabled,
    this.type = '',
    this.input = '',
  });

  final String id;

  /// A short line for the parent's list. Never spoken to the child.
  final String label;
  final bool enabled;
  final String type;

  /// "voice", "copy" or "pick" — what the child does to answer. Shown because
  /// "make a sound" and "say a word" are different things to ask of a
  /// four-year-old.
  final String input;

  KidPrompt copyWith({bool? enabled}) => KidPrompt(
    id: id,
    label: label,
    enabled: enabled ?? this.enabled,
    type: type,
    input: input,
  );

  factory KidPrompt.fromJson(Map<String, dynamic> j) => KidPrompt(
    id: '${j['id'] ?? ''}',
    label: '${j['label'] ?? ''}',
    enabled: j['enabled'] != false,
    type: '${j['type'] ?? ''}',
    input: '${j['input'] ?? ''}',
  );
}

class BreakMessage {
  const BreakMessage({this.id = '', this.text = '', this.spoken = ''});

  final String id;
  final String text;
  final String spoken;

  /// What Gilli says out loud. Falls back to the text so a saved line is never
  /// silent for a pre-reader, who sees nothing on screen.
  String get speech => spoken.isNotEmpty ? spoken : text;

  factory BreakMessage.fromJson(Map<String, dynamic> j) => BreakMessage(
    id: '${j['id'] ?? ''}',
    text: j['text'] as String? ?? '',
    spoken: j['spoken'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'spoken': spoken};
}

/// An active break. Nothing plays while one of these exists.
class BreakPeriod {
  const BreakPeriod({
    required this.id,
    required this.kidId,
    this.message,
    this.startedAt = '',
    this.endsAt = '',
    this.secondsLeft = 0,
    this.isFirm = true,
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

  /// Whichever of the parent's lines Gilli says this time. Null is normal and
  /// safe: a parent who wrote nothing gets a quiet break.
  final BreakMessage? message;

  /// The parent's choice. When firm, the timer decides and [acked] only
  /// records the tap; when not, saying "I did it" ends the break.
  final bool isFirm;

  /// The child has said they are done.
  final bool acked;

  BreakPeriod copyWith({int? secondsLeft, bool? acked}) => BreakPeriod(
    id: id,
    kidId: kidId,
    startedAt: startedAt,
    endsAt: endsAt,
    secondsLeft: secondsLeft ?? this.secondsLeft,
    message: message,
    isFirm: isFirm,
    acked: acked ?? this.acked,
  );

  factory BreakPeriod.fromJson(Map<String, dynamic> j) {
    final raw = (j['message'] as Map?)?.cast<String, dynamic>();
    return BreakPeriod(
      id: '${j['id'] ?? ''}',
      kidId: '${j['kid_id'] ?? ''}',
      startedAt: j['started_at'] as String? ?? '',
      endsAt: j['ends_at'] as String? ?? '',
      secondsLeft: (j['seconds_left'] as num?)?.toInt() ?? 0,
      // Absent and null both mean a quiet break: the server drops null fields.
      message: raw == null ? null : BreakMessage.fromJson(raw),
      isFirm: j['is_firm'] as bool? ?? true,
      acked: j['acked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kid_id': kidId,
    'started_at': startedAt,
    'ends_at': endsAt,
    'seconds_left': secondsLeft,
    if (message != null) 'message': message!.toJson(),
    'is_firm': isFirm,
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
  final BreakPeriod? activeBreak;

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
        : BreakPeriod.fromJson(
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

/// One end of a drift: what the review said at a point in time.
class DriftSnapshot {
  const DriftSnapshot({
    this.verdict = ReviewVerdict.unknown,
    this.flags = const [],
    this.reviewedAt = '',
  });

  final ReviewVerdict verdict;
  final List<ReviewFlag> flags;
  final String reviewedAt;

  factory DriftSnapshot.fromJson(Map<String, dynamic> j) => DriftSnapshot(
    verdict: ReviewVerdict.fromWire(j['verdict'] as String?),
    flags: (j['flags'] as List? ?? const [])
        .map((f) => ReviewFlag.fromJson((f as Map).cast<String, dynamic>()))
        .toList(),
    reviewedAt: j['reviewed_at'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'verdict': verdict.wire,
    'flags': [for (final f in flags) f.toJson()],
    'reviewed_at': reviewedAt,
  };
}

/// `POST /channels/drift/check`: a channel is not what it was.
///
/// PROTOCOL "Channel drift": a review is a snapshot, and channels change
/// hands and chase trends years after a parent approved them. Only `worse`
/// drifts are ever shown — a channel that improved is not worth interrupting
/// anyone about — and a drift is information. **Nothing here removes a
/// channel.** Removal stays a thing the parent does.
class ChannelDrift {
  const ChannelDrift({
    required this.channelId,
    required this.title,
    this.was = const DriftSnapshot(),
    this.now = const DriftSnapshot(),
    this.worse = false,
    this.whatChanged = '',
    this.sampleTitles = const [],
  });

  final String channelId;
  final String title;
  final DriftSnapshot was;
  final DriftSnapshot now;

  /// The verdict moved toward concern, or a new flag appeared. Defaults to
  /// false: an unreadable drift is not surfaced as a worry.
  final bool worse;

  /// One sentence naming the difference, not restating the review.
  final String whatChanged;

  /// The new uploads that changed it.
  final List<String> sampleTitles;

  /// Flags on the new review that were not on the old one. This is the part a
  /// parent scans for; the shared ones were already known about.
  List<ReviewFlag> get newFlags {
    final before = {for (final f in was.flags) f.kind};
    return [
      for (final f in now.flags)
        if (!before.contains(f.kind)) f,
    ];
  }

  /// "Looks fine, now Worth a look". Empty when the verdict did not move, in
  /// which case a new flag is what made this a drift.
  String get verdictMove => was.verdict == now.verdict
      ? ''
      : '${was.verdict.label}, now ${now.verdict.label}';

  factory ChannelDrift.fromJson(Map<String, dynamic> j) => ChannelDrift(
    channelId: '${j['channel_id'] ?? ''}',
    title: j['title'] as String? ?? '',
    was: DriftSnapshot.fromJson(
      (j['was'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    now: DriftSnapshot.fromJson(
      (j['now'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    worse: j['worse'] as bool? ?? false,
    whatChanged: j['what_changed'] as String? ?? '',
    sampleTitles: _strings(j['sample_titles']),
  );

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'title': title,
    'was': was.toJson(),
    'now': now.toJson(),
    'worse': worse,
    'what_changed': whatChanged,
    'sample_titles': sampleTitles,
  };
}

/// One answer from `POST /channels/drift/check`.
class DriftCheck {
  const DriftCheck({this.drifted = const [], this.checked = 0});

  final List<ChannelDrift> drifted;

  /// How many channels were actually re-read rather than answered from cache;
  /// re-review is rate-limited to once a week per channel.
  final int checked;

  /// The only ones a parent is shown. Filtered here as well as server-side:
  /// a channel that got better is not an interruption.
  List<ChannelDrift> get worse => [
    for (final d in drifted)
      if (d.worse) d,
  ];

  factory DriftCheck.fromJson(Map<String, dynamic> j) => DriftCheck(
    drifted: (j['drifted'] as List? ?? const [])
        .map((d) => ChannelDrift.fromJson((d as Map).cast<String, dynamic>()))
        .toList(),
    checked: (j['checked'] as num?)?.toInt() ?? 0,
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
  final BreakPeriod activeBreak;
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

/// One channel in a [HistoryInsight], most watched first.
class HistoryChannel {
  const HistoryChannel({
    required this.title,
    required this.videos,
    this.subscribed = false,
  });

  final String title;
  final int videos;

  /// Whether this child is actually subscribed to it. False is the whole
  /// point of the screen: it means something else put the video in front of
  /// them.
  final bool subscribed;

  factory HistoryChannel.fromJson(Map<String, dynamic> j) => HistoryChannel(
    title: j['title'] as String? ?? '',
    videos: (j['videos'] as num?)?.toInt() ?? 0,
    subscribed: j['subscribed'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'videos': videos,
    'subscribed': subscribed,
  };
}

/// `GET /kids/{id}/history`, and 404 when a household never opted in.
///
/// PROTOCOL "Watch history: opt-in, aggregate, discarded": counts and channel
/// names only. There is nowhere in this shape for a video title, because the
/// server discards the file and every title in it after counting, and nothing
/// but channel names is ever sent to a model. If a field for a title ever
/// appears here, that promise has been broken somewhere upstream.
class HistoryInsight {
  const HistoryInsight({
    required this.kidId,
    this.generatedAt = '',
    this.source = 'takeout',
    this.videos = 0,
    this.firstWatched = '',
    this.lastWatched = '',
    this.topChannels = const [],
    this.unsubscribedShare = 0,
    this.byHour = const [],
    this.summary = '',
  });

  final String kidId;
  final String generatedAt;
  final String source;

  /// How many videos were counted. Not which ones: none of them was kept.
  final int videos;
  final String firstWatched;
  final String lastWatched;

  /// At most 20, most watched first.
  final List<HistoryChannel> topChannels;

  /// 0.0-1.0: the share that came from channels this child does not follow.
  /// PROTOCOL calls this the number that matters, and the screen leads on it.
  final double unsubscribedShare;

  /// 24 integers, local to the export. Always exactly 24 by the time it gets
  /// here, so a chart can index it without checking.
  final List<int> byHour;

  /// Two or three sentences about the numbers above and nothing else.
  final String summary;

  /// Whole percent, clamped, so a gateway sending 0-100 by mistake or a stray
  /// 1.02 cannot render "102%".
  int get unsubscribedPercent =>
      (unsubscribedShare.clamp(0.0, 1.0) * 100).round();

  int get subscribedPercent => 100 - unsubscribedPercent;

  bool get hasHours => byHour.any((h) => h > 0);

  /// The hour with the most watching, or null when there is no watching at
  /// all. 0-23.
  int? get busiestHour {
    if (!hasHours) return null;
    var best = 0;
    for (var h = 1; h < byHour.length; h++) {
      if (byHour[h] > byHour[best]) best = h;
    }
    return best;
  }

  factory HistoryInsight.fromJson(Map<String, dynamic> j) {
    // Padded and trimmed to 24 here rather than in every caller: an hour
    // chart with 23 bars would be quietly wrong about when a child watches.
    final hours = <int>[
      for (final h in (j['by_hour'] as List? ?? const []))
        (h as num?)?.toInt() ?? 0,
    ];
    while (hours.length < 24) {
      hours.add(0);
    }
    return HistoryInsight(
      kidId: '${j['kid_id'] ?? ''}',
      generatedAt: j['generated_at'] as String? ?? '',
      source: j['source'] as String? ?? 'takeout',
      videos: (j['videos'] as num?)?.toInt() ?? 0,
      firstWatched: j['first_watched'] as String? ?? '',
      lastWatched: j['last_watched'] as String? ?? '',
      topChannels: (j['top_channels'] as List? ?? const [])
          .map(
            (c) => HistoryChannel.fromJson((c as Map).cast<String, dynamic>()),
          )
          .toList(),
      unsubscribedShare: (j['unsubscribed_share'] as num?)?.toDouble() ?? 0,
      byHour: hours.take(24).toList(growable: false),
      summary: j['summary'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'kid_id': kidId,
    'generated_at': generatedAt,
    'source': source,
    'videos': videos,
    'first_watched': firstWatched,
    'last_watched': lastWatched,
    'top_channels': [for (final c in topChannels) c.toJson()],
    'unsubscribed_share': unsubscribedShare,
    'by_hour': byHour,
    'summary': summary,
  };
}

/// What one household answered about one kind of video.
///
/// PROTOCOL "Household policy": three choices and no more. There is no
/// "block it" here on purpose — the strongest thing a parent can say is
/// `rather_not`, and that routes a video to their inbox rather than hiding it
/// behind their back.
enum PolicyChoice {
  fine('fine'),
  sometimes('sometimes'),
  ratherNot('rather_not');

  const PolicyChoice(this.wire);

  final String wire;

  /// Null for anything unrecognised, including absent. An unanswered question
  /// carries no weight (PROTOCOL), so guessing a choice here would invent an
  /// opinion this household never expressed.
  static PolicyChoice? fromWire(String? s) =>
      PolicyChoice.values.where((c) => c.wire == s).firstOrNull;

  /// The words on the button. Deliberately a parent's words, not a rating:
  /// nobody thinks of their own household as "moderate".
  String get label => switch (this) {
    PolicyChoice.fine => 'Fine',
    PolicyChoice.sometimes => 'Sometimes',
    PolicyChoice.ratherNot => 'Rather not',
  };

  /// One line under the chosen button saying what will actually happen, so a
  /// parent is never guessing what their tap did.
  String get effect => switch (this) {
    PolicyChoice.fine => 'These go straight through, like anything else.',
    PolicyChoice.sometimes =>
      'Gilli reads these more closely and sends the doubtful ones to you.',
    PolicyChoice.ratherNot =>
      'These come to your inbox to decide. Nothing is hidden without you.',
  };
}

/// One answer in a saved [Policy].
class PolicyAnswer {
  const PolicyAnswer({
    required this.id,
    required this.question,
    required this.choice,
    this.weight = 0,
  });

  final String id;

  /// The question as it was asked. Kept with the answer so a saved policy is
  /// readable on its own, even after the Coach stops proposing that question.
  final String question;
  final PolicyChoice choice;

  /// 0.0-1.0: how much this answer actually moved the Curator. The server
  /// owns it; the client never sends a weight it made up.
  final double weight;

  /// Plain words for [weight], or null when the server sent none. A parent
  /// deserves to know which of their answers is doing the work, and a bare
  /// "0.62" tells them nothing.
  String? get weightLabel {
    if (weight <= 0) return null;
    if (weight >= 0.66) return 'Weighs heavily when Gilli screens a video';
    if (weight >= 0.33) return 'Weighs a fair amount when Gilli screens';
    return 'Weighs a little when Gilli screens';
  }

  factory PolicyAnswer.fromJson(Map<String, dynamic> j) => PolicyAnswer(
    id: '${j['id'] ?? ''}',
    question: j['question'] as String? ?? '',
    // Unrecognised choices default to the mildest of the three rather than to
    // a restriction nobody asked for.
    choice: PolicyChoice.fromWire(j['choice'] as String?) ?? PolicyChoice.fine,
    weight: (j['weight'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'question': question,
    'choice': choice.wire,
    'weight': weight,
  };
}

/// `GET /kids/{id}/policy`, `PUT /kids/{id}/policy`.
///
/// PROTOCOL "Household policy": an empty policy is valid and means the Curator
/// falls back to age-band defaults. It is not a setup step anyone must finish.
class Policy {
  const Policy({
    required this.kidId,
    this.updatedAt = '',
    this.answers = const [],
    this.notes = '',
  });

  final String kidId;
  final String updatedAt;
  final List<PolicyAnswer> answers;

  /// The parent's own words, free text. May be empty.
  final String notes;

  bool get isEmpty => answers.isEmpty && notes.trim().isEmpty;

  PolicyAnswer? answerFor(String questionId) =>
      answers.where((a) => a.id == questionId).firstOrNull;

  PolicyChoice? choiceFor(String questionId) => answerFor(questionId)?.choice;

  factory Policy.fromJson(Map<String, dynamic> j) => Policy(
    kidId: '${j['kid_id'] ?? ''}',
    updatedAt: j['updated_at'] as String? ?? '',
    answers: (j['answers'] as List? ?? const [])
        .map((a) => PolicyAnswer.fromJson((a as Map).cast<String, dynamic>()))
        .toList(),
    notes: j['notes'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'kid_id': kidId,
    'updated_at': updatedAt,
    'answers': [for (final a in answers) a.toJson()],
    'notes': notes,
  };
}

/// One question the Coach thinks is worth asking *this* household.
///
/// PROTOCOL: `why` says which channels prompted it. The screen always shows
/// it, so a parent can see the question came from their own child's channels
/// rather than from a list someone else wrote.
/// The questions to put to a parent, and what they were drawn from.
///
/// [basedOn] is the channels this child actually has. Empty means there was
/// nothing to draw on and these are the questions every family is asked — the
/// screen has to say which it is, because a page that claims a question came
/// from your own child's channels when it did not is a small lie that costs
/// trust in everything else on it.
class PolicyQuestions {
  const PolicyQuestions({this.questions = const [], this.basedOn = const []});

  final List<PolicyQuestion> questions;
  final List<String> basedOn;

  bool get isPersonal => basedOn.isNotEmpty;

  factory PolicyQuestions.fromJson(Map<String, dynamic> j) => PolicyQuestions(
    questions: [
      for (final q in (j['questions'] as List? ?? const []))
        PolicyQuestion.fromJson((q as Map).cast<String, dynamic>()),
    ],
    basedOn: _strings(j['based_on']),
  );
}

class PolicyQuestion {
  const PolicyQuestion({
    required this.id,
    required this.question,
    this.why = '',
    this.options = PolicyChoice.values,
  });

  final String id;
  final String question;
  final String why;

  /// The choices this question offers. All three unless the server narrows
  /// them; an empty or unreadable list falls back to all three rather than to
  /// a question with no way to answer it.
  final List<PolicyChoice> options;

  factory PolicyQuestion.fromJson(Map<String, dynamic> j) {
    final options = _strings(
      j['options'],
    ).map(PolicyChoice.fromWire).nonNulls.toList(growable: false);
    return PolicyQuestion(
      id: '${j['id'] ?? ''}',
      question: j['question'] as String? ?? '',
      why: j['why'] as String? ?? '',
      options: options.isEmpty ? PolicyChoice.values : options,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'question': question,
    'why': why,
    'options': [for (final o in options) o.wire],
  };
}

/// What kind of thing the parent is being asked about.
///
/// Unknown to this build means a gateway newer than the app. Such an entry is
/// still shown — its whole point is to reach the parent — but with no decision
/// buttons, because this build does not know what deciding would mean.
enum PromptKind {
  video,
  channelDrift,
  unknown;

  static PromptKind fromWire(String? s) => switch (s) {
    'video' || null => PromptKind.video,
    'channel_drift' => PromptKind.channelDrift,
    _ => PromptKind.unknown,
  };
}

class ParentPrompt {
  const ParentPrompt({
    required this.id,
    required this.kidId,
    this.kind = PromptKind.video,
    this.video,
    this.drift,
    this.title = '',
    this.channelTitle = '',
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String kidId;

  /// The channel this came from, named. The video carries a channel id and
  /// nothing a person can read, and the inbox groups by this: several
  /// borderline uploads in a row are usually one channel with one answer.
  final String channelTitle;

  /// Which of the two things this is. PROTOCOL sends `video` and `drift` both,
  /// one of them null, so this is read rather than inferred from which key
  /// happens to be present.
  final PromptKind kind;

  /// The video this is about, when it is about one.
  ///
  /// Null for an entry that is not: PROTOCOL says a channel drift also raises
  /// an inbox entry, and a drift has no video in it. The client refuses to
  /// throw away such an entry — its whole point is to reach the parent — so
  /// the video is optional here and the card renders without a thumbnail.
  final Video? video;

  /// The drift this entry is about, on a `channel_drift` entry.
  final ChannelDrift? drift;

  final String reason;
  final String createdAt;

  /// A label for the thing being decided, whatever kind of entry it is.
  String get subject =>
      video?.title ?? drift?.title ?? (title.isNotEmpty ? title : 'Something');

  /// Whether approve/hide mean anything here. They do not for a drift: a
  /// drift is information, and the only action is one the parent takes on the
  /// channel itself (PROTOCOL "Channel drift").
  bool get isDecidable => kind == PromptKind.video;

  /// Set when the entry names something that is not a video, e.g. the channel
  /// a drift is about.
  final String title;

  factory ParentPrompt.fromJson(Map<String, dynamic> j) => ParentPrompt(
    id: '${j['id']}',
    kidId: '${j['kid_id']}',
    kind: PromptKind.fromWire(j['kind'] as String?),
    drift: j['drift'] == null
        ? null
        : ChannelDrift.fromJson((j['drift'] as Map).cast<String, dynamic>()),
    video: j['video'] == null
        ? null
        : Video.fromJson((j['video'] as Map).cast<String, dynamic>()),
    title: j['title'] as String? ?? '${j['channel_title'] ?? ''}',
    channelTitle: '${j['channel_title'] ?? ''}',
    reason: j['reason'] as String? ?? '',
    createdAt: j['created_at'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kid_id': kidId,
    'kind': switch (kind) {
      PromptKind.video => 'video',
      PromptKind.channelDrift => 'channel_drift',
      PromptKind.unknown => 'unknown',
    },
    if (video != null) 'video': video!.toJson(),
    if (drift != null) 'drift': drift!.toJson(),
    if (title.isNotEmpty) 'title': title,
    'reason': reason,
    'created_at': createdAt,
  };
}

List<String> _strings(Object? v) =>
    (v as List? ?? const []).map((e) => '$e').toList();
