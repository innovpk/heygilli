import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/analytics.dart';
import 'package:heygilli/features/parent/progress_charts.dart';

/// A full payload in the exact shape docs/PROTOCOL.md promises.
Map<String, dynamic> _payload() => {
  'kid_id': 'kid_1',
  'band': '4_6',
  'days': 14,
  'generated_at': '2026-09-05T20:00:00+00:00',
  'totals': {
    'minutes': 42,
    'videos': 5,
    'sessions': 4,
    'asked': 9,
    'answered': 6,
    'answer_rate': 0.667,
  },
  'daily': [
    {'date': '2026-09-04', 'minutes': 0, 'videos': 0, 'asked': 0, 'answered': 0},
    {'date': '2026-09-05', 'minutes': 42, 'videos': 5, 'asked': 9, 'answered': 6},
  ],
  'vocabulary': {
    'total_said': 2,
    'new_this_week': 1,
    'said': [
      {'word': 'giraffe', 'times_said': 3, 'first_said': '2026-09-05'},
    ],
    'emerging': [
      {'word': 'hippo', 'times_heard': 4},
    ],
  },
  'concepts': [
    {
      'concept': 'Olympus Mons',
      'asked': 2,
      'understood': 1,
      'shaky': 1,
      'last_seen': '2026-09-05',
    },
  ],
  'needs_another_look': [
    {
      'concept': 'Why the moon changes shape',
      'times_shaky': 4,
      'last_seen': '2026-09-05',
    },
  ],
  'channels': [
    {
      'channel_id': 'UC1',
      'title': 'Super Simple Songs',
      'minutes': 30,
      'videos': 3,
    },
  ],
  'note': {'kind': 'suggestion', 'text': 'Try counting cars on the school run.'},
};

void main() {
  group('Analytics parsing', () {
    test('reads a full payload', () {
      final a = Analytics.fromJson(_payload());

      expect(a.kidId, 'kid_1');
      expect(a.days, 14);
      expect(a.totals.minutes, 42);
      expect(a.totals.answered, 6);
      expect(a.totals.answerRate, closeTo(0.667, 0.001));
      expect(a.daily, hasLength(2));
      expect(a.daily.first.date, '2026-09-04');
      expect(a.vocabulary.said.single.word, 'giraffe');
      expect(a.vocabulary.emerging.single.timesHeard, 4);
      expect(a.concepts.single.concept, 'Olympus Mons');
      expect(a.needsAnotherLook.single.timesShaky, 4);
      expect(a.channels.single.minutes, 30);
      expect(a.note.kind, 'suggestion');
    });

    test('a kid with no history parses to zeros, not an exception', () {
      final a = Analytics.fromJson({'kid_id': 'kid_2', 'band': '9_11'});

      expect(a.totals.sessions, 0);
      expect(a.totals.answerRate, 0);
      expect(a.daily, isEmpty);
      expect(a.vocabulary.said, isEmpty);
      expect(a.concepts, isEmpty);
      expect(a.channels, isEmpty);
    });

    test('missing optional fields inside a list entry do not throw', () {
      final j = _payload();
      j['channels'] = [
        {'channel_id': 'UC2'},
      ];
      final a = Analytics.fromJson(j);

      expect(a.channels.single.minutes, 0);
      expect(a.channels.single.title, isA<String>());
    });
  });

  group('bar geometry', () {
    test('a window where nothing happened renders flat, never NaN', () {
      expect(barFraction(0, 0), 0);
      expect(barFraction(5, 0), 0);
      expect(barFraction(5, double.nan), 0);
    });

    test('a value above the max is clamped into the plot', () {
      expect(barFraction(120, 100), 1);
      expect(barFraction(50, 100), closeTo(0.5, 0.0001));
    });

    test('negative or zero values draw nothing', () {
      expect(barFraction(0, 100), 0);
      expect(barFraction(-4, 100), 0);
    });
  });

  group('bar labels', () {
    test('nothing is labelled when no day has data', () {
      expect(labelledBarIndices(const [0, 0, 0, 0]), isEmpty);
    });

    test('the tallest bar is always labelled', () {
      final kept = labelledBarIndices(const [1, 9, 2, 3, 1, 2, 4]);
      expect(kept, contains(1));
    });

    test('labels closer than the minimum gap are dropped, never collide', () {
      // Tallest at 0 and last-with-data at 1 are adjacent: only one survives.
      final kept = labelledBarIndices(const [9, 4, 0, 0, 0]);
      expect(kept, hasLength(1));
      expect(kept, contains(0));
    });

    test('at most three bars are ever labelled', () {
      final many = List<double>.generate(30, (i) => (i + 1).toDouble());
      expect(labelledBarIndices(many).length, lessThanOrEqualTo(3));
    });
  });

  group('label placement', () {
    test('a label on the first column is not clipped by the card', () {
      expect(labelLeft(0, 300, 60), 0);
    });

    test('a label on the last column is not clipped by the card', () {
      expect(labelLeft(300, 300, 60), 240);
    });

    test('a plot narrower than the label box centres it', () {
      expect(labelLeft(20, 40, 60), -10);
    });
  });
}
