import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/models.dart';

void main() {
  group('age → band (SPEC 3)', () {
    test('4 to 6 is the pre-reader band', () {
      for (final age in [4, 5, 6]) {
        expect(AgeBand.forAge(age), AgeBand.b4to6, reason: 'age $age');
      }
    });

    test('7 to 8 is the early-reader band', () {
      for (final age in [7, 8]) {
        expect(AgeBand.forAge(age), AgeBand.b7to8, reason: 'age $age');
      }
    });

    test('9 to 11 is the fluent band', () {
      for (final age in [9, 10, 11]) {
        expect(AgeBand.forAge(age), AgeBand.b9to11, reason: 'age $age');
      }
    });

    test('out-of-range ages clamp instead of crashing', () {
      expect(AgeBand.forAge(3), AgeBand.b4to6);
      expect(AgeBand.forAge(12), AgeBand.b9to11);
    });

    test('wire names round-trip', () {
      for (final b in AgeBand.values) {
        expect(AgeBand.fromWire(b.wire), b);
      }
      expect(AgeBand.b4to6.wire, '4_6');
      expect(AgeBand.b7to8.wire, '7_8');
      expect(AgeBand.b9to11.wire, '9_11');
    });
  });

  group('does the band show text (SPEC 5.1, 6.2, 6.3)', () {
    test('pre-readers never see question text or titles', () {
      expect(AgeBand.b4to6.showsQuestionText, isFalse);
      expect(AgeBand.b4to6.showsVideoTitles, isFalse);
      expect(AgeBand.b4to6.questionTextSize, 0);
    });

    test('7 to 8 sees large text, 9 to 11 normal text', () {
      expect(AgeBand.b7to8.showsQuestionText, isTrue);
      expect(AgeBand.b9to11.showsQuestionText, isTrue);
      expect(
        AgeBand.b7to8.questionTextSize,
        greaterThan(AgeBand.b9to11.questionTextSize),
      );
    });

    test('only pre-readers auto-listen, and every band gets time to think', () {
      expect(AgeBand.b4to6.autoListens, isTrue);
      expect(AgeBand.b7to8.autoListens, isFalse);
      // The window is measured from the moment Gilli stops speaking, and it
      // was 5 and 8 seconds — long enough to say an answer you already had,
      // not long enough to think of one. The video resumed mid-thought.
      for (final band in AgeBand.values) {
        expect(
          band.defaultListenMs,
          inInclusiveRange(15000, 20000),
          reason: '$band is cut off before a child has answered',
        );
      }
      expect(AgeBand.b4to6.defaultListenMs, 15000);
      expect(AgeBand.b9to11.defaultListenMs, 20000);
    });
  });

  group('Kid.fromJson', () {
    test('uses age_band from the server when present', () {
      final k = Kid.fromJson({
        'id': 'k1',
        'nickname': 'Younger',
        'age': 4,
        'age_band': '4_6',
        'languages': ['en', 'ur'],
      });
      expect(k.band, AgeBand.b4to6);
      expect(k.speaksUrdu, isTrue);
    });

    test('derives the band from age when the server omits it', () {
      final k = Kid.fromJson({'id': 'k2', 'nickname': 'Older', 'age': 9});
      expect(k.band, AgeBand.b9to11);
      expect(k.languages, ['en']);
    });
  });

  test('Digest kind picks the card shape', () {
    final pre = Digest.fromJson({'kid_id': 'k', 'kind': 'prereader'});
    final older = Digest.fromJson({'kid_id': 'k', 'kind': 'older'});
    expect(pre.isPreReader, isTrue);
    expect(older.isPreReader, isFalse);
  });

  test('Video falls back to the public YouTube thumbnail', () {
    final v = Video.fromJson({'id': 'pZw9veQ76fo', 'title': 'Ducks'});
    expect(v.thumb, 'https://i.ytimg.com/vi/pZw9veQ76fo/hqdefault.jpg');
  });
}
