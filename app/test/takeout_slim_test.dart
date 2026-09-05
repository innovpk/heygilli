import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/takeout_slim.dart';

/// Writes a zip with the given members and returns it.
File _zip(
  Directory dir,
  Map<String, String> members, {
  String name = 'takeout.zip',
}) {
  final archive = Archive();
  members.forEach((path, body) {
    archive.addFile(ArchiveFile.string(path, body));
  });
  final f = File('${dir.path}/$name')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
  return f;
}

const _csv = 'Channel ID,Channel URL,Channel title\nUC1,http://x,Danny Go!\n';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('heygilli_slim'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Archive open(File f) => ZipDecoder().decodeStream(InputFileStream(f.path));

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

      final slim = await slimTakeout(src, workDir: tmp);
      final names = open(slim.file).files.map((f) => f.name).toList();

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

      final slim = await slimTakeout(src, workDir: tmp);

      expect(slim.kept, 3);
      expect(slim.skipped, 1);
      expect(
        open(slim.file).files.map((f) => f.name),
        everyElement(endsWith('.csv')),
      );
    });

    test('the CSV contents survive the round trip intact', () async {
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
      });

      final slim = await slimTakeout(src, workDir: tmp);
      final body = String.fromCharCodes(open(slim.file).files.single.content);

      expect(body, _csv);
    });

    test('the slim copy is a different file from the one picked', () async {
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv':
            _csv,
      });

      final slim = await slimTakeout(src, workDir: tmp);

      expect(slim.file.path, isNot(src.path));
      expect(slim.file.existsSync(), isTrue);
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
          () => slimTakeout(src, workDir: tmp),
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
      final notZip = File('${tmp.path}/notes.txt')..writeAsStringSync('hello');

      expect(
        () => slimTakeout(notZip, workDir: tmp),
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
