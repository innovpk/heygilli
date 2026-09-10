import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/channel_reviews.dart';
import 'package:heygilli/core/demo_catalogue.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';

/// PROTOCOL "Channel reviews": the payload, the filter and sort a parent sees,
/// the cached-plus-pending poll, and remove-with-undo.
Channel _channel(String id, [String? title]) =>
    Channel(id: id, title: title ?? id, thumbUrl: '', approved: true);

ChannelReview _review(String id, ReviewVerdict verdict, {String? title}) =>
    ChannelReview(
      channelId: id,
      title: title ?? id,
      verdict: verdict,
      summary: 'summary of $id',
    );

void main() {
  group('ChannelReview payload', () {
    test('parses the full shape', () {
      final review = ChannelReview.fromJson({
        'channel_id': 'ch_a',
        'title': 'A Channel',
        'thumb_url': 'https://example.test/a.jpg',
        'verdict': 'mixed',
        'summary': 'Mostly fine, some long toy hauls.',
        'flags': [
          {
            'kind': 'consumerism',
            'note': 'Four of the last ten are unboxings.',
          },
          {'kind': 'ads_or_merch', 'note': 'Shop linked in every description.'},
        ],
        'good_for': ['7_8', '9_11'],
        'sample_titles': ['One', 'Two'],
        'reviewed_at': '2026-09-06T04:00:00Z',
        'model': 'anthropic.claude-haiku-4-5',
      });

      expect(review.channelId, 'ch_a');
      expect(review.verdict, ReviewVerdict.mixed);
      expect(review.flags.first.kind, 'consumerism');
      expect(review.flags.first.label, 'Buy-me pressure');
      expect(review.suits(AgeBand.b9to11), isTrue);
      expect(review.suits(AgeBand.b4to6), isFalse);
      expect(review.goodForLabel, '7 to 8, 9 to 12');
      expect(review.sampleTitles, ['One', 'Two']);
      expect(review.model, 'anthropic.claude-haiku-4-5');
    });

    test('an unrecognised verdict is unknown, never a guess', () {
      expect(
        ChannelReview.fromJson({
          'channel_id': 'x',
          'verdict': 'suspicious',
        }).verdict,
        ReviewVerdict.unknown,
      );
      expect(
        ChannelReview.fromJson({'channel_id': 'x'}).verdict,
        ReviewVerdict.unknown,
      );
    });

    test('unknown does not count as something to look at', () {
      expect(ReviewVerdict.unknown.needsALook, isFalse);
      expect(ReviewVerdict.good.needsALook, isFalse);
      expect(ReviewVerdict.mixed.needsALook, isTrue);
      expect(ReviewVerdict.concern.needsALook, isTrue);
      // And it reads as "too little to judge", not as a warning.
      expect(ReviewVerdict.unknown.label, 'Not enough yet');
      expect(ReviewVerdict.unknown.blurb, contains('not a warning'));
    });

    test('an unknown flag kind is shown, not dropped', () {
      expect(const ReviewFlag(kind: 'brand_new_kind').label, 'brand new kind');
    });

    test('a batch parses cached reviews and the pending ids together', () {
      final batch = ChannelReviewBatch.fromJson({
        'reviews': [
          {'channel_id': 'ch_a', 'verdict': 'good'},
        ],
        'pending': ['ch_b', 'ch_c'],
      });
      expect(batch.reviews.single.channelId, 'ch_a');
      expect(batch.pending, ['ch_b', 'ch_c']);
    });

    test('an empty answer is an empty batch, not a crash', () {
      final batch = ChannelReviewBatch.fromJson({});
      expect(batch.reviews, isEmpty);
      expect(batch.pending, isEmpty);
    });
  });

  group('Filter and sort', () {
    late ChannelReviewList list;

    setUp(() {
      list = ChannelReviewList(
        channels: [
          _channel('ch_good_z', 'Zebra Facts'),
          _channel('ch_good_a', 'Apple Songs'),
          _channel('ch_mixed', 'Mixed Toys'),
          _channel('ch_concern', 'Prank Squad'),
          _channel('ch_unknown', 'Quiet Channel'),
          _channel('ch_pending', 'Still Reading'),
        ],
      );
      list.apply(
        ChannelReviewBatch(
          reviews: [
            _review('ch_good_z', ReviewVerdict.good),
            _review('ch_good_a', ReviewVerdict.good),
            _review('ch_mixed', ReviewVerdict.mixed),
            _review('ch_concern', ReviewVerdict.concern),
            _review('ch_unknown', ReviewVerdict.unknown),
          ],
          pending: ['ch_pending'],
        ),
      );
    });

    test('anything needing attention floats to the top', () {
      final ids = list.rows().map((r) => r.channel.id).toList();
      expect(ids, [
        'ch_concern', // worth a look first
        'ch_mixed',
        'ch_pending', // still being reviewed, above the settled ones
        'ch_unknown', // not enough to judge: findable, not ranked as a problem
        'ch_good_a', // then good, alphabetically
        'ch_good_z',
      ]);
    });

    test('"Needs a look" is concern and mixed only', () {
      final ids = list
          .rows(ReviewFilter.needsALook)
          .map((r) => r.channel.id)
          .toList();
      expect(ids, ['ch_concern', 'ch_mixed']);
      expect(list.countFor(ReviewFilter.needsALook), 2);
    });

    test('"Good" excludes pending and unknown', () {
      expect(list.rows(ReviewFilter.good).map((r) => r.channel.id), [
        'ch_good_a',
        'ch_good_z',
      ]);
      expect(list.countFor(ReviewFilter.good), 2);
      expect(list.countFor(ReviewFilter.all), 6);
    });

    test('row state tracks what is known about each channel', () {
      final byId = {for (final r in list.rows()) r.channel.id: r};
      expect(byId['ch_good_a']!.state, ReviewRowState.reviewed);
      expect(byId['ch_pending']!.state, ReviewRowState.pending);
      expect(byId['ch_pending']!.review, isNull);
    });
  });

  group('Poll state machine', () {
    test('merges cached reviews with pending and only asks for the rest', () {
      final list = ChannelReviewList(
        channels: [_channel('a'), _channel('b'), _channel('c')],
      );
      expect(list.outstanding, ['a', 'b', 'c']);
      expect(list.reviewedCount, 0);
      expect(list.total, 3);

      // Round one: one cached, two still being reviewed.
      list.apply(
        ChannelReviewBatch(
          reviews: [_review('a', ReviewVerdict.good)],
          pending: ['b', 'c'],
        ),
      );
      expect(list.reviewedCount, 1);
      expect(list.outstanding, ['b', 'c']);
      expect(list.stopped, isFalse);

      // Round two asks only about b and c, and c lands.
      list.apply(
        ChannelReviewBatch(
          reviews: [_review('c', ReviewVerdict.concern)],
          pending: ['b'],
        ),
      );
      expect(list.outstanding, ['b']);
      expect(list.reviewedCount, 2);

      list.apply(
        ChannelReviewBatch(reviews: [_review('b', ReviewVerdict.mixed)]),
      );
      expect(list.outstanding, isEmpty);
      expect(list.complete, isTrue);
      expect(list.stopped, isTrue);
      expect(list.reviewedCount, 3);
    });

    test('a channel the gateway never mentions stops being polled for', () {
      final list = ChannelReviewList(channels: [_channel('a'), _channel('b')]);
      // "b" comes back neither as a review nor as pending: nothing to wait for.
      list.apply(
        ChannelReviewBatch(reviews: [_review('a', ReviewVerdict.good)]),
      );
      expect(list.outstanding, isEmpty);
      expect(list.complete, isTrue);
      final rows = {for (final r in list.rows()) r.channel.id: r};
      expect(rows['b']!.state, ReviewRowState.unavailable);
      // And it is never counted as reviewed.
      expect(list.reviewedCount, 1);
    });

    test('backs off when nothing arrives, and resets when it does', () {
      final list = ChannelReviewList(
        channels: [_channel('a'), _channel('b')],
        firstDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 8),
      );
      expect(list.nextDelay, const Duration(seconds: 1));

      // Quiet round: same request, longer wait.
      list.apply(const ChannelReviewBatch(pending: ['a', 'b']));
      final afterOne = list.nextDelay;
      list.apply(const ChannelReviewBatch(pending: ['a', 'b']));
      final afterTwo = list.nextDelay;
      expect(afterOne, greaterThan(const Duration(seconds: 1)));
      expect(afterTwo, greaterThan(afterOne));
      expect(afterTwo, lessThanOrEqualTo(const Duration(seconds: 8)));

      // A result arrives: back to asking promptly.
      list.apply(
        ChannelReviewBatch(
          reviews: [_review('a', ReviewVerdict.good)],
          pending: ['b'],
        ),
      );
      expect(list.nextDelay, const Duration(seconds: 1));
    });

    test('the delay never exceeds the ceiling', () {
      final list = ChannelReviewList(
        channels: [_channel('a')],
        maxDelay: const Duration(seconds: 5),
        maxQuietRounds: 99,
      );
      for (var i = 0; i < 20; i++) {
        list.apply(const ChannelReviewBatch(pending: ['a']));
      }
      expect(list.nextDelay, const Duration(seconds: 5));
    });

    test('gives up rather than polling a stuck gateway forever', () {
      final list = ChannelReviewList(
        channels: [_channel('a')],
        maxQuietRounds: 3,
      );
      for (var i = 0; i < 3; i++) {
        expect(list.stopped, isFalse);
        list.apply(const ChannelReviewBatch(pending: ['a']));
      }
      expect(list.gaveUp, isTrue);
      expect(list.stopped, isTrue);
      expect(list.complete, isFalse, reason: 'it is unfinished, not done');

      // The parent can ask again.
      list.resume();
      expect(list.stopped, isFalse);
      expect(list.outstanding, ['a']);
    });

    test('a hard round cap stops the loop even while results trickle in', () {
      final list = ChannelReviewList(
        channels: [for (var i = 0; i < 20; i++) _channel('ch_$i')],
        maxRounds: 4,
      );
      for (var i = 0; i < 4; i++) {
        list.apply(
          ChannelReviewBatch(
            reviews: [_review('ch_$i', ReviewVerdict.good)],
            pending: [for (var n = i + 1; n < 20; n++) 'ch_$n'],
          ),
        );
      }
      expect(list.rounds, 4);
      expect(list.gaveUp, isTrue);
      expect(list.reviewedCount, 4);
    });
  });

  group('Remove and undo', () {
    ChannelReviewList seeded() {
      final list = ChannelReviewList(
        channels: [_channel('a', 'A'), _channel('b', 'B'), _channel('c', 'C')],
      );
      list.apply(
        ChannelReviewBatch(
          reviews: [
            _review('a', ReviewVerdict.good, title: 'A'),
            _review('b', ReviewVerdict.concern, title: 'B'),
            _review('c', ReviewVerdict.good, title: 'C'),
          ],
        ),
      );
      return list;
    }

    test('removing drops the row and undo puts it back where it was', () {
      final list = seeded();
      final removal = list.remove('b');
      expect(removal.index, 1);
      expect(list.channels.map((c) => c.id), ['a', 'c']);
      expect(list.total, 2);
      expect(list.rows().map((r) => r.channel.id), ['a', 'c']);

      list.undo(removal);
      expect(list.channels.map((c) => c.id), ['a', 'b', 'c']);
      // The review was kept, so undo does not have to wait for it again.
      expect(list.reviewFor('b')!.verdict, ReviewVerdict.concern);
      expect(list.reviewedCount, 3);
    });

    test('undo twice is not two channels', () {
      final list = seeded();
      final removal = list.remove('a');
      list.undo(removal);
      list.undo(removal);
      expect(list.channels.where((c) => c.id == 'a'), hasLength(1));
    });

    test('removing something still pending stops it being polled for', () {
      final list = ChannelReviewList(channels: [_channel('a'), _channel('b')]);
      list.apply(const ChannelReviewBatch(pending: ['a', 'b']));
      expect(list.outstanding, ['a', 'b']);

      final removal = list.remove('b');
      expect(list.outstanding, ['a']);

      // And undo puts it back on the queue.
      list.undo(removal);
      expect(list.outstanding, ['a', 'b']);
      expect(list.stopped, isFalse);
    });

    test('undo after the last row leaves the list usable', () {
      final list = ChannelReviewList(channels: [_channel('only')]);
      final removal = list.remove('only');
      expect(list.total, 0);
      expect(list.rows(), isEmpty);
      list.undo(removal);
      expect(list.total, 1);
    });
  });

  group('FakeGateway reviews', () {
    test(
      'answers part-cached and finishes 153 in a handful of rounds',
      () async {
        final gateway = FakeGateway();
        final list = ChannelReviewList(
          channels: [for (final c in DemoCatalogue.older) c.toChannel()],
        );
        expect(list.total, 153);

        var rounds = 0;
        while (!list.stopped) {
          list.apply(await gateway.channelReviews(list.outstanding));
          rounds++;
          expect(rounds, lessThan(10), reason: 'the poll should not grind');
        }
        expect(list.reviewedCount, 153);
        // The first answer is already part-filled from the shared cache.
        expect(rounds, inInclusiveRange(2, 6));
      },
    );

    test(
      'the request shrinks every round instead of resending all 153',
      () async {
        final gateway = FakeGateway();
        final list = ChannelReviewList(
          channels: [for (final c in DemoCatalogue.older) c.toChannel()],
        );
        final sizes = <int>[];
        while (!list.stopped) {
          sizes.add(list.outstanding.length);
          list.apply(await gateway.channelReviews(list.outstanding));
        }
        expect(sizes.first, 153);
        for (var i = 1; i < sizes.length; i++) {
          expect(sizes[i], lessThan(sizes[i - 1]));
        }
      },
    );

    test('a single review can be fetched for a row opened early', () async {
      final gateway = FakeGateway();
      final id = DemoCatalogue.all.first.id;
      final review = await gateway.channelReview(id);
      expect(review.channelId, id);
      expect(review.summary, isNotEmpty);
    });

    test('removing takes the channel off that kid', () async {
      final gateway = FakeGateway();
      final ids = [for (final c in DemoCatalogue.younger) c.id];
      await gateway.importChannels('kid_zara', ids);
      expect(await gateway.channels('kid_zara'), hasLength(24));

      await gateway.removeChannel('kid_zara', ids.first);
      final left = await gateway.channels('kid_zara');
      expect(left, hasLength(23));
      expect(left.any((c) => c.id == ids.first), isFalse);

      // Undo is the ordinary one-channel import.
      await gateway.importChannels('kid_zara', [ids.first]);
      expect(await gateway.channels('kid_zara'), hasLength(24));
    });
  });
}
