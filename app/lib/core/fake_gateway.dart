import 'dart:async';
import 'dart:typed_data';

import 'analytics.dart';
import 'demo_catalogue.dart';
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

  @override
  void forgetToken() => _signedIn = false;

  // ---------------------------------------------------------------- canned data

  /// Empty on purpose. Google has no API for a parent's children (Family Link
  /// exposes none), so a kid profile is always something the parent creates
  /// here. Shipping invented children would put names on screen that belong to
  /// nobody, so demo mode grows its history around whichever kid you add.
  final _kids = <Kid>[];

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

  final _channels = <String, List<Channel>>{};

  /// Canned "channels this parent already follows" for the import screen.
  ///
  /// Deliberately a real parent's list, not a curated kids' shelf: two are
  /// already approved for both kids, and a few at the end are the parent's own
  /// viewing. PROTOCOL is explicit that a parent's subscriptions are a starting
  /// list to tick through, never an auto-approved catalogue.
  ///
  /// Thumbnails are left empty for the invented channels so the demo renders
  /// identically offline; the two real ones keep their real thumbnail.
  ///
  /// `approved_for` is not stored here: [youtubeSubscriptions] derives it from
  /// the kids' actual channel lists, so an import done in the demo shows up as
  /// "already added" straight away.
  static const _subscriptions = <Subscription>[
    Subscription(
      channelId: 'ch_supersimple',
      title: 'Super Simple Songs - Kids Songs',
      thumbUrl: 'https://i.ytimg.com/vi/pZw9veQ76fo/hqdefault.jpg',
    ),
    Subscription(
      channelId: 'ch_scishowkids',
      title: 'SciShow Kids',
      thumbUrl: 'https://i.ytimg.com/vi/0jKoOUZ1GBM/hqdefault.jpg',
    ),
    Subscription(channelId: 'ch_numberblocks', title: 'Numberblocks'),
    Subscription(channelId: 'ch_natgeokids', title: 'National Geographic Kids'),
    Subscription(channelId: 'ch_storybots', title: 'StoryBots'),
    Subscription(channelId: 'ch_artforkidshub', title: 'Art for Kids Hub'),
    Subscription(channelId: 'ch_crashcoursekids', title: 'Crash Course Kids'),
    Subscription(channelId: 'ch_teded', title: 'TED-Ed'),
    Subscription(channelId: 'ch_markrober', title: 'Mark Rober'),
    Subscription(channelId: 'ch_urdurhymes', title: 'Urdu Rhymes for Children'),
    Subscription(channelId: 'ch_peppa', title: 'Peppa Pig - Official Channel'),
    Subscription(channelId: 'ch_blippi', title: 'Blippi - Educational Videos'),
    Subscription(channelId: 'ch_kurzgesagt', title: 'Kurzgesagt in a Nutshell'),
    Subscription(
      channelId: 'ch_cricketpk',
      title: 'Pakistan Cricket Highlights',
    ),
  ];

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
        // One word, on the second question, for a concept this child has
        // already answered in English on the first (PROTOCOL). Polly has no
        // Urdu voice, so the client says this one itself or not at all.
        seed: const SeededWord(
          term: 'آتش فشاں',
          gloss: 'volcano',
          firstHeard: true,
        ),
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
      kidId: '',
      video: Video(
        id: 'WX_E1CAZjaQ',
        channelId: 'ch_scishowkids',
        title: 'KABOOM! All About Volcanoes (compilation)',
        durationS: 1560,
        ageOk: true,
        planReady: false,
      ),
      reason:
          'A 26-minute compilation: longer than their usual videos and it '
          'shows a real eruption. Fine for 9 to 11 in my view, but you decide.',
      createdAt: '2026-09-05T07:30:00Z',
    ),
  ];

  final _digests = <AgeBand, Digest>{
    AgeBand.b4to6: const Digest(
      kidId: '',
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
    AgeBand.b9to11: const Digest(
      kidId: '',
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

  /// Demo history for the Progress screen. Only the per-day pattern and the
  /// word/concept lists are canned; every total is summed from the days it
  /// generates, so 7, 14 and 30 day windows are always self-consistent.
  static final _demoShapes = <AgeBand, _DemoAnalyticsShape>{
    AgeBand.b4to6: _DemoAnalyticsShape(
      // Mon..Sun. Two quiet weekdays are deliberate: a real week has zero days
      // and the chart should not hide them.
      minutesByWeekday: const [22, 0, 31, 18, 0, 40, 26],
      minutesPerVideo: 8,
      minutesPerQuestion: 6,
      answeredShare: 0.86,
      channelShares: const [
        ('ch_supersimple', 'Super Simple Songs', 0.64),
        ('ch_scishowkids', 'SciShow Kids', 0.36),
      ],
      // Newest first, matching PROTOCOL. daysAgo feeds first_said.
      said: const [
        ('truck', 6, 1),
        ('star', 11, 2),
        ('purple', 3, 4),
        ('three', 9, 5),
        ('duck', 14, 9),
        ('apple', 7, 12),
      ],
      emerging: const [('hippo', 4), ('yellow', 3), ('under', 2)],
      note: const AnalyticsNote(
        kind: 'suggestion',
        text:
            '{name} says "duck" and "star" without being asked now, and has '
            'heard "hippo" four times without trying it. Point one out today '
            'and let them name it.',
      ),
    ),
    AgeBand.b9to11: _DemoAnalyticsShape(
      minutesByWeekday: const [35, 42, 0, 28, 50, 33, 45],
      minutesPerVideo: 11,
      minutesPerQuestion: 5,
      answeredShare: 0.72,
      channelShares: const [
        ('ch_scishowkids', 'SciShow Kids', 0.71),
        ('ch_supersimple', 'Super Simple Songs', 0.29),
      ],
      concepts: const [
        ('Why volcanoes erupt', 9, 7, 1, 1),
        ('How sound reaches the ear', 7, 5, 1, 2),
        ('Why the moon changes shape', 6, 2, 4, 3),
        ('Where rain comes from', 4, 3, 0, 6),
      ],
      needsAnotherLook: const [('Why the moon changes shape', 4, 3)],
      note: const AnalyticsNote(
        kind: 'praise',
        text:
            '{name} explained why volcanoes erupt in their own words twice '
            'this week, without a hint. The moon phases are still not '
            'landing.',
      ),
    ),
  };

  // ---------------------------------------------------------------- REST

  @override
  Future<void> signInDev(String name) async {
    await _lag();
    _signedIn = true;
  }

  bool _youtubeLinked = false;
  String _email = '';

  @override
  Future<Session> signInWithGoogle(
    String serverAuthCode, {
    String redirectUri = '',
  }) async {
    await _lag();
    // The demo has no OAuth: any code stands in for one the real gateway would
    // exchange. Nothing that looks like a refresh token exists on this side.
    _signedIn = true;
    _youtubeLinked = true;
    _email = 'parent.demo@gmail.com';
    return Session(
      token: 'demo_token',
      householdId: 'hh_demo',
      email: _email,
      youtubeLinked: _youtubeLinked,
    );
  }

  @override
  Future<YouTubeStatus> youtubeStatus() async {
    await _lag();
    return YouTubeStatus(linked: _youtubeLinked, email: _email);
  }

  @override
  Future<SubscriptionList> youtubeSubscriptions() async {
    await _lag();
    if (!_youtubeLinked) return const SubscriptionList(linked: false);
    return SubscriptionList(
      linked: true,
      subscriptions: [
        for (final s in _subscriptions)
          Subscription(
            channelId: s.channelId,
            title: s.title,
            thumbUrl: s.thumbUrl,
            approvedFor: [
              for (final e in _channels.entries)
                if (e.value.any((c) => c.id == s.channelId)) e.key,
            ],
          ),
      ],
    );
  }

  @override
  Future<ImportResult> importChannels(
    String kidId,
    List<String> channelIds, {
    String profile = '',
  }) async {
    await _lag();
    final existing = _channels[kidId] ??= [];
    final added = <Channel>[];
    final already = <String>[];
    for (final id in channelIds) {
      // Compared through the catalogue's canonical id, so the same channel
      // arriving under two ids (a pasted one and a Takeout one) is spotted as
      // already there instead of listed twice.
      final key = DemoCatalogue.canonical(id);
      if (existing.any((c) => DemoCatalogue.canonical(c.id) == key)) {
        already.add(id);
        continue;
      }
      // Importing approves the channel, not any video: the Curator still
      // screens every upload (PROTOCOL).
      final sub = _subscriptions.where((s) => s.channelId == id).firstOrNull;
      final ch = switch ((sub, DemoCatalogue.byId(id))) {
        (final Subscription s, _) => Channel(
          id: s.channelId,
          title: s.title,
          thumbUrl: s.thumbUrl,
          approved: true,
        ),
        // Takeout ids are not in the parent's own subscription list, so the
        // demo catalogue is the second place to look.
        (_, final DemoChannel c) => c.toChannel(),
        // An id from neither: keep it rather than silently dropping it, the
        // way the live gateway would resolve it against YouTube.
        _ => Channel(id: id, title: id, thumbUrl: '', approved: true),
      };
      existing.add(ch);
      added.add(ch);
    }
    // An import from an export the parent ticked history on is where the
    // aggregate lands, because naming [profile] is the call that finally says
    // which kid it belongs to. Without a profile name there is nothing to
    // attach — a pasted URL or an import from the parent's own account
    // carries no history with it.
    if (_historyOffered && profile.isNotEmpty) {
      _histories[kidId] ??= _demoHistory(kidId);
    }
    return ImportResult(added: added, already: already);
  }

  /// Whether the last export was uploaded with history included. Off, always,
  /// until a parent ticks the box for one import (PROTOCOL).
  bool _historyOffered = false;

  /// Whether the last export was uploaded with the history box ticked. Read
  /// by tests that need to prove the default is off and that the tick is what
  /// changed it.
  bool get historyWasIncluded => _historyOffered;

  final _histories = <String, HistoryInsight>{};

  @override
  Future<HistoryInsight?> history(String kidId) async {
    await _lag();
    return _histories[kidId];
  }

  @override
  Future<bool> deleteHistory(String kidId) async {
    await _lag();
    // Gone, and gone for good: a later import has to be ticked again.
    _historyOffered = false;
    return _histories.remove(kidId) != null;
  }

  /// The insight without the simulated lag, for widget tests on a frozen
  /// clock. The same object [history] would hand back.
  HistoryInsight? savedHistory(String kidId) => _histories[kidId];

  /// A year of watching, at the shape a real export has: mostly after school,
  /// a long tail of channels nobody chose, and a couple of late nights.
  ///
  /// Counts and channel names only. There is no list of videos here because
  /// there is none anywhere: the server counts the file and throws it away.
  HistoryInsight _demoHistory(String kidId) {
    final subscribed = {
      for (final c in _channels[kidId] ?? const <Channel>[])
        c.title.toLowerCase(),
    };
    const counted = <(String, int)>[
      ('Super Simple Songs - Kids Songs', 143),
      ('Slime Lab Shorts', 121),
      ('Gacha Life Stories', 98),
      ('SciShow Kids', 74),
      ('Toy Haul Tuesday', 61),
      ('Minecraft Diaries', 52),
      ('Squishy Makeover Daily', 44),
      ('Numberblocks', 31),
    ];
    return HistoryInsight(
      kidId: kidId,
      generatedAt: DateTime.now().toIso8601String(),
      videos: 1284,
      firstWatched: '2025-10-14',
      lastWatched: '2026-09-04',
      topChannels: [
        for (final (title, videos) in counted)
          HistoryChannel(
            title: title,
            videos: videos,
            subscribed: subscribed.contains(title.toLowerCase()),
          ),
      ],
      unsubscribedShare: 0.62,
      // Midnight to 23:00. Quiet in the morning, a wall after school, and a
      // little that is later than a parent probably thinks.
      byHour: const [
        12, 4, 1, 0, 0, 0, 2, 18, 24, 9, 6, 11, //
        38, 22, 31, 74, 118, 143, 121, 96, 62, 41, 27, 19,
      ],
      summary:
          'Most of what was watched came from channels this profile does not '
          'follow. The busiest hour is 5pm, and there is some watching after '
          '10pm. Only channel names and counts were kept; the file and every '
          'video title in it were discarded.',
    );
  }

  /// A stand-in for the two YouTube Kids profiles a real export contains, at
  /// the sizes a real export contains them: 153 channels and 24.
  ///
  /// The zip is never opened. Demo mode has no server to unzip it, and the
  /// screen says plainly that it is using a sample.
  @override
  Future<TakeoutPreview> importTakeout(
    Uint8List zipBytes,
    String filename, {
    bool includeHistory = false,
  }) async {
    await _lag();
    // Whether this export brought history with it. The insight belongs to a
    // kid, and which kid a profile is only settled when the parent maps it,
    // so it is attached at that point rather than here.
    _historyOffered = includeHistory;
    return TakeoutPreview(
      profiles: [
        TakeoutProfile(
          name: 'Profile 1',
          channelCount: DemoCatalogue.older.length,
          channels: [for (final c in DemoCatalogue.older) c.toTakeoutChannel()],
        ),
        TakeoutProfile(
          name: 'Profile 2',
          channelCount: DemoCatalogue.younger.length,
          channels: [
            for (final c in DemoCatalogue.younger) c.toTakeoutChannel(),
          ],
        ),
      ],
      parent: TakeoutProfile(
        channelCount: DemoCatalogue.parentOwn.length,
        channels: [
          for (final c in DemoCatalogue.parentOwn) c.toTakeoutChannel(),
        ],
      ),
    );
  }

  /// Channels the demo has "already reviewed". Seeded with every fourth one so
  /// the first answer comes back part-cached, exactly like a shared cache that
  /// another household has already filled in.
  late final Set<String> _reviewed = {
    for (var i = 0; i < DemoCatalogue.all.length; i += 4)
      DemoCatalogue.all[i].id,
  };

  /// How many the demo "finishes" per poll. 153 channels then take about four
  /// rounds, which is what the progress line and the backoff are there for.
  static const _reviewsPerRound = 40;

  @override
  Future<ChannelReviewBatch> channelReviews(List<String> channelIds) async {
    await _lag();
    var budget = _reviewsPerRound;
    final reviews = <ChannelReview>[];
    final pending = <String>[];
    for (final id in channelIds.toSet()) {
      final channel = DemoCatalogue.byId(id);
      // A channel the demo has never heard of appears in neither list, which
      // is the case the client's poll has to survive without spinning.
      if (channel == null) continue;
      if (!_reviewed.contains(id)) {
        if (budget == 0) {
          pending.add(id);
          continue;
        }
        budget--;
        _reviewed.add(id);
      }
      reviews.add(channel.review);
    }
    return ChannelReviewBatch(reviews: reviews, pending: pending);
  }

  @override
  Future<ChannelReview> channelReview(
    String channelId, {
    bool refresh = false,
  }) async {
    await _lag();
    final channel = DemoCatalogue.byId(channelId);
    if (channel == null) {
      throw StateError('No review for $channelId');
    }
    _reviewed.add(channelId);
    return channel.review;
  }

  /// Channels the demo has already re-read for drift. A second check answers
  /// from here with `checked: 0`, the way a week-long rate limit would.
  final _driftChecked = <String>{};

  @override
  Future<DriftCheck> checkDrift(List<String> channelIds) async {
    await _lag();
    final drifted = <ChannelDrift>[];
    var checked = 0;
    for (final id in channelIds.toSet()) {
      final channel = DemoCatalogue.byId(id);
      if (channel == null) continue;
      if (_driftChecked.add(id)) checked++;
      final story = _driftStories[channel.id];
      if (story == null) continue;
      drifted.add(
        ChannelDrift(
          channelId: channel.id,
          title: channel.title,
          was: DriftSnapshot(
            verdict: channel.review.verdict,
            flags: channel.review.flags,
            reviewedAt: channel.review.reviewedAt,
          ),
          now: DriftSnapshot(
            verdict: story.verdict,
            flags: [
              ...channel.review.flags,
              ReviewFlag(kind: story.flag, note: story.note),
            ],
            reviewedAt: DateTime.now().toUtc().toIso8601String(),
          ),
          worse: true,
          whatChanged: story.whatChanged,
          sampleTitles: story.samples,
        ),
      );
    }
    return DriftCheck(drifted: drifted, checked: checked);
  }

  /// Two channels in the demo pile that have moved since they were approved.
  ///
  /// Both are invented names, as every unflattering demo review is: putting a
  /// drift on a real creator's name would be unfair to them.
  static final _driftStories =
      <
        String,
        ({
          ReviewVerdict verdict,
          String flag,
          String note,
          String whatChanged,
          List<String> samples,
        })
      >{
        'ch_slimelabkids': (
          verdict: ReviewVerdict.concern,
          flag: 'ads_or_merch',
          note:
              'Recent uploads open with a paid promotion for a mobile game '
              'with in-app purchases.',
          whatChanged:
              'It used to be craft videos. Since June most uploads open with '
              'a sponsor read for a game with loot boxes, and the channel '
              'sells its own merch in the first minute.',
          samples: [
            'MY NEW MERCH IS HERE (use my code)',
            '£100 SLIME HAUL - sponsored by Gem Quest',
            'I spent my whole allowance in Gem Quest',
          ],
        ),
        'ch_pranksquadworld': (
          verdict: ReviewVerdict.concern,
          flag: 'scary',
          note: 'Several recent uploads are scare pranks on family members.',
          whatChanged:
              'The pranks have moved from harmless to frightening: four of '
              'the last ten uploads are scare pranks, two of them on a child '
              'who is crying by the end.',
          samples: [
            'SCARING MY LITTLE SISTER AT 3AM',
            'She actually cried... (gone too far)',
            'Fake spider in her bed prank',
          ],
        ),
      };

  @override
  Future<void> removeChannel(String kidId, String channelId) async {
    await _lag();
    _channels[kidId]?.removeWhere((c) => c.id == channelId);
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
    // Demo mode only: give the new kid the two sample channels so the home
    // rows, digest and Progress screens have something to show immediately.
    _channels[kid.id] = [_sss, _ssk];
    return kid;
  }

  @override
  Future<List<Channel>> channels(String kidId) async {
    await _lag();
    return List.unmodifiable(_channels[kidId] ?? const []);
  }

  /// The demo's copy of the server's bank, enough to show the screen working.
  /// Real wording lives in agents/heygilli_agents/question_bank.py.
  static const _bank = <String, List<List<String>>>{
    '4_6': [
      ['p46_favourite_part', 'What was your favourite bit?', 'name_it', 'voice'],
      ['p46_who_was_in_it', 'Who was in it?', 'name_it', 'voice'],
      ['p46_colour_seen', 'Name a colour you saw', 'name_it', 'voice'],
      ['p46_clap', 'Clap for the video', 'copy_it', 'copy'],
      ['p46_stretch_tall', 'Stretch up tall', 'copy_it', 'copy'],
      ['p46_happy_sad', 'Happy or sad?', 'name_it', 'voice'],
    ],
    '7_8': [
      ['p78_favourite_part', 'What was your favourite part?', 'recall', 'voice'],
      ['p78_one_new_thing', 'One thing you learned', 'recall', 'voice'],
      ['p78_what_happened_first', 'What happened first?', 'recall', 'voice'],
      ['p78_why_liked', 'Why did you like it?', 'why', 'voice'],
      ['p78_what_next', 'What might happen next?', 'predict', 'voice'],
    ],
    '9_11': [
      ['p911_tell_a_friend', 'Explain it to a friend', 'explain', 'voice'],
      ['p911_best_bit_why', 'Best part, and why', 'opinion', 'voice'],
      ['p911_something_left_out', 'What was left out?', 'apply', 'voice'],
      ['p911_compare_other', 'How did it compare?', 'compare', 'voice'],
      ['p911_would_recommend', 'Would you recommend it?', 'opinion', 'voice'],
    ],
  };

  final Map<String, Set<String>> _disabledPrompts = {};

  List<KidPrompt> _promptsFor(String kidId) {
    final kid = _kids.firstWhere((k) => k.id == kidId);
    final off = _disabledPrompts[kidId] ?? const <String>{};
    return [
      for (final row in _bank[kid.band.wire] ?? const <List<String>>[])
        KidPrompt(
          id: row[0],
          label: row[1],
          type: row[2],
          input: row[3],
          enabled: !off.contains(row[0]),
        ),
    ];
  }

  @override
  Future<List<KidPrompt>> prompts(String kidId) async {
    await _lag();
    return _promptsFor(kidId);
  }

  @override
  Future<List<KidPrompt>> savePrompts(
    String kidId,
    List<String> disabled,
  ) async {
    await _lag();
    _disabledPrompts[kidId] = disabled.toSet();
    return _promptsFor(kidId);
  }

  @override
  Future<Kid> editKid(
    String kidId, {
    String? nickname,
    int? age,
    List<String>? languages,
  }) async {
    await _lag();
    final i = _kids.indexWhere((k) => k.id == kidId);
    if (i < 0) throw StateError('no such kid: $kidId');
    final old = _kids[i];
    final newAge = age ?? old.age;
    final updated = Kid(
      id: old.id,
      nickname: nickname ?? old.nickname,
      age: newAge,
      // Re-derived, like the server does: keeping the old band is the bug the
      // edit exists to fix.
      band: AgeBand.forAge(newAge),
      languages: languages ?? old.languages,
      avatar: old.avatar,
      dailyMinutes: old.dailyMinutes,
      breakAfterMinutes: old.breakAfterMinutes,
      breakMinutes: old.breakMinutes,
      maxVideoMinutes: old.maxVideoMinutes,
      breakIsFirm: old.breakIsFirm,
      breakMessages: old.breakMessages,
      searchEnabled: old.searchEnabled,
    );
    _kids[i] = updated;
    return updated;
  }

  @override
  Future<void> curateNow(String kidId) async {
    // The demo's videos are canned, so there is nothing to screen: the button
    // must still work, and must still take a moment, or the demo would show a
    // spinner that never appears on a real gateway.
    await _lag();
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
  /// Demo mode has no Polly behind it, so every line is spoken on-device.
  @override
  Future<String> speechUrl(String text, {bool slow = false}) async => '';

  @override
  Future<List<HomeRow>> home(String kidId, {String query = ''}) async {
    await _lag();
    final kid = _kids.where((k) => k.id == kidId).firstOrNull;
    if (kid == null) return const [];
    final rows = kid.band == AgeBand.b4to6
        ? const [
            HomeRow(title: 'New from your channels', videos: [_ducks, _twinkle]),
            HomeRow(title: 'Keep watching', videos: [_ears, _volcano]),
          ]
        : const [
            HomeRow(title: 'New from your channels', videos: [_volcano, _ears]),
            HomeRow(title: 'Keep watching', videos: [_twinkle, _ducks]),
          ];
    final q = query.trim().toLowerCase();
    // Same rule as the gateway: a query only ever narrows what is already
    // approved, and it does nothing at all unless the parent enabled it.
    if (q.isEmpty || !kid.searchEnabled) return rows;
    final hits = [
      for (final row in rows)
        for (final v in row.videos)
          if (v.title.toLowerCase().contains(q)) v,
    ];
    return [HomeRow(title: 'Found ${hits.length}', videos: hits)];
  }

  final _sessions = <String, _FakeSessionInfo>{};

  @override
  Future<SessionStartResult> startSession({
    required String kidId,
    required String videoId,
    required String device,
  }) async {
    await _lag();
    final kid = _kids.firstWhere((k) => k.id == kidId);
    // The live gateway answers 409 here while a break runs; so does this one,
    // which is how the demo proves nothing plays during a break.
    final active = _liveBreak(kidId);
    if (active != null) return SessionBlockedByBreak(active);
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
    return SessionStarted(
      SessionStart(sessionId: id, video: video, planReady: true),
    );
  }

  @override
  Future<SessionSocket> openSession(String sessionId) async {
    final info = _sessions[sessionId]!;
    return FakeSession(
      kid: info.kid,
      video: info.video,
      plan: _plans[info.video.id] ?? const [],
      // Demo mode compresses the real 25 minutes into one, so a judge sees a
      // break inside a three-minute video instead of taking the app's word
      // for it. Off entirely when the parent set "never".
      breakAtS: info.kid.takesBreaks ? _demoBreakAtS : null,
      onBreakDue: () => startDemoBreak(info.kid.id, source: info.video.title),
    );
  }

  // ------------------------------------------------- time limits and breaks

  /// Demo only: how long into a video Gilli calls a break.
  static const _demoBreakAtS = 60;

  final _breaks = <String, BreakPeriod>{};

  /// Minutes "already watched today", moved by the demo controls so the
  /// numbers on the parent card agree with whatever screen is being shown.
  final _minutesToday = <String, int>{};

  /// The break for [kidId] if it is still running, expiring it when its own
  /// timer has passed. The break ends on the clock, never on a tap.
  BreakPeriod? _liveBreak(String kidId) {
    final b = _breaks[kidId];
    if (b == null) return null;
    final left = _secondsLeft(b);
    if (left <= 0) {
      _breaks.remove(kidId);
      return null;
    }
    return b.copyWith(secondsLeft: left);
  }

  int _secondsLeft(BreakPeriod b) {
    final ends = DateTime.tryParse(b.endsAt);
    if (ends == null) return b.secondsLeft;
    return ends.difference(DateTime.now()).inSeconds;
  }

  Kid? _kid(String id) => _kids.where((k) => k.id == id).firstOrNull;

  @override
  Future<WatchState> watchState(String kidId) async {
    await _lag();
    return watchStateNow(kidId);
  }

  /// The same answer without the fake network lag, so the demo controls can
  /// read back what they just did.
  WatchState watchStateNow(String kidId) {
    final kid = _kid(kidId);
    final active = _liveBreak(kidId);
    final today = _minutesToday[kidId] ?? 0;
    final daily = kid?.dailyMinutes ?? 0;
    final dayDone = daily > 0 && today >= daily;
    return WatchState(
      minutesToday: today,
      minutesLeftToday: daily == 0 ? 0 : (daily - today).clamp(0, daily),
      continuousMinutes: active == null ? today : 0,
      watchingAllowed: active == null && !dayDone,
      // A break wins over the daily limit: it is the thing the child is
      // standing in the middle of.
      blockedReason: active != null
          ? BlockedReason.movementBreak
          : (dayDone ? BlockedReason.dailyLimit : null),
      activeBreak: active,
    );
  }

  @override
  Future<Kid> updateLimits(
    String kidId, {
    int? dailyMinutes,
    int? breakAfterMinutes,
    int? breakMinutes,
    int? maxVideoMinutes,
    bool? breakIsFirm,
    bool? searchEnabled,
  }) async {
    await _lag();
    final i = _kids.indexWhere((k) => k.id == kidId);
    if (i < 0) throw StateError('No kid $kidId');
    final updated = _kids[i].copyWith(
      dailyMinutes: dailyMinutes,
      breakAfterMinutes: breakAfterMinutes,
      breakMinutes: breakMinutes,
      maxVideoMinutes: maxVideoMinutes,
      breakIsFirm: breakIsFirm,
      searchEnabled: searchEnabled,
    );
    _kids[i] = updated;
    return updated;
  }

  @override
  Future<Kid> saveBreakMessages(
    String kidId,
    List<BreakMessage> messages,
  ) async {
    await _lag();
    final i = _kids.indexWhere((k) => k.id == kidId);
    if (i < 0) throw StateError('No kid $kidId');
    // Saved exactly as given, empty list included: a parent clearing their
    // lines means a quiet break, and is not a reason to keep the old ones.
    var n = 0;
    final saved = [
      for (final m in messages)
        BreakMessage(
          id: m.id.isNotEmpty ? m.id : 'msg_${kidId}_${n++}',
          text: m.text,
          spoken: m.spoken,
        ),
    ];
    final updated = _kids[i].copyWith(breakMessages: saved);
    _kids[i] = updated;
    // The rotation restarts on the new list rather than pointing into the old.
    _messageCursor.remove(kidId);
    return updated;
  }

  @override
  Future<List<BreakMessage>> suggestBreakMessages(String kidId) async {
    await _lag();
    final kid = _kid(kidId);
    // Drafts only. These reach a child solely by way of saveBreakMessages,
    // which is a parent's tap; the real gateway's Coach agent answers here.
    final preReader = kid?.band == AgeBand.b4to6;
    return [
      BreakMessage(
        id: 'draft_1',
        text: 'Break time. Go and find me three blue things in this room.',
        spoken: preReader
            ? 'Break time! Can you find three blue things? Go and look!'
            : 'Break time. Go and find three blue things in this room.',
      ),
      const BreakMessage(
        id: 'draft_2',
        text: 'Break time. Have a drink of water and a good stretch.',
        spoken: 'Break time! Have a drink of water and a big stretch.',
      ),
      const BreakMessage(
        id: 'draft_3',
        text: 'Break time. Go and tell someone one thing you just learned.',
        spoken: 'Break time! Go and tell someone what you just learned.',
      ),
    ];
  }

  @override
  Future<BreakPeriod> ackBreak(String kidId) async {
    await _lag();
    final b = _liveBreak(kidId);
    if (b == null) throw StateError('No break running for $kidId');
    // Recorded, and that is all: the seconds left are untouched.
    final acked = b.copyWith(acked: true);
    _breaks[kidId] = acked;
    return acked;
  }

  @override
  Future<void> overrideBreak(String kidId) async {
    await _lag();
    _breaks.remove(kidId);
  }

  /// Demo control: start a break right now for [kidId].
  ///
  /// The real one starts the same way: the gateway picks the next line the
  /// parent saved, rotating so the same sentence is not read every time. A
  /// parent who saved nothing gets a quiet break, and neither this nor the
  /// real gateway writes a line to fill it.
  BreakPeriod startDemoBreak(String kidId, {String source = ''}) {
    final kid = _kid(kidId);
    final minutes = kid?.breakMinutes ?? Kid.defaultBreakMinutes;
    final now = DateTime.now();
    final active = BreakPeriod(
      id: 'brk_${now.millisecondsSinceEpoch}',
      kidId: kidId,
      startedAt: now.toIso8601String(),
      endsAt: now.add(Duration(minutes: minutes)).toIso8601String(),
      secondsLeft: minutes * 60,
      isFirm: kid?.breakIsFirm ?? true,
      message: _nextMessage(kid),
    );
    _breaks[kidId] = active;
    // Keep the counters honest: a break fires because they have been watching.
    final after = kid?.breakAfterMinutes ?? Kid.defaultBreakAfterMinutes;
    _minutesToday[kidId] =
        (_minutesToday[kidId] ?? 0) + (after > 0 ? after : 25);
    return active;
  }

  /// Which saved line each kid heard last, so the next break moves on.
  final Map<String, int> _messageCursor = {};

  BreakMessage? _nextMessage(Kid? kid) {
    final lines = kid?.breakMessages ?? const <BreakMessage>[];
    if (lines.isEmpty) return null;
    final next = (_messageCursor[kid!.id] ?? -1) + 1;
    _messageCursor[kid.id] = next;
    return lines[next % lines.length];
  }

  /// The lines saved for [kidId] right now, without the simulated network
  /// lag. Widget tests run on a frozen clock, where awaiting that lag never
  /// comes back; this is the same list [kids] would hand them.
  List<BreakMessage> savedBreakMessages(String kidId) =>
      _kid(kidId)?.breakMessages ?? const [];

  /// Demo control: put the kid at their daily limit so the end-of-day screen
  /// can be seen.
  void useUpTheDay(String kidId) {
    _breaks.remove(kidId);
    final daily = _kid(kidId)?.dailyMinutes ?? Kid.defaultDailyMinutes;
    _minutesToday[kidId] = daily == 0 ? 0 : daily;
  }

  /// Demo control: back to a normal day with everything to watch.
  void clearDemoLimits(String kidId) {
    _breaks.remove(kidId);
    _minutesToday.remove(kidId);
  }

  @override
  Future<void> endSession(String sessionId) async {
    _sessions.remove(sessionId);
  }

  @override
  Future<Digest> digest(String kidId, String date) async {
    await _lag();
    final kid = _kids.where((k) => k.id == kidId).firstOrNull;
    final d = kid == null ? null : _digests[kid.band];
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
        kind: kid?.band == AgeBand.b4to6 ? 'prereader' : 'older',
      );
    }
    return Digest.fromJson({...d.toJson(), 'date': date, 'kid_id': kidId});
  }

  @override
  Future<Digest> runDigest(String kidId) =>
      digest(kidId, DateTime.now().toIso8601String().substring(0, 10));

  @override
  Future<Analytics> analytics(String kidId, {int days = 14}) async {
    await _lag();
    final kid = _kids.where((k) => k.id == kidId).firstOrNull;
    // A kid added during the demo has no history yet: that is the empty state,
    // and the screen is built to show it honestly.
    final shape = kid == null ? null : _demoShapes[kid.band];
    if (shape == null) {
      return Analytics(
        kidId: kidId,
        band: kid?.band ?? AgeBand.b4to6,
        days: days.clamp(7, 90),
        generatedAt: DateTime.now().toIso8601String(),
        totals: const AnalyticsTotals(),
        daily: const [],
        vocabulary: const Vocabulary(),
        concepts: const [],
        needsAnotherLook: const [],
        channels: const [],
        note: const AnalyticsNote(
          kind: 'quiet',
          text: 'Nothing yet. This fills in after the first watch.',
        ),
      );
    }
    return shape.build(kid!, days.clamp(7, 90));
  }

  /// One saved policy per kid. Nothing is seeded: a household that has not
  /// answered anything has an empty policy, which is a valid state and the one
  /// every new kid starts in (PROTOCOL).
  final _policies = <String, Policy>{};

  @override
  Future<Policy> policy(String kidId) async {
    await _lag();
    return _policies[kidId] ?? Policy(kidId: kidId);
  }

  @override
  Future<Policy> savePolicy(
    String kidId, {
    required List<PolicyAnswer> answers,
    required String notes,
  }) async {
    await _lag();
    final saved = Policy(
      kidId: kidId,
      updatedAt: DateTime.now().toIso8601String(),
      // The weight is the server's, and the real one recomputes it from how
      // often the answer actually decided a video. The demo settles for a
      // stable number per choice so the parent screen has something true to
      // its own data to show: a "rather not" does more work than a "fine".
      answers: [
        for (final a in answers)
          PolicyAnswer(
            id: a.id,
            question: a.question,
            choice: a.choice,
            weight: switch (a.choice) {
              PolicyChoice.ratherNot => 0.8,
              PolicyChoice.sometimes => 0.5,
              PolicyChoice.fine => 0.2,
            },
          ),
      ],
      notes: notes,
    );
    _policies[kidId] = saved;
    return saved;
  }

  /// The saved policy without the simulated network lag, for widget tests on
  /// a frozen clock. Same object [policy] would hand back.
  Policy savedPolicy(String kidId) => _policies[kidId] ?? Policy(kidId: kidId);

  /// Question templates for the demo Coach.
  ///
  /// Each one only gets asked when this child's own channels match it, and
  /// `why` names the ones that did — which is the whole point of the endpoint
  /// (PROTOCOL): a household with forty gaming channels is asked about gaming.
  static const _policyTemplates =
      <({String id, List<String> match, String question, String why})>[
        (
          id: 'q_gaming',
          match: ['minecraft', 'roblox', 'gacha', 'among', 'sandbox', 'gaming'],
          question:
              'Gaming videos, where someone plays and talks over the top?',
          why: 'do this',
        ),
        (
          id: 'q_toys',
          match: ['toy', 'lego', 'hot wheels', 'nerf', 'doll', 'squishy'],
          question: 'Toy videos that are mostly about buying the toy?',
          why: 'post unboxings and hauls',
        ),
        (
          id: 'q_slime',
          match: ['slime', 'squishy', 'shorts', 'clips'],
          question: 'Very short videos, one after another?',
          why: 'publish mostly shorts',
        ),
        (
          id: 'q_peril',
          match: ['dino', 'monster', 'mystery', 'wild', 'nat geo'],
          question: 'Animals hunting, or a creature in danger?',
          why: 'show this sometimes',
        ),
        (
          id: 'q_songs',
          match: ['songs', 'rhymes', 'nursery', 'simple'],
          question: 'Songs and rhymes on repeat, with no story?',
          why: 'are mostly songs',
        ),
      ];

  @override
  Future<PolicyQuestions> policyQuestions(String kidId) async {
    await _lag();
    final name = _kid(kidId)?.nickname ?? 'this child';
    final titles = [
      for (final c in _channels[kidId] ?? const <Channel>[]) c.title,
    ];
    final questions = <PolicyQuestion>[];
    for (final t in _policyTemplates) {
      final hits = [
        for (final title in titles)
          if (t.match.any((m) => title.toLowerCase().contains(m))) title,
      ];
      if (hits.isEmpty) continue;
      final named = hits.take(2).join(' and ');
      questions.add(
        PolicyQuestion(
          id: t.id,
          question: t.question,
          why: hits.length > 2
              ? '$named and ${hits.length - 2} more of the channels you '
                    'approved for $name ${t.why}.'
              : '$named ${t.why}.',
        ),
      );
    }
    if (questions.isEmpty) {
      // Nothing to point at is said plainly rather than dressed up as a
      // finding. A question with an invented reason is worse than no question,
      // and an empty basedOn is how the screen knows to say so.
      return PolicyQuestions(
        questions: [
          PolicyQuestion(
            id: 'q_ads',
            question: 'Videos that sell something — merch, a sponsor, a code?',
            why:
                'Asked of every household. HeyGilli has not read enough of '
                "$name's channels yet to say which prompted it.",
          ),
        ],
      );
    }
    return PolicyQuestions(questions: questions, basedOn: titles);
  }

  @override
  Future<List<RevisitConcept>> revisits(String kidId) async {
    await _lag();
    final kid = _kid(kidId);
    final shape = kid == null ? null : _demoShapes[kid.band];
    final today = DateTime.now();
    String daysAgo(int n) => DateTime(
      today.year,
      today.month,
      today.day - n,
    ).toIso8601String().substring(0, 10);
    // The same list Analytics calls needs_another_look, seen from the other
    // side: what has been come back to, and what is still waiting a turn.
    // A pre-reader's shape has none, and that is the honest answer.
    return [
      for (final (i, s) in (shape?.needsAnotherLook ?? const []).indexed)
        RevisitConcept(
          concept: s.$1,
          timesShaky: s.$2,
          lastSeen: daysAgo(s.$3),
          // The first one has had its turn; anything after it is queued,
          // because at most one revisit fits in a session (PROTOCOL).
          askedAgain: i == 0 ? 1 : 0,
        ),
    ];
  }

  /// Urdu words the demo has offered, at the rate the rule allows: one a
  /// session, and never one for a concept the child has not already got right
  /// in English (PROTOCOL). A couple have come back; most have not, which is
  /// what a real week looks like.
  static const _demoWords = <WordSeed>[
    WordSeed(
      term: 'بادل',
      gloss: 'cloud',
      timesHeard: 4,
      timesSaid: 2,
      firstHeard: '2026-08-24',
      lastHeard: '2026-09-03',
    ),
    WordSeed(
      term: 'آتش فشاں',
      gloss: 'volcano',
      timesHeard: 3,
      timesSaid: 1,
      firstHeard: '2026-08-28',
      lastHeard: '2026-09-04',
    ),
    WordSeed(
      term: 'چاند',
      gloss: 'moon',
      timesHeard: 2,
      firstHeard: '2026-09-01',
      lastHeard: '2026-09-02',
    ),
    WordSeed(
      term: 'زلزلہ',
      gloss: 'earthquake',
      timesHeard: 1,
      firstHeard: '2026-09-05',
      lastHeard: '2026-09-05',
    ),
  ];

  @override
  Future<List<WordSeed>> words(String kidId) async {
    await _lag();
    // A household with one language is offered nothing, and that is not an
    // empty state to apologise for: seeding is opt-in by virtue of the
    // language list (PROTOCOL).
    final kid = _kid(kidId);
    if (kid == null || !kid.speaksUrdu) return const [];
    return _demoWords;
  }

  @override
  Future<List<ParentPrompt>> inbox() async {
    await _lag();
    // Attach the sample prompt to the oldest kid the parent has actually
    // added; with no kids there is nothing to decide.
    final oldest = _kids.isEmpty
        ? null
        : _kids.reduce((a, b) => a.age >= b.age ? a : b);
    if (oldest == null) return const [];
    return List.unmodifiable([
      for (final p in _inbox)
        ParentPrompt(
          id: p.id,
          kidId: oldest.id,
          video: p.video,
          reason: p.reason,
          createdAt: p.createdAt,
        ),
    ]);
  }

  @override
  Future<void> decide(String promptId, String decision) async {
    await _lag();
    _inbox.removeWhere((p) => p.id == promptId);
  }

  Future<void> _lag() =>
      Future<void>.delayed(const Duration(milliseconds: 250));
}

/// Builds a whole Analytics payload for a demo kid over an arbitrary window.
///
/// Totals, channel minutes and the answer rate are all derived from the daily
/// series it generates, so they can never disagree with the chart above them.
class _DemoAnalyticsShape {
  _DemoAnalyticsShape({
    required this.minutesByWeekday,
    required this.minutesPerVideo,
    required this.minutesPerQuestion,
    required this.answeredShare,
    required this.channelShares,
    required this.note,
    this.said = const [],
    this.emerging = const [],
    this.concepts = const [],
    this.needsAnotherLook = const [],
  });

  /// Index 0 is Monday, matching DateTime.weekday - 1.
  final List<int> minutesByWeekday;
  final int minutesPerVideo;
  final int minutesPerQuestion;
  final double answeredShare;
  final List<(String id, String title, double share)> channelShares;
  final AnalyticsNote note;

  /// (word, times said, days ago first said)
  final List<(String, int, int)> said;

  /// (word, times heard)
  final List<(String, int)> emerging;

  /// (concept, asked, understood, shaky, days ago last seen)
  final List<(String, int, int, int, int)> concepts;

  /// (concept, times shaky, days ago last seen)
  final List<(String, int, int)> needsAnotherLook;

  Analytics build(Kid kid, int days) {
    final now = DateTime.now();
    // Calendar arithmetic rather than Duration so a DST change cannot land two
    // bars on the same date.
    DateTime dayAgo(int n) => DateTime(now.year, now.month, now.day - n);

    final daily = <AnalyticsDay>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = dayAgo(i);
      final base = minutesByWeekday[d.weekday - 1];
      // A little deterministic wobble so a 30-day window is not visibly
      // periodic. Quiet days stay quiet.
      final minutes = base == 0 ? 0 : (base + (i * 7) % 9 - 4).clamp(3, 90);
      final asked = minutes == 0 ? 0 : (minutes / minutesPerQuestion).round();
      daily.add(
        AnalyticsDay(
          date: _isoDate(d),
          minutes: minutes,
          videos: minutes == 0 ? 0 : (minutes / minutesPerVideo).ceil(),
          asked: asked,
          answered: (asked * answeredShare).round(),
        ),
      );
    }

    var minutes = 0, videos = 0, asked = 0, answered = 0, sessions = 0;
    for (final d in daily) {
      minutes += d.minutes;
      videos += d.videos;
      asked += d.asked;
      answered += d.answered;
      if (d.minutes > 0) sessions++;
    }

    // Split minutes by share, then hand the rounding remainder to the biggest
    // channel so the bars add up to the headline number exactly.
    final channels = <ChannelMinutes>[];
    var allocated = 0;
    for (var i = 0; i < channelShares.length; i++) {
      final (id, title, share) = channelShares[i];
      final m = i == channelShares.length - 1
          ? minutes - allocated
          : (minutes * share).round();
      allocated += m;
      channels.add(
        ChannelMinutes(
          channelId: id,
          title: title,
          minutes: m,
          videos: (videos * share).round(),
        ),
      );
    }
    channels.sort((a, b) => b.minutes.compareTo(a.minutes));

    // Only words first said inside the window count as history for it.
    final saidInWindow = [
      for (final (word, times, ago) in said)
        if (ago < days)
          SaidWord(
            word: word,
            timesSaid: times,
            firstSaid: _isoDate(dayAgo(ago)),
          ),
    ];

    return Analytics(
      kidId: kid.id,
      band: kid.band,
      days: days,
      generatedAt: now.toIso8601String(),
      totals: AnalyticsTotals(
        minutes: minutes,
        videos: videos,
        sessions: sessions,
        asked: asked,
        answered: answered,
        answerRate: asked == 0 ? 0 : answered / asked,
      ),
      daily: daily,
      vocabulary: Vocabulary(
        totalSaid: saidInWindow.length,
        newThisWeek: saidInWindow
            .where((w) => said.firstWhere((s) => s.$1 == w.word).$3 < 7)
            .length,
        said: saidInWindow,
        emerging: [
          for (final (word, heard) in emerging)
            EmergingWord(word: word, timesHeard: heard),
        ],
      ),
      concepts: [
        for (final (concept, a, u, s, ago) in concepts)
          ConceptStat(
            concept: concept,
            asked: a,
            understood: u,
            shaky: s,
            lastSeen: _isoDate(dayAgo(ago)),
          ),
      ],
      needsAnotherLook: [
        for (final (concept, times, ago) in needsAnotherLook)
          ShakyConcept(
            concept: concept,
            timesShaky: times,
            lastSeen: _isoDate(dayAgo(ago)),
          ),
      ],
      channels: channels,
      note: AnalyticsNote(
        kind: note.kind,
        text: note.text.replaceAll('{name}', kid.nickname),
      ),
    );
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
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
    this.seed,
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

  /// The Urdu word this question offers, if any. At most one per plan, and
  /// only for a kid whose languages include it (PROTOCOL).
  final SeededWord? seed;
}

/// Scripted server side of one session. Watches `position` messages and runs
/// pause → ask → (answer) → reply → resume for each planned question, scoring
/// answers the way SPEC 7.4 describes (forgiving for pre-readers).
class FakeSession implements SessionSocket {
  FakeSession({
    required this.kid,
    required this.video,
    required this.plan,
    this.breakAtS,
    this.onBreakDue,
  }) {
    _out = StreamController<ServerMessage>.broadcast();
  }

  final Kid kid;
  final Video video;
  final List<PlannedAsk> plan;

  /// Position at which this session calls a movement break, or null for none.
  final int? breakAtS;

  /// Registers the break with the gateway and hands it back, so the same
  /// break is what `GET /state` and `POST /sessions` see afterwards.
  final BreakPeriod Function()? onBreakDue;

  late final StreamController<ServerMessage> _out;
  int _nextQ = 0;
  bool _busy = false;
  bool _closed = false;
  bool _breakSent = false;
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
        // PROTOCOL: the break waits for a natural moment, so it never lands
        // while a question is in flight (_busy covers that).
        if (!_breakSent && breakAtS != null && seconds >= breakAtS!) {
          _breakSent = true;
          final active = onBreakDue?.call();
          if (active != null) _emit(BreakStartedMessage(active));
          return;
        }
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
        // Only for a bilingual session. Seeding is opt-in by virtue of the
        // language list, so an English-only kid is never offered one.
        word: urdu ? ask.seed : null,
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
