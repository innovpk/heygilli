import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/inbox_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answering a whole channel at once.
///
/// A household that has just added channels arrives with a queue in the
/// hundreds, and most of a channel's queue gets the same answer — which is
/// what grouping by channel showed in the first place. Tapping Approve two
/// hundred times is not a decision, it is a chore that ends in the parent
/// approving without reading.
class _RecordingGateway extends FakeGateway {
  final List<String> decided = [];
  String? failOn;

  @override
  Future<void> decide(String promptId, String decision) async {
    if (promptId == failOn) throw StateError('the server said no');
    decided.add('$promptId:$decision');
    return super.decide(promptId, decision);
  }
}

void main() {
  late AppState app;
  late _RecordingGateway gateway;

  Future<void> show(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    gateway = _RecordingGateway();
    await tester.runAsync(() async {
      await gateway.signInDev('parent');
      app = AppState(gateway: gateway, settings: await LocalSettings.load());
      await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
      await app.refreshKids();
    });
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: InboxScreen())),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('offered only where there is more than one to answer', (
    tester,
  ) async {
    await show(tester);
    // The demo has two prompts from SciShow Kids and one from Danny Go!, so
    // exactly one group earns the button. "Approve all 1" is the card's own
    // button with extra words and an extra tap.
    expect(find.text('Approve all'), findsOneWidget);
  });

  testWidgets('asks first, and cancelling decides nothing', (tester) async {
    await show(tester);

    await tester.tap(find.text('Approve all'));
    await tester.pumpAndSettle();
    expect(find.text('Approve all 2?'), findsOneWidget);
    expect(
      find.textContaining('SciShow Kids'),
      findsWidgets,
      reason: 'the dialog must name what "all" means',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(gateway.decided, isEmpty);
  });

  testWidgets('approves every waiting video from that channel and no other', (
    tester,
  ) async {
    await show(tester);

    await tester.tap(find.text('Approve all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve 2'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(gateway.decided, ['prompt_1:approve', 'prompt_2:approve']);
    expect(
      gateway.decided.any((d) => d.startsWith('prompt_3')),
      isFalse,
      reason: 'the other channel was not part of what the parent agreed to',
    );
  });

  testWidgets('one failure stops, and says how far it got', (tester) async {
    await show(tester);
    gateway.failOn = 'prompt_2';

    await tester.tap(find.text('Approve all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve 2'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // The one that worked stays done; the parent is told rather than left
    // unsure whether any of it happened.
    expect(gateway.decided, ['prompt_1:approve']);
    expect(find.textContaining('1 of 2 approved'), findsOneWidget);
  });
}
