import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/demo_catalogue.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';

/// PROTOCOL "Takeout import": the preview shape, and the demo standing in for
/// a real export at the size a real export actually is.
void main() {
  group('TakeoutPreview (POST /import/takeout)', () {
    test('parses profiles, their channels and the parent block', () {
      final preview = TakeoutPreview.fromJson({
        'profiles': [
          {
            'name': 'Profile 2',
            'channel_count': 2,
            'channels': [
              {
                'channel_id': 'ch_a',
                'title': 'A',
                'url': 'https://youtube.com/channel/ch_a',
              },
              {'channel_id': 'ch_b', 'title': 'B'},
            ],
          },
        ],
        'parent': {
          'channel_count': 1,
          'channels': [
            {'channel_id': 'ch_p', 'title': 'P'},
          ],
        },
      });

      final profileTwo = preview.profiles.single;
      expect(profileTwo.name, 'Profile 2');
      expect(profileTwo.channelCount, 2);
      expect(profileTwo.channelIds, ['ch_a', 'ch_b']);
      expect(profileTwo.channels.first.url, 'https://youtube.com/channel/ch_a');
      // A CSV row with no URL column is still a usable channel.
      expect(profileTwo.channels.last.url, isEmpty);

      // The parent block carries no name: it is not a child profile.
      expect(preview.parent!.name, isEmpty);
      expect(preview.parent!.channelCount, 1);
      expect(preview.isEmpty, isFalse);
    });

    test('an export with no children block is empty, not an error', () {
      final preview = TakeoutPreview.fromJson({'profiles': [], 'parent': null});
      expect(preview.profiles, isEmpty);
      expect(preview.parent, isNull);
      expect(preview.isEmpty, isTrue);
    });

    test('a missing channel_count falls back to what is listed', () {
      final profile = TakeoutProfile.fromJson({
        'name': 'Profile 1',
        'channels': [
          {'channel_id': 'ch_a', 'title': 'A'},
          {'channel_id': 'ch_b', 'title': 'B'},
        ],
      });
      expect(profile.channelCount, 2);
    });

    test('an empty body parses to an empty preview', () {
      expect(TakeoutPreview.fromJson({}).isEmpty, isTrue);
    });
  });

  group('FakeGateway takeout import', () {
    test('the sample export is the size a real one is', () async {
      final gateway = FakeGateway();
      final preview = await gateway.importTakeout(Uint8List(0), 'sample.zip');

      expect(preview.profiles, hasLength(2));
      // The numbers from the export this was built against: one child with a
      // pile nobody would audit by hand, one with a manageable list.
      expect(preview.profiles.first.channelCount, 153);
      expect(preview.profiles.last.channelCount, 24);
      expect(preview.profiles.first.channels, hasLength(153));
      expect(preview.parent, isNotNull);
      expect(preview.parent!.channelCount, greaterThan(0));
    });

    test('importing a profile puts its channels on that kid only', () async {
      final gateway = FakeGateway();
      final preview = await gateway.importTakeout(Uint8List(0), 'sample.zip');
      final profile = preview.profiles.last;

      final result = await gateway.importChannels(
        'kid_zara',
        profile.channelIds,
      );
      expect(result.added, hasLength(24));
      expect(result.already, isEmpty);
      // Takeout ids are not in the parent's own subscription list, so they
      // have to resolve to titles some other way rather than being dropped.
      expect(result.added.every((c) => c.title.isNotEmpty), isTrue);
      expect(result.added.every((c) => c.id != c.title), isTrue);

      expect(await gateway.channels('kid_zara'), hasLength(24));
      expect(await gateway.channels('kid_ayaan'), isEmpty);

      // Importing the same profile twice adds nothing.
      final again = await gateway.importChannels(
        'kid_zara',
        profile.channelIds,
      );
      expect(again.added, isEmpty);
      expect(again.already, hasLength(24));
    });
  });

  group('Demo catalogue', () {
    test('153 channels, with a spread worth reviewing', () {
      final verdicts = <ReviewVerdict, int>{};
      for (final channel in DemoCatalogue.all) {
        verdicts.update(
          channel.review.verdict,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      }
      expect(DemoCatalogue.all, hasLength(153));
      // Mostly good, a few mixed, one or two concern, one unknown.
      expect(verdicts[ReviewVerdict.concern], inInclusiveRange(1, 2));
      expect(verdicts[ReviewVerdict.unknown], 1);
      expect(verdicts[ReviewVerdict.mixed], inInclusiveRange(4, 20));
      expect(
        verdicts[ReviewVerdict.good],
        greaterThan(DemoCatalogue.all.length ~/ 2),
      );
    });

    test('ids are unique, and every review carries its evidence', () {
      final ids = DemoCatalogue.all.map((c) => c.id).toSet();
      expect(ids, hasLength(DemoCatalogue.all.length));
      for (final channel in DemoCatalogue.all) {
        expect(channel.review.channelId, channel.id);
        expect(channel.review.summary, isNotEmpty);
        expect(channel.review.sampleTitles, isNotEmpty);
        // Anything flagged has to say why: a bare label is not advice.
        for (final flag in channel.review.flags) {
          expect(
            flag.note,
            isNotEmpty,
            reason: '${channel.title} ${flag.kind}',
          );
        }
      }
    });

    test('unknown carries no flags: it is not a warning', () {
      final unknown = DemoCatalogue.all
          .map((c) => c.review)
          .where((r) => r.verdict == ReviewVerdict.unknown);
      expect(unknown, isNotEmpty);
      for (final review in unknown) {
        expect(review.flags, isEmpty);
      }
    });
  });
}
