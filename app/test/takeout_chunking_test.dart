import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/takeout_import_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A big household's import, which used to be one request.
///
/// 148 subscriptions in a single call ran the better part of a minute and came
/// back "Failed to fetch" with nothing to show for it — every channel lost, and
/// the only offer was to do the whole thing again.
void main() {
  late _RecordingGateway gateway;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _RecordingGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    await gateway.createKid(
      nickname: 'Abeeha',
      age: 6,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Widget host() => ChangeNotifierProvider<AppState>.value(
    value: app,
    child: const MaterialApp(home: TakeoutImportScreen()),
  );

  Future<void> openBigExport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(find.text('Use a sample export (demo)'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> tapImport(WidgetTester tester) async {
    // Inside the FilledButton: the screen's own "Import subscriptions"
    // subtitle also contains the word, and it is first in the tree.
    final button = find.descendant(
      of: find.byType(FilledButton),
      matching: find.textContaining(
        RegExp(r'(Import \d+|import \d+|Try again)'),
      ),
    );
    expect(button, findsOneWidget, reason: 'no import button on the card');
    await tester.ensureVisible(button);
    await tester.tap(button);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('148 channels go in batches, not in one request', (tester) async {
    await openBigExport(tester);
    await tapImport(tester);

    expect(gateway.batches.length, greaterThan(1), reason: 'still one request');
    expect(
      gateway.batches.map((b) => b.length).reduce((a, b) => a > b ? a : b),
      lessThanOrEqualTo(25),
    );
    expect(
      gateway.batches.expand((b) => b).length,
      148,
      reason: 'a channel was dropped between batches',
    );
  });

  testWidgets('the profile rides on the last batch only', (tester) async {
    // Attaching the history aggregate reads what the child follows, so it has
    // to happen once, after every channel is approved.
    await openBigExport(tester);
    await tapImport(tester);

    expect(gateway.profiles.where((p) => p.isNotEmpty).length, 1);
    expect(gateway.profiles.last, isNotEmpty);
  });

  testWidgets('a failure part way keeps what already landed', (tester) async {
    gateway.failFromBatch = 3;
    await openBigExport(tester);
    await tapImport(tester);

    expect(find.textContaining('of 148'), findsOneWidget);
    expect(
      find.textContaining('Try again for the last'),
      findsOneWidget,
      reason: 'the only offer was to redo the whole profile',
    );
  });

  testWidgets('trying again resumes rather than starting over', (tester) async {
    gateway.failFromBatch = 3;
    await openBigExport(tester);
    await tapImport(tester);

    // Batches 1 and 2 landed; batch 3 threw, so 50 channels are in.
    final landed = gateway.batches.take(2).expand((b) => b).toSet();
    expect(landed.length, 50);

    gateway.batches.clear();
    gateway.failFromBatch = null;
    await tapImport(tester);

    final resent = gateway.batches.expand((b) => b).toList();
    expect(
      resent.toSet().intersection(landed),
      isEmpty,
      reason: 'the retry sent channels that were already in',
    );
    expect(resent.length, 98, reason: 'the rest of the profile was not sent');
    expect(find.textContaining('added to Abeeha'), findsOneWidget);
  });
}

/// FakeGateway that reports a 148-channel profile and records how the import
/// was actually sent.
class _RecordingGateway extends FakeGateway {
  final List<List<String>> batches = [];
  final List<String> profiles = [];

  /// 1-based index of the first batch that should fail, or null for none.
  int? failFromBatch;

  @override
  Future<TakeoutPreview> importTakeout(
    Uint8List zipBytes,
    String filename, {
    bool includeHistory = false,
  }) async => TakeoutPreview(
    profiles: [
      TakeoutProfile(
        name: 'Abeeha',
        channelCount: 148,
        channels: [
          for (var i = 0; i < 148; i++)
            TakeoutChannel(
              channelId: 'UC${i.toString().padLeft(22, '0')}',
              title: 'Channel $i',
            ),
        ],
      ),
    ],
  );

  @override
  Future<ImportResult> importChannels(
    String kidId,
    List<String> channelIds, {
    String profile = '',
    List<String> topics = const [],
  }) async {
    batches.add(List.of(channelIds));
    profiles.add(profile);
    if (failFromBatch != null && batches.length >= failFromBatch!) {
      throw Exception('Failed to fetch');
    }
    return ImportResult(
      added: [
        for (final id in channelIds)
          Channel(id: id, title: id, thumbUrl: '', approved: true),
      ],
    );
  }
}
