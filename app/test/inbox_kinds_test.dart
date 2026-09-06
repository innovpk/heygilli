import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/models.dart';

/// The inbox now carries two kinds of thing, and this file is the seam between
/// the two sides of the product.
///
/// The payloads below were taken from the running gateway — `ParentPrompt`
/// serialised by `heygilli_agents.schemas` — not written by hand to match the
/// parser. A drift entry that the client silently renders as a blank card, or
/// worse offers Approve and Hide on, is exactly what this catches: both sides
/// pass their own tests while the seam between them is broken.
void main() {
  // As emitted by the gateway for a channel that is no longer what it was.
  final driftJson = {
    'id': 'pp_de28c447d004',
    'kid_id': 'k1',
    'kind': 'channel_drift',
    'video': null,
    'drift': {
      'channel_id': 'UCx',
      'title': 'Toy Land',
      'was': {'verdict': 'good', 'flags': [], 'reviewed_at': ''},
      'now': {'verdict': 'concern', 'flags': [], 'reviewed_at': ''},
      'worse': true,
      'what_changed': 'Now mostly paid toy promotions.',
      'sample_titles': ['Unboxing 50 toys'],
    },
    'reason': 'This channel is not what it was.',
    'created_at': '2026-09-06T02:17:03+00:00',
  };

  final videoJson = {
    'id': 'pp_1',
    'kid_id': 'k1',
    'kind': 'video',
    'video': {
      'id': 'v1',
      'channel_id': 'UCx',
      'title': 'Every Kind of Volcano',
      'duration_s': 480,
    },
    'drift': null,
    'reason': 'Could not settle this one alone.',
    'created_at': '2026-09-06T02:17:03+00:00',
  };

  test('a drift entry arrives whole, with the channel it is about', () {
    final p = ParentPrompt.fromJson(driftJson);
    expect(p.kind, PromptKind.channelDrift);
    expect(p.video, isNull);
    expect(p.drift, isNotNull);
    expect(p.subject, 'Toy Land', reason: 'the card would have had no name');
    expect(p.drift!.whatChanged, 'Now mostly paid toy promotions.');
    expect(p.drift!.worse, isTrue);
    expect(p.drift!.was.verdict, ReviewVerdict.good);
    expect(p.drift!.now.verdict, ReviewVerdict.concern);
  });

  test('a drift is not something to approve or hide', () {
    // Approve and Hide are about one video. Offering them here would let a
    // parent think they had dealt with the channel when nothing had changed.
    expect(ParentPrompt.fromJson(driftJson).isDecidable, isFalse);
  });

  test('a video entry still parses and is still decidable', () {
    final p = ParentPrompt.fromJson(videoJson);
    expect(p.kind, PromptKind.video);
    expect(p.subject, 'Every Kind of Volcano');
    expect(p.isDecidable, isTrue);
  });

  test('a gateway that predates kinds still means "video"', () {
    // The field was added after the endpoint shipped, so its absence is not a
    // broken payload — it is the original shape, and it is a video.
    final old = Map<String, dynamic>.from(videoJson)..remove('kind');
    final p = ParentPrompt.fromJson(old);
    expect(p.kind, PromptKind.video);
    expect(p.isDecidable, isTrue);
  });

  test('a kind this build has never heard of still reaches the parent', () {
    // A newer gateway must not be able to make an entry disappear. It is
    // shown, and it offers no buttons, because this build does not know what
    // deciding on it would do.
    final future = Map<String, dynamic>.from(driftJson)
      ..['kind'] = 'something_new';
    final p = ParentPrompt.fromJson(future);
    expect(p.kind, PromptKind.unknown);
    expect(p.isDecidable, isFalse);
    expect(p.reason, isNotEmpty);
  });

  test('an entry with nothing to name it still has something to show', () {
    final bare = {
      'id': 'pp_2',
      'kid_id': 'k1',
      'kind': 'channel_drift',
      'reason': 'Something changed.',
    };
    expect(ParentPrompt.fromJson(bare).subject, isNotEmpty);
  });

  test('both kinds survive a round trip', () {
    for (final j in [driftJson, videoJson]) {
      final back = ParentPrompt.fromJson(ParentPrompt.fromJson(j).toJson());
      expect(back.kind, ParentPrompt.fromJson(j).kind);
      expect(back.subject, ParentPrompt.fromJson(j).subject);
    }
  });
}
