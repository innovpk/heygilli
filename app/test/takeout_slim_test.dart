import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/takeout_slim.dart';

/// Writes a zip with the given members and returns it as a picked export.
///
/// A path, not bytes: on a phone this is the streaming route, which is the
/// one a real hundreds-of-megabyte export takes.
TakeoutZip _zip(
  Directory dir,
  Map<String, String> members, {
  String name = 'takeout.zip',
}) {
  final archive = Archive();
  members.forEach((path, body) {
    archive.addFile(ArchiveFile.string(path, body));
  });
  File('${dir.path}/$name').writeAsBytesSync(ZipEncoder().encode(archive));
  return TakeoutZip.path(name, '${dir.path}/$name');
}

const _csv = 'Channel ID,Channel URL,Channel title\nUC1,http://x,Danny Go!\n';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('heygilli_slim'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Archive open(SlimTakeout s) =>
      ZipDecoder().decodeStream(InputMemoryStream(s.bytes));

  group('what leaves the phone', () {
    test('watch and search history are not in the uploaded zip', () async {
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
        'Takeout/YouTube and YouTube Music/children/Abu/watch-history.html':
            '<html>every video the child watched</html>',
        'Takeout/YouTube and YouTube Music/children/Abu/search-history.html':
            '<html>every search the child made</html>',
      });

      final slim = await slimTakeout(src);
      final names = open(slim).files.map((f) => f.name).toList();

      expect(names, hasLength(1));
      expect(names.single, endsWith('children/Abu/subscriptions.csv'));
      expect(names.any((n) => n.contains('history')), isFalse);
      expect(slim.kept, 1);
      expect(slim.skipped, 2);
    });

    test('every child profile and the parent list are carried across', () async {
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
        'Takeout/YouTube and YouTube Music/children/Abeeha/subscriptions.csv':
            _csv,
        'Takeout/YouTube and YouTube Music/subscriptions/subscriptions.csv':
            _csv,
        'Takeout/YouTube and YouTube Music/children/Abeeha/watch-history.html':
            'x',
      });

      final slim = await slimTakeout(src);

      expect(slim.kept, 3);
      expect(slim.skipped, 1);
      expect(
        open(slim).files.map((f) => f.name),
        everyElement(endsWith('.csv')),
      );
    });

    test('the CSV contents survive the round trip intact', () async {
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
      });

      final slim = await slimTakeout(src);
      final body = String.fromCharCodes(open(slim).files.single.content);

      expect(body, _csv);
    });

    test('nothing is written to disk on the way out', () async {
      // The slim copy lives in memory and is uploaded from there. A temp file
      // would be a second copy of a family's channel lists left on the
      // device, outliving the import that needed it.
      final before = tmp.listSync().length;
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
      });

      final slim = await slimTakeout(src);

      expect(slim.bytes, isNotEmpty);
      expect(tmp.listSync().length, before + 1, reason: 'only the input zip');
    });

    test('a browser, with no path to stream from, gets the same result', () {
      // On the web the picker has no file path, so the export arrives as
      // bytes. Same export, same slimming, or the privacy promise holds on
      // one platform and not the other.
      final path = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
        'Takeout/YouTube and YouTube Music/children/Abu/watch-history.html':
            '<html>every video the child watched</html>',
      });
      final bytes = TakeoutZip.bytes(
        'takeout.zip',
        File(path.path!).readAsBytesSync(),
      );

      return Future.wait([slimTakeout(path), slimTakeout(bytes)]).then((r) {
        expect(r[1].kept, r[0].kept);
        expect(r[1].skipped, r[0].skipped);
        expect(
          open(r[1]).files.map((f) => f.name),
          open(r[0]).files.map((f) => f.name),
        );
        expect(
          open(r[1]).files.any((f) => f.name.contains('history')),
          isFalse,
        );
      });
    });
  });

  group('what is refused', () {
    test(
      'an export with no subscription lists is refused with advice',
      () async {
        final src = _zip(tmp, {
          'Takeout/YouTube and YouTube Music/history/watch-history.html': 'x',
        });

        expect(
          () => slimTakeout(src),
          throwsA(
            isA<NotATakeoutExport>().having(
              (e) => e.message,
              'message',
              contains('children'),
            ),
          ),
        );
      },
    );

    test('a file that is not a zip is refused, not crashed on', () async {
      File('${tmp.path}/notes.txt').writeAsStringSync('hello');
      final notZip = TakeoutZip.path('notes.txt', '${tmp.path}/notes.txt');

      expect(
        () => slimTakeout(notZip),
        throwsA(isA<NotATakeoutExport>()),
      );
    });
  });

  group('member filter', () {
    test('accepts a subscriptions.csv at any depth', () {
      expect(isSubscriptionCsv('a/b/c/subscriptions.csv'), isTrue);
      expect(isSubscriptionCsv('subscriptions.csv'), isTrue);
      expect(isSubscriptionCsv('A/SUBSCRIPTIONS.CSV'), isTrue);
    });

    test('rejects history and anything else', () {
      expect(isSubscriptionCsv('children/Abu/watch-history.html'), isFalse);
      expect(isSubscriptionCsv('children/Abu/search-history.html'), isFalse);
      expect(isSubscriptionCsv('subscriptions.csv.html'), isFalse);
      expect(isSubscriptionCsv('playlists.csv'), isFalse);
    });

    test('refuses a member that tries to walk out of its own tree', () {
      expect(isSubscriptionCsv('../../etc/subscriptions.csv'), isFalse);
      expect(isSubscriptionCsv('a/../../subscriptions.csv'), isFalse);
    });
  });
}
