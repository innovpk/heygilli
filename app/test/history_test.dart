import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/takeout_slim.dart';
import 'package:heygilli/features/parent/history_screen.dart';
import 'package:heygilli/features/parent/takeout_import_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Watch history (PROTOCOL "Watch history: opt-in, aggregate, discarded").
///
/// The tests that matter most here are the ones about what does *not* leave
/// the phone. History goes only when a parent ticked the box for that one
/// import, search history never goes at all, and both of those are decided on
/// the device before the network is involved.
File _zip(Directory dir, Map<String, String> members) {
  final archive = Archive();
  members.forEach((path, body) {
    archive.addFile(ArchiveFile.string(path, body));
  });
  return File('${dir.path}/takeout.zip')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}

const _csv = 'Channel ID,Channel URL,Channel title\nUC1,http://x,Danny Go!\n';

const _export = {
  'Takeout/YouTube and YouTube Music/children/Abu/subscriptions.csv': _csv,
  'Takeout/YouTube and YouTube Music/children/Abu/watch-history.html':
      '<html>every video the child watched</html>',
  'Takeout/YouTube and YouTube Music/children/Abu/search-history.html':
      '<html>every search the child made</html>',
};

void main() {
  group('what leaves the phone', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('heygilli_history'));
    tearDown(() => tmp.deleteSync(recursive: true));

    List<String> namesIn(File f) => [
      for (final m in ZipDecoder().decodeStream(InputFileStream(f.path)).files)
        m.name,
    ];

    test('history stays on the phone unless it was asked for', () async {
      final slim = await slimTakeout(_zip(tmp, _export), workDir: tmp);

      expect(namesIn(slim.file), hasLength(1));
      expect(namesIn(slim.file).single, endsWith('subscriptions.csv'));
      expect(slim.history, 0);
    });

    test('the tick is the only thing that adds the watch history', () async {
      final slim = await slimTakeout(
        _zip(tmp, _export),
        workDir: tmp,
        includeHistory: true,
      );

      expect(slim.kept, 1, reason: 'the subscription list still goes');
      expect(slim.history, 1);
      expect(
        namesIn(slim.file).any((n) => n.endsWith('watch-history.html')),
        isTrue,
      );
    });

    test('search history never goes, ticked or not', () async {
      final slim = await slimTakeout(
        _zip(tmp, _export),
        workDir: tmp,
        includeHistory: true,
      );

      // There is no opt-in for this one anywhere in the product. A child's
      // searches are their own.
      expect(
        namesIn(slim.file).any((n) => n.contains('search-history')),
        isFalse,
      );
      expect(isWatchHistory('children/Abu/search-history.html'), isFalse);
      expect(slim.skipped, 1);
    });

    test('a zip of history with no channel lists is refused', () async {
      final src = _zip(tmp, {
        'Takeout/YouTube and YouTube Music/children/Abu/watch-history.html':
            '<html>x</html>',
      });

      // Uploading the sensitive half on its own is not an import of anything.
      expect(
        () => slimTakeout(src, workDir: tmp, includeHistory: true),
        throwsA(isA<NotATakeoutExport>()),
      );
    });

    test('a member walking out of its own tree is not history either', () {
      expect(isWatchHistory('../../etc/watch-history.html'), isFalse);
      expect(isWatchHistory('children/Abu/watch-history.html'), isTrue);
    });
  });

  group('HistoryInsight wire type', () {
    test('a short by_hour is padded so a chart cannot read past the end', () {
      final h = HistoryInsight.fromJson({
        'kid_id': 'kid_1',
        'by_hour': [3, 4, 5],
      });

      expect(h.byHour, hasLength(24));
      expect(h.byHour.sublist(3), everyElement(0));
      expect(h.busiestHour, 2);
    });

    test('an over-long by_hour is trimmed rather than trusted', () {
      final h = HistoryInsight.fromJson({
        'kid_id': 'kid_1',
        'by_hour': List<int>.filled(30, 1),
      });

      expect(h.byHour, hasLength(24));
    });

    test('a share outside 0-1 cannot render an impossible percentage', () {
      expect(
        HistoryInsight.fromJson({
          'kid_id': 'k',
          'unsubscribed_share': 1.04,
        }).unsubscribedPercent,
        100,
      );
      expect(
        HistoryInsight.fromJson({
          'kid_id': 'k',
          'unsubscribed_share': -0.2,
        }).unsubscribedPercent,
        0,
      );
    });

    test('an empty history has no busiest hour to invent', () {
      const h = HistoryInsight(kidId: 'k');
      expect(h.hasHours, isFalse);
      expect(h.busiestHour, isNull);
    });

    test('the two shares are the whole of it', () {
      final h = HistoryInsight.fromJson({
        'kid_id': 'k',
        'unsubscribed_share': 0.62,
      });
      expect(h.unsubscribedPercent, 62);
      expect(h.subscribedPercent, 38);
    });
  });

  group('the opt-in box', () {
    late FakeGateway gateway;
    late AppState app;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
    });

    Widget host() => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const MaterialApp(home: TakeoutImportScreen()),
    );

    /// A tall surface: the intro is several cards and the demo button sits
    /// under all of them.
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      await tester.pump();
    }

    testWidgets('it is off when the screen opens', (tester) async {
      await open(tester);

      final box = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(
        box.value,
        isFalse,
        reason: 'history must be opt-in, never opt-out',
      );
      expect(gateway.historyWasIncluded, isFalse);
    });

    testWidgets('the box says which file goes and what survives it', (
      tester,
    ) async {
      await open(tester);

      // Named, not implied: a parent should be able to check the claim.
      expect(find.textContaining('watch-history.html'), findsOneWidget);
      expect(
        find.textContaining('deletes the file and every video title'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Search history is never sent'),
        findsOneWidget,
      );
    });

    testWidgets('ticking it is the only thing that changes it', (tester) async {
      await open(tester);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    });

    // The import itself is not driven from here: picking a file is real I/O
    // and a widget test's clock never reaches it. What the tick does to an
    // import is asserted directly against the gateway instead.
    test('an import carries no history unless it was asked for', () async {
      await gateway.importTakeout(File('sample-takeout.zip'));
      expect(gateway.historyWasIncluded, isFalse);

      await gateway.importTakeout(
        File('sample-takeout.zip'),
        includeHistory: true,
      );
      expect(gateway.historyWasIncluded, isTrue);
    });

    test('the aggregate lands on the kid the profile was mapped to', () async {
      final kid = (await gateway.kids()).single;
      await gateway.importTakeout(
        File('sample-takeout.zip'),
        includeHistory: true,
      );
      expect(
        gateway.savedHistory(kid.id),
        isNull,
        reason: 'an upload alone says nothing about whose history it is',
      );

      await gateway.importChannels(kid.id, const ['ch_numberblocks']);
      expect(gateway.savedHistory(kid.id), isNotNull);
    });

    test('deleting it also forgets that history was ever offered', () async {
      final kid = (await gateway.kids()).single;
      await gateway.importTakeout(
        File('sample-takeout.zip'),
        includeHistory: true,
      );
      await gateway.importChannels(kid.id, const ['ch_numberblocks']);

      expect(await gateway.deleteHistory(kid.id), isTrue);
      expect(await gateway.history(kid.id), isNull);
      // The next import starts from off again, like every other one.
      expect(gateway.historyWasIncluded, isFalse);
    });
  });

  group('the insight screen', () {
    late FakeGateway gateway;
    late AppState app;
    late Kid kid;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = FakeGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
    });

    Widget host() => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(home: HistoryScreen(kid: kid)),
    );

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('a household that never opted in is told so, not shown zeros', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Nothing here'), findsOneWidget);
      expect(
        find.textContaining('does not unless you ask it to'),
        findsWidgets,
      );
      expect(find.textContaining('%'), findsNothing);
    });

    group('once a parent has opted in', () {
      /// Walk the real route: an export uploaded with history, then a profile
      /// mapped onto this kid, which is when the aggregate lands. Done here
      /// rather than in a test body, because FakeGateway's lag is a real
      /// delay and the clock inside testWidgets never reaches it.
      setUp(() async {
        await gateway.importTakeout(
          File('sample-takeout.zip'),
          includeHistory: true,
        );
        await gateway.importChannels(kid.id, const ['ch_numberblocks']);
      });

      testWidgets('the unsubscribed share is the headline', (tester) async {
        await open(tester);

        final insight = gateway.savedHistory(kid.id)!;
        expect(insight.unsubscribedShare, greaterThan(0));
        expect(find.text('${insight.unsubscribedPercent}%'), findsOneWidget);
        expect(
          find.textContaining('came from channels Abu does not follow'),
          findsOneWidget,
        );
      });

      testWidgets('it says what was kept, and it is not video titles', (
        tester,
      ) async {
        await open(tester);

        expect(find.text('What was kept'), findsOneWidget);
        expect(
          find.textContaining('No video title was stored or sent to a model'),
          findsOneWidget,
        );
      });

      testWidgets('deleting it takes one confirmation and it is gone', (
        tester,
      ) async {
        await open(tester);
        expect(gateway.savedHistory(kid.id), isNotNull);

        await tester.tap(find.text('Delete these counts'));
        await tester.pump();
        await tester.tap(find.text('Delete'));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }

        expect(gateway.savedHistory(kid.id), isNull);
        expect(find.text('Nothing here'), findsOneWidget);
      });

      testWidgets('backing out of the delete keeps it', (tester) async {
        await open(tester);

        await tester.tap(find.text('Delete these counts'));
        await tester.pump();
        await tester.tap(find.text('Keep it'));
        await tester.pump();

        expect(gateway.savedHistory(kid.id), isNotNull);
      });
    });
  });
}
