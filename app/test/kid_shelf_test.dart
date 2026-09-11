import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/speech.dart';
import 'package:heygilli/features/kid/home_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The kid shelf: a section for each channel, each a heading and a strip of
/// big tiles.
///
/// It had been a list of rows marked by a channel picture small enough to
/// miss, under a header of four more circles, and then a row of tabs that hid
/// all but one channel. A child who cannot read had nothing to go on.
void main() {
  late _TwoChannels gateway;
  late AppState app;
  late Kid preReader;
  late Kid reader;
  late Kid searcher;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _TwoChannels();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    preReader = await gateway.createKid(
      nickname: 'Lisa',
      age: 5,
      languages: const ['en'],
    );
    reader = await gateway.createKid(
      nickname: 'Rayan',
      age: 9,
      languages: const ['en'],
    );
    final other = await gateway.createKid(
      nickname: 'Sara',
      age: 9,
      languages: const ['en'],
    );
    searcher = await gateway.updateLimits(other.id, searchEnabled: true);
  });

  Future<void> open(
    WidgetTester tester,
    Kid kid, {
    Future<String> Function()? hear,
  }) async {
    app.enterKidMode(kid);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<GilliVoice>(create: (_) => GilliVoice()),
        ],
        child: MaterialApp(home: KidHomeScreen(hear: hear)),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Finder text(String s) => find.text(s, skipOffstage: false);

  testWidgets('a section for every channel, with all of its videos', (
    tester,
  ) async {
    await open(tester, reader);
    expect(text('Super Simple Songs'), findsOneWidget);
    expect(text('SciShow Kids'), findsOneWidget);
    expect(text('Five Little Ducks'), findsOneWidget);
    expect(text('Twinkle Twinkle Little Star'), findsOneWidget);
    expect(text('Every Kind of Volcano'), findsOneWidget);
  });

  testWidgets('a reader sees how long each video is', (tester) async {
    await open(tester, reader);
    expect(text('2 min'), findsNWidgets(2));
    expect(text('5 min'), findsOneWidget);
  });

  testWidgets('a pre-reader gets one grid, a title under every picture', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester, preReader);
    // As on YouTube Kids: the title under the picture, even for the youngest.
    expect(find.byType(GridView), findsOneWidget);
    expect(text('Five Little Ducks'), findsOneWidget);
    expect(text('Every Kind of Volcano'), findsOneWidget);
    // No channel headings: a picture of a channel over each row was one more
    // small circle to puzzle at.
    expect(text('Super Simple Songs'), findsNothing);
    expect(find.bySemanticsLabel('Super Simple Songs'), findsNothing);
    expect(find.textContaining('left today'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the header has no picture of the child', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester, reader);
    expect(find.bySemanticsLabel('Change your picture'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a reader sees the time left under the greeting', (tester) async {
    await open(tester, reader);
    expect(find.text('Hi Rayan'), findsOneWidget);
    expect(find.textContaining('left today'), findsOneWidget);
  });

  testWidgets('a search keeps only the videos that match', (tester) async {
    await open(tester, searcher);
    // "v" is in Five Little Ducks and in Every Kind of Volcano: one hit on
    // each channel.
    await tester.enterText(find.byType(TextField), 'v');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(text('Five Little Ducks'), findsOneWidget);
    expect(text('Every Kind of Volcano'), findsOneWidget);
    expect(text('Twinkle Twinkle Little Star'), findsNothing);
  });

  testWidgets('saying a word searches, just as typing it would', (
    tester,
  ) async {
    await open(tester, reader, hear: () async => 'volcano');
    await tester.tap(find.byKey(const Key('search-mic')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    // What was heard sits in the box, where the child can see and change it.
    expect(find.widgetWithText(TextField, 'volcano'), findsOneWidget);
    expect(text('Every Kind of Volcano'), findsOneWidget);
    expect(text('Five Little Ducks'), findsNothing);
  });

  testWidgets('a pre-reader searches by voice too', (tester) async {
    await open(tester, preReader, hear: () async => 'ducks');
    await tester.tap(find.byKey(const Key('search-mic')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(text('Five Little Ducks'), findsOneWidget);
    expect(text('Every Kind of Volcano'), findsNothing);
  });

  testWidgets('hearing nothing leaves the shelf as it was', (tester) async {
    await open(tester, reader, hear: () async => '');
    await tester.tap(find.byKey(const Key('search-mic')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(text('Five Little Ducks'), findsOneWidget);
    expect(text('Every Kind of Volcano'), findsOneWidget);
  });
}

/// Two channels, each with its own videos.
class _TwoChannels extends FakeGateway {
  static const _songs = HomeRow(
    title: 'Super Simple Songs',
    channelId: 'UC-songs',
    videos: [
      Video(
        id: 'ducks',
        channelId: 'UC-songs',
        title: 'Five Little Ducks',
        durationS: 120,
      ),
      Video(
        id: 'star',
        channelId: 'UC-songs',
        title: 'Twinkle Twinkle Little Star',
        durationS: 130,
      ),
    ],
  );

  static const _science = HomeRow(
    title: 'SciShow Kids',
    channelId: 'UC-science',
    videos: [
      Video(
        id: 'volcano',
        channelId: 'UC-science',
        title: 'Every Kind of Volcano',
        durationS: 300,
      ),
    ],
  );

  @override
  Future<List<HomeRow>> home(String kidId, {String query = ''}) async {
    final q = query.trim().toLowerCase();
    return [
      for (final row in [_songs, _science])
        HomeRow(
          title: row.title,
          channelId: row.channelId,
          videos: [
            for (final v in row.videos)
              if (v.title.toLowerCase().contains(q)) v,
          ],
        ),
    ];
  }
}
