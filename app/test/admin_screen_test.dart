import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heygilli/core/admin.dart';
import 'package:heygilli/core/app_state.dart';
import 'package:heygilli/core/fake_gateway.dart';
import 'package:heygilli/core/settings.dart';
import 'package:heygilli/features/parent/admin_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The admin overview: the service's own view of who has tried HeyGilli.
void main() {
  late AppState app;

  Future<void> open(WidgetTester tester) async {
    // Tall enough that the household rows are built, not just scrolled to.
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: AdminScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('for an admin', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      app = AppState(gateway: _Admin(), settings: await LocalSettings.load());
    });

    testWidgets('the counts that answer "how many real families"', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Real families'), findsOneWidget);
      expect(find.text('2'), findsWidgets);
      expect(find.text('Sessions per day'), findsOneWidget);
    });

    testWidgets('likely tests are hidden until asked for', (tester) async {
      await open(tester);
      expect(find.text('Nalain (4)'), findsOneWidget);
      expect(find.text('Ver (6)'), findsNothing);

      await tester.tap(find.byKey(const Key('admin-show-tests')));
      await tester.pumpAndSettle();
      expect(find.text('Ver (6)'), findsOneWidget);
      expect(find.text('Likely test'), findsOneWidget);
    });

    testWidgets('feedback, with a tick for what was acted on', (tester) async {
      await open(tester);
      expect(find.text('Feedback · 1 open'), findsOneWidget);
      expect(find.text('Please add more songs.'), findsOneWidget);
      expect(
        find.textContaining('reply to parent@example.org'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('feedback-done-fb_1')));
      await tester.pumpAndSettle();
      expect(find.text('Feedback · 0 open'), findsOneWidget);
      expect((app.gateway as _Admin).ticked, ['hh_family/fb_1/true']);
    });

    test('the rail learns it may show the link', () async {
      await app.refreshAdmin();
      expect(app.isAdmin, isTrue);
    });
  });

  test('everyone else never gets the link', () async {
    SharedPreferences.setMockInitialValues({});
    final other = AppState(
      gateway: FakeGateway(),
      settings: await LocalSettings.load(),
    );
    await other.refreshAdmin();
    expect(other.isAdmin, isFalse);
  });
}

class _Admin extends FakeGateway {
  final ticked = <String>[];

  @override
  Future<bool> isAdmin() async => true;

  @override
  Future<List<FeedbackItem>> adminFeedback() async => [
    FeedbackItem.fromJson({
      'id': 'fb_1',
      'household': 'hh_family',
      'text': 'Please add more songs.',
      'contact': 'parent@example.org',
      'where': 'rail',
      'created_at': '2026-09-11T09:00:00+00:00',
    }),
  ];

  @override
  Future<void> setFeedbackDone(String household, String id, bool done) async {
    ticked.add('$household/$id/$done');
  }

  @override
  Future<AdminOverview> adminOverview() async => AdminOverview.fromJson({
    'totals': {
      'households': 4,
      'google': 2,
      'with_kid': 3,
      'watched': 2,
      'sessions': 37,
      'likely_tests': 1,
      'real': 2,
      'real_watched': 1,
    },
    'sessions_per_day': [
      {'date': '2026-09-07', 'sessions': 2},
      {'date': '2026-09-08', 'sessions': 35},
    ],
    'households': [
      {
        'id': 'hh_you',
        'google': true,
        'you': true,
        'kids': [
          {'nickname': 'Abu', 'age': 8},
        ],
        'sessions': 35,
        'minutes_watched': 210,
        'first_seen': '2026-09-08T19:48:00+00:00',
        'last_active': '2026-09-11T10:00:00+00:00',
      },
      {
        'id': 'hh_family',
        'google': true,
        'kids': [
          {'nickname': 'Nalain', 'age': 4},
        ],
        'sessions': 2,
        'minutes_watched': 9,
        'first_seen': '2026-09-07T12:15:00+00:00',
        'last_active': '2026-09-07T12:30:00+00:00',
      },
      {
        'id': 'hh_test',
        'likely_test': true,
        'kids': [
          {'nickname': 'Ver', 'age': 6},
        ],
      },
      {'id': 'hh_empty'},
    ],
  });
}
