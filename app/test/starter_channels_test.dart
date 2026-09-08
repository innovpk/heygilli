import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/starter_channels_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Somewhere to start, for a household with no channels.
///
/// Setting up meant requesting a Takeout export from Google and waiting for
/// it, or handing over an account before knowing whether you want the thing.
/// A parent who did neither had an empty app.
class _CountingGateway extends FakeGateway {
  final List<String> added = [];
  final List<String> imported = [];
  final List<String> searches = [];
  bool searchFails = false;

  @override
  Future<ImportResult> importChannels(
    String kidId,
    List<String> channelIds, {
    String profile = '',
    List<String> topics = const [],
  }) {
    imported.addAll(channelIds);
    return super.importChannels(
      kidId,
      channelIds,
      profile: profile,
      topics: topics,
    );
  }

  @override
  Future<Channel> addChannel(String kidId, String url) {
    added.add(url);
    return super.addChannel(kidId, url);
  }

  @override
  Future<List<StarterChannel>> searchChannels(String query) async {
    searches.add(query);
    if (searchFails) throw StateError('the daily search limit');
    return super.searchChannels(query);
  }
}

void main() {
  _topicsTravel();

  _search();

  _existingHousehold();

  late AppState app;
  late _CountingGateway gateway;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _CountingGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abeeha',
      age: 5,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: StarterChannelsScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('picking nothing still offers channels for their age', (
    tester,
  ) async {
    await show(tester);
    // "I do not know yet" is the commonest answer during setup and must not
    // be met with a blank screen.
    expect(find.byType(CheckboxListTile), findsWidgets);
    expect(find.text('Danny Go!'), findsOneWidget);
    // Nothing is preselected: arriving here approves nothing.
    final boxes = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(boxes.every((b) => b.value == false), isTrue);
    expect(find.text('Choose at least one'), findsOneWidget);
  });

  testWidgets('a topic narrows the list', (tester) async {
    await show(tester);
    final before = tester.widgetList(find.byType(CheckboxListTile)).length;

    await tester.tap(find.text('Science and how things work'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('SciShow Kids'), findsOneWidget);
    expect(find.text('Danny Go!'), findsNothing);
    expect(tester.widgetList(find.byType(CheckboxListTile)).length, lessThan(before));
  });

  testWidgets('the chosen channels are added, and only those', (tester) async {
    await show(tester);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Danny Go!'));
    await tester.pump();
    expect(find.text('Add 1 channel'), findsOneWidget);

    await tester.tap(find.text('Add 1 channel'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(gateway.imported, ['UC3wCAOfSB0W9iuKDDtNJeGw']);
  });

  testWidgets('select all is a toggle, not a trap', (tester) async {
    await show(tester);
    final total = tester.widgetList(find.byType(CheckboxListTile)).length;

    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('Add $total channels'), findsOneWidget);

    // A parent who ticked everything by accident needs one tap back, not one
    // per channel.
    await tester.tap(find.text('Clear all'));
    await tester.pump();
    expect(find.text('Choose at least one'), findsOneWidget);
    expect(gateway.imported, isEmpty);
  });
}

/// A household that already has channels.
///
/// The screen was written for a household with none. One that arrives with
/// nineteen would otherwise be offered channels it approved months ago, with
/// nothing to say so: the parent ticks one, nothing changes, and the screen
/// looks broken.
void _existingHousehold() {
  late AppState app;
  late _CountingGateway gateway;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _CountingGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abeeha',
      age: 5,
      languages: const ['en'],
    );
    // Already approved, before ever opening the suggestions screen.
    await gateway.addChannel(
      kid.id,
      'https://www.youtube.com/channel/UC3wCAOfSB0W9iuKDDtNJeGw',
    );
    gateway.added.clear();
    gateway.imported.clear();
    await app.refreshKids();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: StarterChannelsScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a channel they already have says so and cannot be re-ticked', (
    tester,
  ) async {
    await show(tester);

    expect(find.text('Already added for Abeeha'), findsOneWidget);
    final row = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Danny Go!'),
    );
    expect(row.value, isTrue, reason: 'they have it; showing it unticked is a lie');
    expect(row.onChanged, isNull, reason: 'nothing useful happens on tapping it');
  });

  testWidgets('select all means only what they do not already have', (
    tester,
  ) async {
    await show(tester);
    final total = tester.widgetList(find.byType(CheckboxListTile)).length;

    await tester.tap(find.text('Select all'));
    await tester.pump();

    // One of the listed channels is already theirs, so the button offers to
    // add one fewer than is on screen.
    expect(find.text('Add ${total - 1} channels'), findsOneWidget);

    await tester.tap(find.text('Add ${total - 1} channels'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(
      gateway.imported.any((id) => id.contains('UC3wCAOfSB0W9iuKDDtNJeGw')),
      isFalse,
      reason: 'a channel they already had must not be re-added',
    );
    expect(gateway.imported.length, total - 1);
  });
}

/// Searching YouTube for a channel.
///
/// Adding one meant knowing its URL already, or finding it in the suggested
/// list. A parent who just wants "that dinosaur channel my nephew watches"
/// had nowhere to type it.
void _search() {
  late AppState app;
  late _CountingGateway gateway;
  late Kid kid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _CountingGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    kid = await gateway.createKid(
      nickname: 'Abeeha',
      age: 5,
      languages: const ['en'],
    );
    await app.refreshKids();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: StarterChannelsScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a channel found only by search can still be added', (
    tester,
  ) async {
    await show(tester);
    // Crash Course Kids is written for older bands, so it is NOT among the
    // suggestions for a five-year-old. Adding it proves the Add button counts
    // what the search returned and not just what was suggested — searching
    // for something already on the page would have proved nothing.
    expect(find.text('Crash Course Kids'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'primary-school');
    await tester.tap(find.text('Search'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Crash Course Kids'), findsOneWidget);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Crash Course Kids'));
    await tester.pump();
    await tester.tap(find.text('Add 1 channel'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    // Sent by id in the batch call now rather than as a pasted URL one at a
    // time; the server resolves both the same way, and the batch is what
    // carries the parent's chosen topics.
    expect(gateway.imported, ['UCONtPx56PSebXJOxbFv-2jQ']);
  });

  testWidgets('nothing is searched until the parent asks', (tester) async {
    await show(tester);
    // search.list costs a shared daily allowance — a hundred a day for every
    // household together — so it must not fire on every keystroke.
    await tester.enterText(find.byType(TextField).first, 'science');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(gateway.searches, isEmpty, reason: 'searched while they were typing');

    await tester.tap(find.text('Search'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(gateway.searches, ['science']);
  });

  testWidgets('a search that cannot run says so, not "nothing matched"', (
    tester,
  ) async {
    await show(tester);
    gateway.searchFails = true;

    await tester.enterText(find.byType(TextField).first, 'peppa');
    await tester.tap(find.text('Search'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // A parent retyping their query would never fix a daily limit.
    expect(find.textContaining('Could not search'), findsOneWidget);
    expect(find.text('Nothing on YouTube matched that.'), findsNothing);
  });
}

/// What the parent picked has to reach the screening.
///
/// A parent chose Science, was offered Free School — a real educational
/// channel, correctly tagged — and had Swami Vivekananda and Albert Einstein
/// quote compilations approved onto an eight-year-old's shelf. The topics
/// filtered which channels were *suggested* and were then dropped, so by the
/// time each upload was read nothing knew science had been asked for.
void _topicsTravel() {
  testWidgets('approving suggestions sends the topics that were picked', (
    tester,
  ) async {
    late AppState app;
    late _CapturingGateway gateway;
    late Kid kid;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      gateway = _CapturingGateway();
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      kid = await gateway.createKid(
        nickname: 'Abu',
        age: 8,
        languages: const ['en'],
      );
      await app.refreshKids();
    });

    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: StarterChannelsScreen(kid: kid)),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tester.tap(find.text('Science and how things work'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    // Two, so that "one call for the batch" is a claim the test can fail on.
    await tester.tap(find.byType(CheckboxListTile).at(0));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(CheckboxListTile).at(1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Add 2 channels'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(gateway.sentTopics, ['science']);
    // One call for the batch, not one per channel over a sleeping gateway.
    expect(gateway.importCalls, 1);
  });
}

/// Keeps what the screen sent, which is the thing under test.
class _CapturingGateway extends FakeGateway {
  List<String> sentTopics = const [];
  int importCalls = 0;

  @override
  Future<ImportResult> importChannels(
    String kidId,
    List<String> channelIds, {
    String profile = '',
    List<String> topics = const [],
  }) {
    importCalls++;
    sentTopics = topics;
    return super.importChannels(
      kidId,
      channelIds,
      profile: profile,
      topics: topics,
    );
  }
}
