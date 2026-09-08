import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/ask_about_video_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asking about one video.
///
/// The screening answers the question it thought of; this is for the one the
/// parent actually has. What matters is that the answer says what it rests on,
/// and that asking changes nothing.
void main() {
  late AppState app;
  late FakeGateway gateway;
  late Kid kid;
  late Video video;

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
    await app.refreshKids();
    video = (await gateway.home(kid.id)).first.videos.first;
  });

  Future<void> open(WidgetTester tester, {AppState? state}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state ?? app,
        child: MaterialApp(
          home: Scaffold(
            body: AskAboutVideoSheet(kidId: kid.id, video: video),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('an empty box offers something to ask', (tester) async {
    // A parent who does not know what this can answer should not be staring at
    // a blank field.
    await open(tester);
    expect(find.text('Does it try to sell them something?'), findsOneWidget);
    expect(find.textContaining('the choice stays yours'), findsOneWidget);
  });

  testWidgets('asking shows the question and the answer', (tester) async {
    await open(tester);

    await tester.tap(find.text('Does it try to sell them something?'));
    await settle(tester);

    expect(find.textContaining('sponsor read about three minutes in'), findsOneWidget);
    // The question stays on screen: an answer with no question above it is a
    // paragraph a parent has to reverse-engineer.
    expect(find.text('Does it try to sell them something?'), findsOneWidget);
  });

  testWidgets('every answer says what it was read from', (tester) async {
    // An answer drawn from a video nobody could read reads exactly like a good
    // one. This is the line that separates them.
    await open(tester);
    await tester.tap(find.text('Is anything scary in it?'));
    await settle(tester);

    expect(
      find.text('Answered from what is said in the video'),
      findsOneWidget,
    );
  });

  testWidgets('a video nobody could read says so instead of sounding sure', (
    tester,
  ) async {
    final unread = _UnreadGateway(gateway);
    await open(
      tester,
      state: AppState(gateway: unread, settings: await LocalSettings.load()),
    );

    await tester.tap(find.text('Is anything scary in it?'));
    await settle(tester);

    expect(
      find.textContaining('nobody could read this one'),
      findsOneWidget,
      reason: 'an answer from the title alone was presented as if it were read',
    );
  });

  testWidgets('a follow-up carries what was already asked', (tester) async {
    final spy = _RecordingGateway(gateway);
    await open(
      tester,
      state: AppState(gateway: spy, settings: await LocalSettings.load()),
    );

    await tester.tap(find.text('Does it try to sell them something?'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'And how long is that bit?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester);

    expect(spy.lastHistory, hasLength(1));
    expect(spy.lastHistory.single.$1, 'Does it try to sell them something?');
    expect(spy.lastHistory.single.$2, contains('sponsor read'));
  });

  testWidgets('a failure says so and leaves the box usable', (tester) async {
    await open(
      tester,
      state: AppState(
        gateway: _FailingGateway(gateway),
        settings: await LocalSettings.load(),
      ),
    );

    await tester.tap(find.text('Is anything scary in it?'));
    await settle(tester);

    expect(find.textContaining('Could not ask just now'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });
}

class _UnreadGateway extends FakeGateway {
  _UnreadGateway(this.inner);
  final FakeGateway inner;

  @override
  Future<VideoAnswer> askAboutVideo(
    String kidId,
    String videoId,
    String question, {
    List<(String, String)> history = const [],
  }) async => const VideoAnswer(
    answer: 'The title says it is about volcanoes. Nobody has read the words.',
    answeredFrom: 'the title and description only',
  );
}

class _RecordingGateway extends FakeGateway {
  _RecordingGateway(this.inner);
  final FakeGateway inner;
  List<(String, String)> lastHistory = const [];

  @override
  Future<VideoAnswer> askAboutVideo(
    String kidId,
    String videoId,
    String question, {
    List<(String, String)> history = const [],
  }) {
    lastHistory = history;
    return inner.askAboutVideo(kidId, videoId, question, history: history);
  }
}

class _FailingGateway extends FakeGateway {
  _FailingGateway(this.inner);
  final FakeGateway inner;

  @override
  Future<VideoAnswer> askAboutVideo(
    String kidId,
    String videoId,
    String question, {
    List<(String, String)> history = const [],
  }) async => throw Exception('gateway asleep');
}
