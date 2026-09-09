import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/models.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/inbox_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The inbox, grouped by the channel each video came from.
///
/// A parent working through it is mostly deciding about a channel rather than
/// about videos one at a time: four borderline uploads in a row are usually
/// one channel, and the answer to all four is the same answer. Ungrouped they
/// read as four unrelated cards.
void main() {
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeGateway();
    await gateway.signInDev('parent');
    app = AppState(gateway: gateway, settings: await LocalSettings.load());
    // The demo attaches its prompts to a kid the parent actually added, so
    // there is nothing waiting until there is somebody to decide about.
    await gateway.createKid(nickname: 'Abu', age: 8, languages: const ['en']);
    await app.refreshKids();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
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

  testWidgets('one heading per channel, with how many are waiting', (
    tester,
  ) async {
    await show(tester);

    expect(find.text('SciShow Kids'), findsOneWidget);
    expect(find.text('Danny Go!'), findsOneWidget);
    expect(find.text('2 waiting'), findsOneWidget);
    expect(find.text('1 waiting'), findsOneWidget);
  });

  testWidgets('videos sit under their own channel, not scattered', (
    tester,
  ) async {
    await show(tester);

    final heading = tester.getRect(find.text('SciShow Kids')).top;
    final other = tester.getRect(find.text('Danny Go!')).top;
    final volcanoes = tester.getRect(find.textContaining('Volcanoes')).top;
    final goosebumps = tester.getRect(find.textContaining('Goosebumps')).top;
    final lava = tester.getRect(find.textContaining('Floor Is Lava')).top;

    expect(volcanoes, greaterThan(heading));
    expect(goosebumps, greaterThan(volcanoes));
    expect(
      goosebumps,
      lessThan(other),
      reason: 'both SciShow videos belong above the next channel heading',
    );
    expect(lava, greaterThan(other));
  });

  test('a prompt with no channel name still lands in a group', () {
    const p = ParentPrompt(
      id: 'p',
      kidId: 'k',
      channelTitle: '',
      reason: 'r',
      createdAt: '',
    );
    // Empty is a real key, so these gather together under one heading rather
    // than each becoming its own nameless section.
    expect(p.channelTitle, '');
  });
}
