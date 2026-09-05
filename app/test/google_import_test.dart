import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/google_auth.dart';
import 'package:heygilli/core/models.dart';

/// PROTOCOL "Google sign-in and subscription import": payload shapes, the
/// "already approved" rule, and the path where no Google client id exists.
void main() {
  group('Session (POST /auth/google)', () {
    test('parses the full session', () {
      final s = Session.fromJson({
        'token': 'tok_abc',
        'household_id': 'hh_1',
        'email': 'asma@example.com',
        'youtube_linked': true,
      });
      expect(s.token, 'tok_abc');
      expect(s.householdId, 'hh_1');
      expect(s.email, 'asma@example.com');
      expect(s.youtubeLinked, isTrue);
    });

    test('a dev session without Google is not linked', () {
      final s = Session.fromJson({'token': 't', 'household_id': 1});
      expect(s.householdId, '1');
      expect(s.email, isEmpty);
      expect(s.youtubeLinked, isFalse);
    });
  });

  group('YouTubeStatus (GET /me/youtube)', () {
    test('linked false is a normal answer, not an error', () {
      final st = YouTubeStatus.fromJson({'linked': false});
      expect(st.linked, isFalse);
      expect(st.email, isEmpty);
    });
  });

  group('Subscription and SubscriptionList', () {
    test('parses a subscription and the kids it is approved for', () {
      final s = Subscription.fromJson({
        'channel_id': 'ch_ssk',
        'title': 'SciShow Kids',
        'thumb_url': 'https://example.test/ssk.jpg',
        'approved_for': ['kid_zara'],
      });
      expect(s.channelId, 'ch_ssk');
      expect(s.title, 'SciShow Kids');
      expect(s.thumbUrl, 'https://example.test/ssk.jpg');
      expect(s.isApprovedFor('kid_zara'), isTrue);
      expect(s.isApprovedFor('kid_ayaan'), isFalse);
    });

    test('a subscription approved for nobody is selectable for every kid', () {
      final s = Subscription.fromJson({'channel_id': 'ch_x', 'title': 'X'});
      expect(s.approvedFor, isEmpty);
      expect(s.isApprovedFor('kid_zara'), isFalse);
    });

    test('linked false comes with an empty list', () {
      final l = SubscriptionList.fromJson({'linked': false});
      expect(l.linked, isFalse);
      expect(l.subscriptions, isEmpty);
    });

    test('parses a linked list', () {
      final l = SubscriptionList.fromJson({
        'linked': true,
        'subscriptions': [
          {'channel_id': 'ch_a', 'title': 'A'},
          {
            'channel_id': 'ch_b',
            'title': 'B',
            'approved_for': ['kid_zara'],
          },
        ],
      });
      expect(l.linked, isTrue);
      expect(l.subscriptions, hasLength(2));
      expect(l.subscriptions[1].isApprovedFor('kid_zara'), isTrue);
    });
  });

  group('ImportResult (POST /kids/{id}/channels/import)', () {
    test('splits what was added from what was already there', () {
      final r = ImportResult.fromJson({
        'added': [
          {'id': 'ch_a', 'title': 'A', 'approved': true},
        ],
        'already': ['ch_b', 'ch_c'],
      });
      expect(r.added.single.id, 'ch_a');
      expect(r.added.single.approved, isTrue);
      expect(r.already, ['ch_b', 'ch_c']);
    });

    test('accepts channel objects in "already" as well as bare ids', () {
      final r = ImportResult.fromJson({
        'already': [
          {'channel_id': 'ch_b'},
          {'id': 'ch_c'},
        ],
      });
      expect(r.already, ['ch_b', 'ch_c']);
      expect(r.added, isEmpty);
    });

    test('an empty body is an empty result, not a crash', () {
      final r = ImportResult.fromJson({});
      expect(r.added, isEmpty);
      expect(r.already, isEmpty);
    });
  });

  group('FakeGateway import flow', () {
    test('no subscriptions until the household is linked to Google', () async {
      final g = FakeGateway();
      final before = await g.youtubeSubscriptions();
      expect(before.linked, isFalse);
      expect(before.subscriptions, isEmpty);
      expect((await g.youtubeStatus()).linked, isFalse);

      final session = await g.signInWithGoogle('any_code');
      expect(session.youtubeLinked, isTrue);
      expect(g.signedIn, isTrue);

      final after = await g.youtubeSubscriptions();
      expect(after.linked, isTrue);
      expect(after.subscriptions.length, greaterThan(10));
    });

    test(
      'channels a kid already has are marked approved for that kid',
      () async {
        final g = FakeGateway();
        await g.signInWithGoogle('any_code');
        final subs = (await g.youtubeSubscriptions()).subscriptions;

        final existing = await g.channels('kid_zara');
        for (final c in existing) {
          final s = subs.firstWhere((s) => s.channelId == c.id);
          expect(
            s.isApprovedFor('kid_zara'),
            isTrue,
            reason: '${c.title} is already on the younger kid\'s list',
          );
        }
        // And at least one is not, or there is nothing to import.
        expect(subs.any((s) => !s.isApprovedFor('kid_zara')), isTrue);
      },
    );

    test(
      'importing adds the channels and reports the ones already there',
      () async {
        final g = FakeGateway();
        await g.signInWithGoogle('any_code');
        final subs = (await g.youtubeSubscriptions()).subscriptions;
        final fresh = subs
            .where((s) => !s.isApprovedFor('kid_zara'))
            .take(3)
            .map((s) => s.channelId)
            .toList();
        final beforeCount = (await g.channels('kid_zara')).length;

        final first = await g.importChannels('kid_zara', fresh);
        expect(first.added.map((c) => c.id), fresh);
        expect(first.already, isEmpty);
        expect((await g.channels('kid_zara')).length, beforeCount + 3);
        expect(first.added.every((c) => c.approved), isTrue);

        // Importing the same ids again adds nothing and says so.
        final second = await g.importChannels('kid_zara', fresh);
        expect(second.added, isEmpty);
        expect(second.already, fresh);
        expect((await g.channels('kid_zara')).length, beforeCount + 3);

        // The list now shows them as approved for one kid but not the other.
        final after = (await g.youtubeSubscriptions()).subscriptions;
        for (final id in fresh) {
          final s = after.firstWhere((s) => s.channelId == id);
          expect(s.isApprovedFor('kid_zara'), isTrue);
          expect(s.isApprovedFor('kid_ayaan'), isFalse);
        }
      },
    );

    test('one kid\'s import never touches another kid', () async {
      final g = FakeGateway();
      await g.signInWithGoogle('any_code');
      final ayaanBefore = (await g.channels('kid_ayaan')).length;
      final id = (await g.youtubeSubscriptions()).subscriptions
          .firstWhere((s) => !s.isApprovedFor('kid_zara'))
          .channelId;
      await g.importChannels('kid_zara', [id]);
      expect((await g.channels('kid_ayaan')).length, ayaanBefore);
    });
  });

  group('GoogleAuth without credentials', () {
    test('an empty server client id is "not configured"', () async {
      final auth = GoogleAuth(serverClientId: '');
      expect(auth.isConfigured, isFalse);
      // Returns a typed result instead of reaching for a plugin that would
      // throw MissingPluginException in a test binding.
      final result = await auth.signIn();
      expect(result, isA<GoogleAuthNotConfigured>());
      expect((result as GoogleAuthNotConfigured).reason, isNotEmpty);
    });

    test('a server client id makes it configured', () {
      expect(
        GoogleAuth(
          serverClientId: '123.apps.googleusercontent.com',
        ).isConfigured,
        isTrue,
      );
    });

    test('the scope asked for is exactly youtube.readonly', () {
      expect(
        GoogleAuth.youtubeReadonlyScope,
        'https://www.googleapis.com/auth/youtube.readonly',
      );
    });
  });
}
