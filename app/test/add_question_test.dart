import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/core/theme.dart';
import 'package:heygilli/features/parent/add_question_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A parent writing their own question for a video.
///
/// The Planner knows what happened in the video. Only the parent knows that
/// this child has been asking about volcanoes all week. What matters here is
/// that their sentence survives unchanged, that they can take it back, and
/// that a video cannot be turned into a worksheet.
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

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: AddQuestionSheet(
              kidId: kid.id,
              videoId: video.id,
              videoTitle: video.title,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> add(WidgetTester tester, String text, {bool yesNo = false}) async {
    await tester.enterText(find.byType(TextField), text);
    if (yesNo) {
      await tester.tap(find.byType(Switch));
      await tester.pump();
    }
    await tester.tap(find.text('Add it'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('the parent\'s sentence is stored exactly as typed', (tester) async {
    await open(tester);
    await add(tester, 'What did the volcano do?');

    final stored = await gateway.parentQuestions(kid.id, video.id);
    expect(stored.single.text, 'What did the volcano do?');
    expect(stored.single.yesNo, isFalse);
  });

  testWidgets('a yes/no question is marked as one', (tester) async {
    await open(tester);
    await add(tester, 'Did you like the ending?', yesNo: true);

    final stored = await gateway.parentQuestions(kid.id, video.id);
    expect(stored.single.yesNo, isTrue);
  });

  testWidgets('it appears in the list once added, and the box clears', (tester) async {
    await open(tester);
    await add(tester, 'What did the volcano do?');

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
      reason: 'a parent adding a second question should start from blank',
    );
    expect(find.text('What did the volcano do?'), findsOneWidget);
  });

  testWidgets('a parent can take one back', (tester) async {
    await open(tester);
    await add(tester, 'Mine');

    await tester.tap(find.byIcon(Icons.close_rounded));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(await gateway.parentQuestions(kid.id, video.id), isEmpty);
  });

  testWidgets('three is the most, and the box goes away at the limit', (tester) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {
      await add(tester, 'Question $i');
    }

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('Three is the most'), findsOneWidget);
  });

  testWidgets('an empty box adds nothing', (tester) async {
    await open(tester);
    await tester.tap(find.text('Add it'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(await gateway.parentQuestions(kid.id, video.id), isEmpty);
  });

  testWidgets('nothing on the sheet is written in the sheet colour', (
    tester,
  ) async {
    // `HgText.display` and `HgText.body` both default to cream, and this sheet
    // is cream. Two labels shipped invisible — the heading and the yes/no
    // switch text — and every test here still passed, because a Text widget
    // exists whether or not a human can read it.
    await open(tester);
    await add(tester, 'What did the volcano do?');

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts, isNotEmpty);
    for (final t in texts) {
      final colour = t.style?.color;
      if (colour == null) continue; // inherits, and nothing here inherits cream
      expect(
        colour,
        isNot(HgColors.cream),
        reason: 'invisible on a cream sheet: "${t.data}"',
      );
    }
  });
}
