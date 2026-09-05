import 'models.dart';

/// The demo's channel catalogue and the review each channel gets.
///
/// Sized from a real export: one child subscribed to 153 channels, the other
/// to 24. Both screens have to stay calm at those numbers, so the demo has to
/// reach them - a six-row sample would prove nothing.
///
/// The spread is deliberate: mostly `good`, a handful of `mixed`, two
/// `concern`, one `unknown`. Every `mixed` and `concern` verdict lands on an
/// invented channel name. Putting an unflattering review on a real creator's
/// name in demo data would be unfair to them, and the review is meant as
/// advice about recent uploads anyway, not a judgement on a person.
class DemoChannel {
  const DemoChannel({
    required this.id,
    required this.title,
    required this.thumbUrl,
    required this.review,
  });

  final String id;
  final String title;
  final String thumbUrl;
  final ChannelReview review;

  Channel toChannel() =>
      Channel(id: id, title: title, thumbUrl: thumbUrl, approved: true);

  TakeoutChannel toTakeoutChannel() => TakeoutChannel(
    channelId: id,
    title: title,
    url: 'https://www.youtube.com/channel/$id',
  );
}

abstract final class DemoCatalogue {
  /// Every channel the demo knows about, in a stable order.
  static final List<DemoChannel> all = _build();

  /// The older child's pile: all 153. This is the list the review screen has
  /// to stay usable at.
  static List<DemoChannel> get older => all;

  /// The younger child's 24, taken from the middle so the slice contains a
  /// couple of the flagged ones rather than only the safe named channels.
  static List<DemoChannel> get younger => all.sublist(12, 36);

  /// The parent's own subscriptions in the same export. Shown as a count and
  /// left alone: they are the parent's, not a child's.
  static List<DemoChannel> get parentOwn => all.sublist(100, 141);

  /// Ids used elsewhere in the demo before this catalogue existed, so a kid
  /// created in demo mode still has reviewable channels.
  static const _aliases = <String, String>{
    'ch_supersimple': 'ch_supersimplesongskidssongs',
  };

  /// The id this catalogue knows a channel by. Used so importing the same
  /// channel twice under two ids is spotted as a duplicate, not added twice.
  static String canonical(String id) => _aliases[id] ?? id;

  static DemoChannel? byId(String id) {
    final key = canonical(id);
    for (final c in all) {
      if (c.id == key) return c;
    }
    return null;
  }

  // ------------------------------------------------------------------ build

  /// Real, widely known kids' and education channels. All reviewed `good`
  /// except one `unknown`, which is simply a channel that has gone quiet.
  static const _named = <String>[
    'Super Simple Songs - Kids Songs',
    'SciShow Kids',
    'Numberblocks',
    'Alphablocks',
    'National Geographic Kids',
    'StoryBots',
    'Art for Kids Hub',
    'Crash Course Kids',
    'TED-Ed',
    'Peppa Pig - Official Channel',
    'Blippi - Educational Videos',
    'Sesame Street',
    'Bluey - Official Channel',
    'Octonauts',
    'Wild Kratts',
    'Cosmic Kids Yoga',
    'Free School',
    'Homeschool Pop',
    'Urdu Rhymes for Children',
    'Kids Learning Tube',
    'Storyline Online',
    'Mystery Science',
    'Netflix Jr.',
    'Nat Geo Wild',
  ];

  /// The long tail of a real child's subscription list: gaming, toys, shorts.
  /// Invented names, built from two word lists so 129 of them stay varied
  /// without a hand-typed wall of text.
  static const _topics = <String>[
    'Minecraft',
    'Roblox',
    'Lego Builds',
    'Dino Facts',
    'Slime Lab',
    'Squishy',
    'Gacha',
    'Pokemon Cards',
    'Hot Wheels',
    'Nerf Battle',
    'Doll House',
    'Paw Patrol Fan',
    'Toy Train',
    'Sandbox',
    'Among Friends',
    'Sonic Speed',
    'Mario Kart',
    'Kitten Cam',
    'Puppy Diary',
    'Space Facts',
    'Volcano Watch',
    'Origami',
    'Magnet Tricks',
    'Marble Run',
    'Rainbow Buddies',
    'Tiny Bakery',
    'Karaoke Kids',
    'Cricket Skills',
    'Football Tricks',
    'Chess Club',
    'Calligraphy',
    'Urdu Stories',
    'Quran for Kids',
    'Hindi Rhymes',
    'Science Lab',
    'Robot Build',
    'Drone Flights',
    'Mystery Box',
    'Prank Squad',
    'Skit Time',
    'Sticker Art',
    'Paper Craft',
    'Bug Hunt',
  ];

  static const _suffixes = <String>[
    'Kids',
    'TV',
    'World',
    'Zone',
    'Club',
    'Adventures',
    'Daily',
    'HQ',
    'Studio',
    'Family',
    'Shorts',
    'Channel',
  ];

  static const _tailCount = 129;

  static List<DemoChannel> _build() {
    final out = <DemoChannel>[];
    for (var i = 0; i < _named.length; i++) {
      final title = _named[i];
      // One real channel that has gone quiet, so `unknown` appears in the list
      // as what it is: too little recent material, not a warning.
      final verdict = title.startsWith('Urdu Rhymes')
          ? ReviewVerdict.unknown
          : ReviewVerdict.good;
      out.add(_channel(i, title, verdict));
    }
    for (var i = 0; i < _tailCount; i++) {
      final topic = _topics[i % _topics.length];
      final title =
          '$topic ${_suffixes[(i ~/ _topics.length) % _suffixes.length]}';
      // Two concerns and roughly one mixed in twelve: a pile a parent can
      // actually work through, with a few things genuinely worth reading.
      // The two concern indices are one odd, one even so the pair does not
      // land on the same summary template.
      final verdict = (i == 38 || i == 81)
          ? ReviewVerdict.concern
          : (i % 12 == 5 ? ReviewVerdict.mixed : ReviewVerdict.good);
      out.add(_channel(_named.length + i, title, verdict, topic: topic));
    }
    return out;
  }

  static DemoChannel _channel(
    int i,
    String title,
    ReviewVerdict verdict, {
    String? topic,
  }) {
    final id = 'ch_${_slug(title)}';
    // The two channels the rest of the demo already uses keep their real
    // thumbnails; everything else renders a lettered stand-in, so the demo
    // looks the same with no network.
    final thumb = switch (id) {
      'ch_supersimplesongskidssongs' =>
        'https://i.ytimg.com/vi/pZw9veQ76fo/hqdefault.jpg',
      'ch_scishowkids' => 'https://i.ytimg.com/vi/0jKoOUZ1GBM/hqdefault.jpg',
      _ => '',
    };
    return DemoChannel(
      id: id,
      title: title,
      thumbUrl: thumb,
      review: ChannelReview(
        channelId: id,
        title: title,
        thumbUrl: thumb,
        verdict: verdict,
        // Stride of 7 over the template lists so neighbouring rows never read
        // the same sentence back to back.
        summary: _pick(_summaries[verdict]!, i),
        flags: _pick(_flags[verdict]!, i),
        goodFor: _pick(_goodFor[verdict]!, i),
        sampleTitles: _samplesFor(verdict, topic, i),
        reviewedAt: _reviewedAt,
        model: 'anthropic.claude-haiku-4-5',
      ),
    );
  }

  static T _pick<T>(List<T> from, int i) => from[(i * 7) % from.length];

  static String _slug(String title) =>
      title.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// One fixed timestamp for the whole demo so nothing shifts mid-screenshot.
  static final String _reviewedAt = DateTime.now()
      .subtract(const Duration(hours: 6))
      .toUtc()
      .toIso8601String();

  static final Map<ReviewVerdict, List<String>> _summaries = {
    ReviewVerdict.good: const [
      'Short episodes built around one idea at a time. Calm pace, no '
          'shouting, and the last month looks like the rest.',
      'Songs and counting aimed at pre-schoolers. Nothing in the recent '
          'uploads looks out of place.',
      'One science question per video, answered with real footage rather '
          'than stock loops.',
      'Draw-along and craft videos, adult-led, with each step shown slowly '
          'enough to follow.',
      'Story readings with the book on screen. Quiet, and much the same '
          'every time.',
      'Animal facts over real wildlife clips. Long shots, plain narration, '
          'nothing startling in the recent uploads.',
      'Build-alongs that show the finished thing at the start, so nobody is '
          'strung along to the end.',
      'Bilingual rhymes, mostly Urdu with the English line repeated. Uploads '
          'are steady and consistent.',
      'Explainers for older children, a few minutes each, and it says so when '
          'something is still uncertain.',
      'Gentle routines and repetition. Samey by design, which is rather the '
          'point at this age.',
    ],
    ReviewVerdict.mixed: const [
      'Most of it is ordinary play, but several recent uploads are long toy '
          'hauls with the brand name in the title.',
      'The videos themselves are unremarkable; the titles and thumbnails are '
          'the part doing the shouting.',
      'Split audience: some uploads are clearly for young children, others '
          'are aimed at teenagers.',
      'Mostly build-alongs, but a run of recent uploads is jump-scare '
          'gameplay with a lot of screaming.',
      'Steady and harmless apart from a sponsored slot in most recent '
          'uploads that is not marked as one.',
    ],
    ReviewVerdict.concern: const [
      'Recent uploads lean on prank setups, shouting and staged arguments, '
          'and several titles promise something the video never shows.',
      'Mystery-box and buy-this uploads fill the last two months, with '
          'shopping links in every description.',
    ],
    ReviewVerdict.unknown: const [
      'Two uploads in the last six months and neither carries a description, '
          'so there is not enough recent material to say what it is like now.',
    ],
  };

  static final Map<ReviewVerdict, List<List<ReviewFlag>>> _flags = {
    ReviewVerdict.good: const [<ReviewFlag>[]],
    ReviewVerdict.mixed: const [
      [
        ReviewFlag(
          kind: 'consumerism',
          note: 'Four of the last ten uploads are unboxings of one toy line.',
        ),
        ReviewFlag(
          kind: 'ads_or_merch',
          note: 'The channel\'s own shop is linked in every description.',
        ),
      ],
      [
        ReviewFlag(
          kind: 'low_quality',
          note: 'Titles in capitals and shock thumbnails over ordinary play.',
        ),
      ],
      [
        ReviewFlag(
          kind: 'off_topic',
          note: 'Recent uploads drift into teen gaming chat.',
        ),
        ReviewFlag(
          kind: 'not_for_kids',
          note: 'Some uploads are not marked as made for children.',
        ),
      ],
      [
        ReviewFlag(
          kind: 'scary',
          note: 'Jump scares and screaming in six recent uploads.',
        ),
      ],
      [
        ReviewFlag(
          kind: 'ads_or_merch',
          note: 'A sponsored segment mid-video, not announced as one.',
        ),
      ],
    ],
    ReviewVerdict.concern: const [
      [
        ReviewFlag(
          kind: 'scary',
          note: 'Prank setups built on frightening someone.',
        ),
        ReviewFlag(
          kind: 'mature_language',
          note: 'Bleeped swearing in several recent uploads.',
        ),
        ReviewFlag(
          kind: 'low_quality',
          note: 'Titles promise an outcome the video does not show.',
        ),
      ],
      [
        ReviewFlag(
          kind: 'consumerism',
          note: 'Almost every upload ends on a buy-this link.',
        ),
        ReviewFlag(
          kind: 'ads_or_merch',
          note: 'Paid promotions are not declared in the video.',
        ),
      ],
    ],
    ReviewVerdict.unknown: const [<ReviewFlag>[]],
  };

  static final Map<ReviewVerdict, List<List<String>>> _goodFor = {
    ReviewVerdict.good: const [
      ['4_6', '7_8', '9_11'],
      ['4_6', '7_8'],
      ['7_8', '9_11'],
    ],
    ReviewVerdict.mixed: const [
      ['9_11'],
      ['7_8', '9_11'],
    ],
    // Nothing named: the screen then says so rather than inventing a band.
    ReviewVerdict.concern: const [<String>[]],
    ReviewVerdict.unknown: const [<String>[]],
  };

  /// The uploads a review was read from. Shown to the parent so the advice can
  /// be checked instead of taken on trust.
  ///
  /// Channels built from a topic get titles about that topic, so a cricket
  /// channel is not evidenced with bedtime stories. The named real channels
  /// fall back to the wholesome sets below.
  static List<String> _samplesFor(ReviewVerdict verdict, String? topic, int i) {
    if (topic == null) return _pick(_namedSamples, i);
    return switch (verdict) {
      ReviewVerdict.good => [
        '$topic for beginners',
        'The $topic question everyone asks',
        'A closer look at $topic',
      ],
      ReviewVerdict.mixed => [
        '$topic haul - everything we bought',
        '$topic challenge with my brother',
        'Ranking every $topic thing out of 10',
      ],
      ReviewVerdict.concern => [
        'We pranked the whole $topic team',
        'HUGE mystery box - you will not believe it',
        'I spent my savings on $topic',
      ],
      // Two, because the summary says two: the evidence has to match.
      ReviewVerdict.unknown => ['$topic update', 'Channel trailer'],
    };
  }

  static const _namedSamples = <List<String>>[
    [
      'Five Little Ducks - counting song',
      'The Wheels on the Bus (slow version)',
      'Twinkle Twinkle Little Star',
    ],
    [
      'Why does the moon change shape?',
      'What is inside a volcano?',
      'How do bees find flowers?',
    ],
    [
      'Draw a friendly dragon step by step',
      'Paper plate jellyfish',
      'How to fold a paper crane',
    ],
    [
      'I built a whole village in survival mode',
      'Ranking every block in the game',
      'Building a bridge that actually works',
    ],
    [
      'HUGE mystery box - what is inside?!',
      'We bought everything on the shelf',
      'Rating 20 slimes out of 10',
    ],
    [
      'Reading: The Very Hungry Caterpillar',
      'Bedtime story - The Snowy Day',
      'A poem about the sea',
    ],
  ];
}
