import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/feedback_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Send feedback", from the parent side: a line or two to the people who make
/// HeyGilli.
void main() {
  late FakeGateway gateway;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = FakeGateway();
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
  });

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFeedbackSheet(context, where: 'test'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a parent sends a line, and is thanked', (tester) async {
    await openSheet(tester);
    await tester.enterText(find.byKey(const Key('feedback-text')), 'Loved it');
    await tester.pump();
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();

    expect(gateway.feedbackSent, ['Loved it']);
    expect(find.text('Thank you. It is on its way to us.'), findsOneWidget);
  });

  testWidgets('nothing typed, nothing to send', (tester) async {
    await openSheet(tester);
    final send = tester.widget<FilledButton>(
      find.byKey(const Key('feedback-send')),
    );
    expect(send.onPressed, isNull);
  });
}
