import 'dart:math' as math;

import 'models.dart';

/// State of one row in the review list.
enum ReviewRowState {
  /// A review came back for this channel.
  reviewed,

  /// Still being reviewed; the row fills in when the next poll answers.
  pending,

  /// The gateway answered about the batch but said nothing about this
  /// channel, so there is nothing to wait for. Shown quietly, not as a fault.
  unavailable,
}

/// One channel the kid has, plus whatever the review said about it.
class ReviewRow {
  const ReviewRow({required this.channel, this.review, required this.state});

  final Channel channel;
  final ChannelReview? review;
  final ReviewRowState state;

  ReviewVerdict? get verdict => review?.verdict;

  /// Sort weight. Anything a parent should look at floats to the top; rows
  /// still being reviewed sit under those, so a result landing mid-poll never
  /// pushes a real finding down the screen. `unknown` sits just above `good`:
  /// easy to find, without being ranked as a problem.
  int get weight => switch (state) {
    ReviewRowState.pending => 2,
    ReviewRowState.unavailable => 3,
    ReviewRowState.reviewed => switch (review!.verdict) {
      ReviewVerdict.concern => 0,
      ReviewVerdict.mixed => 1,
      ReviewVerdict.unknown => 4,
      ReviewVerdict.good => 5,
    },
  };
}

/// The three ways a parent slices the list.
enum ReviewFilter {
  all('All'),
  needsALook('Needs a look'),
  good('Good');

  const ReviewFilter(this.label);

  final String label;

  bool matches(ReviewRow row) => switch (this) {
    ReviewFilter.all => true,
    // `unknown` is not here on purpose: too little to judge is not a warning.
    ReviewFilter.needsALook => row.verdict?.needsALook ?? false,
    ReviewFilter.good => row.verdict == ReviewVerdict.good,
  };
}

/// A removal the parent can still take back.
class ChannelRemoval {
  const ChannelRemoval({required this.channel, required this.index});

  final Channel channel;

  /// Where it sat in the kid's channel list, so undo puts it back rather than
  /// appending it to the end.
  final int index;
}

/// The review list for one kid: which channels the kid has, which reviews have
/// come back, what is still outstanding, and when to ask again.
///
/// Pure state, no timers and no widgets, because the poll loop is the part
/// most likely to go wrong at 153 channels and it should be testable on its
/// own. The screen calls [outstanding], awaits the gateway, calls [apply], and
/// sleeps for [nextDelay] until [stopped].
class ChannelReviewList {
  ChannelReviewList({
    required List<Channel> channels,
    this.firstDelay = const Duration(milliseconds: 1200),
    this.maxDelay = const Duration(seconds: 20),
    this.maxRounds = 30,
    this.maxQuietRounds = 6,
  }) : _channels = List.of(channels),
       _outstanding = [for (final c in channels) c.id];

  /// Delay after a round that made progress.
  final Duration firstDelay;

  /// Ceiling for the backoff, so a stuck gateway is asked about three times a
  /// minute rather than continuously.
  final Duration maxDelay;

  /// Hard stop on the number of requests, whatever happens.
  final int maxRounds;

  /// Stop after this many consecutive rounds that produced no new review.
  final int maxQuietRounds;

  List<Channel> _channels;
  final Map<String, ChannelReview> _reviews = {};
  List<String> _outstanding;
  final Set<String> _unavailable = {};
  int _rounds = 0;
  int _quietRounds = 0;
  bool _gaveUp = false;

  List<Channel> get channels => List.unmodifiable(_channels);

  /// Ids to send on the next `POST /channels/reviews`. Only the ones still
  /// missing: the request shrinks every round instead of re-sending all 153.
  List<String> get outstanding => List.unmodifiable(_outstanding);

  int get total => _channels.length;

  /// Drives "Reviewed 40 of 153".
  int get reviewedCount =>
      _channels.where((c) => _reviews.containsKey(c.id)).length;

  int get rounds => _rounds;

  /// True when the client stopped polling before everything came back.
  bool get gaveUp => _gaveUp;

  /// Nothing left to ask about.
  bool get complete => _outstanding.isEmpty;

  /// Stop the loop: either everything is in, or we have backed off far enough
  /// that asking again on a timer is just noise.
  bool get stopped => complete || _gaveUp;

  ChannelReview? reviewFor(String channelId) => _reviews[channelId];

  /// Merge one answer. Cached reviews and the pending list arrive together,
  /// and both are trusted only about the ids we actually asked for.
  void apply(ChannelReviewBatch batch) {
    _rounds++;
    final asked = _outstanding.toSet();
    final arrived = <String>{};
    for (final review in batch.reviews) {
      // A review for something we did not ask about is still worth keeping;
      // it costs nothing and a later removal-undo may want it.
      if (!_reviews.containsKey(review.channelId)) {
        arrived.add(review.channelId);
      }
      _reviews[review.channelId] = review;
    }
    final stillPending = batch.pending.toSet();
    // Anything we asked about that came back neither as a review nor as
    // pending is not coming: drop it rather than polling for it forever.
    for (final id in asked) {
      if (!_reviews.containsKey(id) && !stillPending.contains(id)) {
        _unavailable.add(id);
      }
    }
    _outstanding = [
      for (final id in _outstanding)
        if (!_reviews.containsKey(id) && stillPending.contains(id)) id,
    ];

    final progressed = arrived.intersection(asked).isNotEmpty;
    _quietRounds = progressed ? 0 : _quietRounds + 1;
    if (_rounds >= maxRounds || _quietRounds >= maxQuietRounds) _gaveUp = true;
  }

  /// How long to wait before the next round. Steady while reviews keep
  /// arriving, and backs off geometrically when they stop.
  Duration get nextDelay {
    final ms = firstDelay.inMilliseconds * math.pow(1.8, _quietRounds);
    return Duration(
      milliseconds: math.min(ms.round(), maxDelay.inMilliseconds),
    );
  }

  /// Let the parent ask again after the loop gave up.
  void resume() {
    if (_outstanding.isEmpty) return;
    _gaveUp = false;
    _rounds = 0;
    _quietRounds = 0;
  }

  /// Rows in display order: attention first, then title.
  List<ReviewRow> rows([ReviewFilter filter = ReviewFilter.all]) {
    final rows = <ReviewRow>[];
    for (final channel in _channels) {
      final review = _reviews[channel.id];
      final state = review != null
          ? ReviewRowState.reviewed
          : (_unavailable.contains(channel.id)
                ? ReviewRowState.unavailable
                : ReviewRowState.pending);
      final row = ReviewRow(channel: channel, review: review, state: state);
      if (filter.matches(row)) rows.add(row);
    }
    rows.sort((a, b) {
      final byWeight = a.weight.compareTo(b.weight);
      if (byWeight != 0) return byWeight;
      return a.channel.title.toLowerCase().compareTo(
        b.channel.title.toLowerCase(),
      );
    });
    return rows;
  }

  /// How many rows each filter would show, for the counts on the filter pills.
  int countFor(ReviewFilter filter) =>
      filter == ReviewFilter.all ? total : rows(filter).length;

  /// Take a channel off the kid. Returns what is needed to put it back.
  ChannelRemoval remove(String channelId) {
    final index = _channels.indexWhere((c) => c.id == channelId);
    final channel = _channels[index];
    _channels = [..._channels]..removeAt(index);
    _outstanding = [
      for (final id in _outstanding)
        if (id != channelId) id,
    ];
    // The review itself is kept: it belongs to the channel, not the kid, so an
    // undo does not have to wait for it again.
    return ChannelRemoval(channel: channel, index: index);
  }

  /// Put a removed channel back where it was.
  void undo(ChannelRemoval removal) {
    if (_channels.any((c) => c.id == removal.channel.id)) return;
    final index = removal.index.clamp(0, _channels.length);
    _channels = [..._channels]..insert(index, removal.channel);
    if (!_reviews.containsKey(removal.channel.id) &&
        !_unavailable.contains(removal.channel.id) &&
        !_outstanding.contains(removal.channel.id)) {
      _outstanding = [..._outstanding, removal.channel.id];
      _gaveUp = false;
    }
  }
}
