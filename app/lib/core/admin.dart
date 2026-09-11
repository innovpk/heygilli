/// The admin overview from `GET /admin/overview`, for the service's own
/// admins. Parsed tolerantly: a missing key or a null is a zero, never a throw.
library;

class AdminOverview {
  const AdminOverview({
    required this.totals,
    required this.perDay,
    required this.households,
  });

  /// `households`, `google`, `with_kid`, `watched`, `sessions`,
  /// `likely_tests`, `real`, `real_watched`.
  final Map<String, int> totals;
  final List<({String date, int sessions})> perDay;

  /// Newest activity first.
  final List<AdminHousehold> households;

  int total(String key) => totals[key] ?? 0;

  factory AdminOverview.fromJson(Map<String, dynamic> j) => AdminOverview(
    totals: {
      for (final e in ((j['totals'] as Map?) ?? const {}).entries)
        '${e.key}': (e.value as num?)?.toInt() ?? 0,
    },
    perDay: [
      for (final d in (j['sessions_per_day'] as List?) ?? const [])
        (
          date: '${(d as Map)['date'] ?? ''}',
          sessions: (d['sessions'] as num?)?.toInt() ?? 0,
        ),
    ],
    households: [
      for (final h in (j['households'] as List?) ?? const [])
        AdminHousehold.fromJson(h as Map<String, dynamic>),
    ],
  );
}

class AdminHousehold {
  const AdminHousehold({
    required this.id,
    required this.google,
    required this.kids,
    required this.sessions,
    required this.minutesWatched,
    required this.likelyTest,
    required this.you,
    this.firstSeen,
    this.lastActive,
  });

  final String id;
  final String? firstSeen;
  final String? lastActive;
  final bool google;

  /// "Nalain (4)", one per child.
  final List<String> kids;
  final int sessions;
  final int minutesWatched;

  /// A guess from the children's names; the row is shown either way.
  final bool likelyTest;

  /// The admin's own household.
  final bool you;

  factory AdminHousehold.fromJson(Map<String, dynamic> j) => AdminHousehold(
    id: '${j['id'] ?? ''}',
    firstSeen: j['first_seen'] as String?,
    lastActive: j['last_active'] as String?,
    google: j['google'] == true,
    kids: [
      for (final k in (j['kids'] as List?) ?? const [])
        '${(k as Map)['nickname'] ?? '?'} (${k['age'] ?? '?'})',
    ],
    sessions: (j['sessions'] as num?)?.toInt() ?? 0,
    minutesWatched: (j['minutes_watched'] as num?)?.toInt() ?? 0,
    likelyTest: j['likely_test'] == true,
    you: j['you'] == true,
  );
}

/// One parent's feedback, from `GET /admin/feedback`.
class FeedbackItem {
  const FeedbackItem({
    required this.id,
    required this.household,
    required this.text,
    required this.contact,
    required this.where,
    required this.createdAt,
    required this.done,
  });

  final String id;
  final String household;
  final String text;

  /// How to reach them, if they left a way. Often empty.
  final String contact;

  /// Which screen it was sent from.
  final String where;
  final String createdAt;
  final bool done;

  FeedbackItem copyWith({bool? done}) => FeedbackItem(
    id: id,
    household: household,
    text: text,
    contact: contact,
    where: where,
    createdAt: createdAt,
    done: done ?? this.done,
  );

  factory FeedbackItem.fromJson(Map<String, dynamic> j) => FeedbackItem(
    id: '${j['id'] ?? ''}',
    household: '${j['household'] ?? ''}',
    text: '${j['text'] ?? ''}',
    contact: '${j['contact'] ?? ''}',
    where: '${j['where'] ?? ''}',
    createdAt: '${j['created_at'] ?? ''}',
    done: j['done'] == true,
  );
}
