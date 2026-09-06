import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'analytics.dart';
import 'gateway.dart';
import 'models.dart';
import 'session_socket.dart';

/// REST + WebSocket client for the Python gateway (docs/PROTOCOL.md).
class ApiClient implements Gateway {
  ApiClient({required this.baseUrl, String? token, http.Client? client})
    : _token = token,
      _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;
  String? _token;

  /// Callback so the app can persist a fresh token from /auth/dev.
  void Function(String token)? onToken;

  @override
  bool get isDemo => false;

  @override
  bool get signedIn => _token != null;

  @override
  void forgetToken() => _token = null;

  /// True when the gateway answers on the base URL. Used once at startup to
  /// choose between live and demo mode.
  Future<bool> reachable() async {
    try {
      final r = await _http
          .get(Uri.parse('$baseUrl/kids'), headers: _headers())
          // Generous on purpose. This probe decides between the app and a
          // dead end, and a first connection on a cold radio or a slow house
          // wifi can take several seconds. Two seconds turned a working
          // gateway into "Gilli can't connect" on an emulator; on a phone in
          // a back bedroom it would do the same.
          .timeout(const Duration(seconds: 8));
      // 401 still means "a gateway is there".
      return r.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<dynamic> _get(String path) async {
    final r = await _http.get(Uri.parse('$baseUrl$path'), headers: _headers());
    return _decode(r);
  }

  Future<dynamic> _post(String path, [Object? body]) async {
    final r = await _http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(r);
  }

  Future<dynamic> _patch(String path, [Object? body]) async {
    final r = await _http.patch(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(r);
  }

  Future<dynamic> _put(String path, [Object? body]) async {
    final r = await _http.put(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(r);
  }

  Future<dynamic> _delete(String path) async {
    final r = await _http.delete(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
    );
    return _decode(r);
  }

  dynamic _decode(http.Response r) {
    if (r.statusCode >= 400) {
      throw ApiException(r.statusCode, r.body);
    }
    if (r.body.isEmpty) return null;
    return jsonDecode(r.body);
  }

  @override
  Future<void> signInDev(String name) async {
    final j = await _post('/auth/dev', {'name': name}) as Map<String, dynamic>;
    _token = j['token'] as String;
    onToken?.call(_token!);
  }

  @override
  Future<Session> signInWithGoogle(
    String serverAuthCode, {
    String redirectUri = '',
  }) async {
    final session = Session.fromJson(
      await _post('/auth/google', {
            'server_auth_code': serverAuthCode,
            // Sent only when there is one. A phone has no redirect, and
            // Google refuses the exchange if it is given an empty one.
            if (redirectUri.isNotEmpty) 'redirect_uri': redirectUri,
          })
          as Map<String, dynamic>,
    );
    _token = session.token;
    onToken?.call(_token!);
    return session;
  }

  @override
  Future<YouTubeStatus> youtubeStatus() async =>
      YouTubeStatus.fromJson(await _get('/me/youtube') as Map<String, dynamic>);

  @override
  Future<SubscriptionList> youtubeSubscriptions() async =>
      SubscriptionList.fromJson(
        await _get('/me/youtube/subscriptions') as Map<String, dynamic>,
      );

  @override
  Future<ImportResult> importChannels(
    String kidId,
    List<String> channelIds, {
    String profile = '',
  }) async => ImportResult.fromJson(
    await _post('/kids/$kidId/channels/import', {
          'channel_ids': channelIds,
          if (profile.isNotEmpty) 'profile': profile,
        })
        as Map<String, dynamic>,
  );

  @override
  Future<TakeoutPreview> importTakeout(
    Uint8List zipBytes,
    String filename, {
    bool includeHistory = false,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/import/takeout'),
    );
    if (_token != null) request.headers['Authorization'] = 'Bearer $_token';
    // Sent only when it is true. A default-off setting should not travel as
    // "include_history=false" on every import the household ever does.
    if (includeHistory) request.fields['include_history'] = 'true';
    // Bytes, not a path: this is the slimmed zip, which is kilobytes. The
    // hundreds of megabytes a real export weighs were already left on the
    // device by slimTakeout and never reach this call. No timeout: a slow
    // connection is not a reason to abandon a household's only import route.
    request.files.add(
      http.MultipartFile.fromBytes('file', zipBytes, filename: filename),
    );
    final response = await http.Response.fromStream(await _http.send(request));
    return TakeoutPreview.fromJson(_decode(response) as Map<String, dynamic>);
  }

  @override
  Future<ChannelReviewBatch> channelReviews(List<String> channelIds) async =>
      ChannelReviewBatch.fromJson(
        await _post('/channels/reviews', {'channel_ids': channelIds})
            as Map<String, dynamic>,
      );

  @override
  Future<ChannelReview> channelReview(
    String channelId, {
    bool refresh = false,
  }) async => ChannelReview.fromJson(
    await _get('/channels/$channelId/review?refresh=$refresh')
        as Map<String, dynamic>,
  );

  @override
  Future<DriftCheck> checkDrift(List<String> channelIds) async =>
      DriftCheck.fromJson(
        await _post('/channels/drift/check', {'channel_ids': channelIds})
            as Map<String, dynamic>,
      );

  @override
  Future<void> removeChannel(String kidId, String channelId) =>
      _delete('/kids/$kidId/channels/$channelId');

  @override
  Future<List<Kid>> kids() async => (await _get('/kids') as List)
      .map((k) => Kid.fromJson(k as Map<String, dynamic>))
      .toList();

  @override
  Future<Kid> createKid({
    required String nickname,
    required int age,
    required List<String> languages,
  }) async => Kid.fromJson(
    await _post('/kids', {
          'nickname': nickname,
          'age': age,
          'languages': languages,
        })
        as Map<String, dynamic>,
  );

  @override
  Future<List<Channel>> channels(String kidId) async =>
      (await _get('/kids/$kidId/channels') as List)
          .map((c) => Channel.fromJson(c as Map<String, dynamic>))
          .toList();

  @override
  Future<Channel> addChannel(String kidId, String url) async =>
      Channel.fromJson(
        await _post('/kids/$kidId/channels', {'url': url})
            as Map<String, dynamic>,
      );

  @override
  Future<List<HomeRow>> home(String kidId, {String query = ''}) async {
    final q = query.trim();
    final j =
        await _get(
              '/kids/$kidId/home${q.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(q)}'}',
            )
            as Map<String, dynamic>;
    return (j['rows'] as List? ?? const [])
        .map((r) => HomeRow.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<String> speechUrl(String text, {bool slow = false}) async {
    try {
      final j =
          await _post('/tts', {'text': text, 'slow': slow})
              as Map<String, dynamic>;
      final url = j['url'] as String? ?? '';
      // Relative, like every other tts url the protocol hands back.
      return url.isEmpty || url.startsWith('http') ? url : '$baseUrl$url';
    } catch (_) {
      // A voice is a nicety; the caller speaks it on-device instead. Never let
      // this be the reason a screen says nothing at all.
      return '';
    }
  }

  @override
  Future<WatchState> watchState(String kidId) async => WatchState.fromJson(
    await _get('/kids/$kidId/state') as Map<String, dynamic>,
  );

  @override
  Future<Kid> updateLimits(
    String kidId, {
    int? dailyMinutes,
    int? breakAfterMinutes,
    int? breakMinutes,
    int? maxVideoMinutes,
    bool? breakIsFirm,
    bool? searchEnabled,
  }) async => Kid.fromJson(
    await _patch('/kids/$kidId/limits', {
          // Omitted fields are left alone by the gateway, so a screen that
          // only touched one setting sends only that one.
          'daily_minutes': ?dailyMinutes,
          'break_after_minutes': ?breakAfterMinutes,
          'break_minutes': ?breakMinutes,
          'max_video_minutes': ?maxVideoMinutes,
          'break_is_firm': ?breakIsFirm,
          'search_enabled': ?searchEnabled,
        })
        as Map<String, dynamic>,
  );

  @override
  Future<Kid> saveBreakMessages(
    String kidId,
    List<BreakMessage> messages,
  ) async => Kid.fromJson(
    await _put('/kids/$kidId/break-messages', {
          'messages': [for (final m in messages) m.toJson()],
        })
        as Map<String, dynamic>,
  );

  @override
  Future<List<BreakMessage>> suggestBreakMessages(String kidId) async {
    final body =
        await _post('/kids/$kidId/break-messages/suggest')
            as Map<String, dynamic>;
    // PROTOCOL names this list "suggestions", not "messages": drafts and
    // saved lines are different things and the gateway keeps them apart.
    return [
      for (final m in (body['suggestions'] as List? ?? const []))
        BreakMessage.fromJson(m as Map<String, dynamic>),
    ];
  }

  @override
  Future<BreakPeriod> ackBreak(String kidId) async => BreakPeriod.fromJson(
    await _post('/kids/$kidId/break/ack') as Map<String, dynamic>,
  );

  @override
  Future<void> overrideBreak(String kidId) =>
      _post('/kids/$kidId/break/override', {'pin_ok': true});

  @override
  Future<SessionStartResult> startSession({
    required String kidId,
    required String videoId,
    required String device,
  }) async {
    try {
      return SessionStarted(
        SessionStart.fromJson(
          await _post('/sessions', {
                'kid_id': kidId,
                'video_id': videoId,
                'device': device,
              })
              as Map<String, dynamic>,
        ),
      );
    } on ApiException catch (e) {
      // 409 is "a break is running", which the kid screen shows as the break.
      // Any other status is a real failure and still throws.
      final active = e.status == 409 ? breakFromErrorBody(e.body) : null;
      if (active == null) rethrow;
      return SessionBlockedByBreak(active);
    }
  }

  @override
  Future<SessionSocket> openSession(String sessionId) {
    final ws = Uri.parse(baseUrl).replace(
      scheme: baseUrl.startsWith('https') ? 'wss' : 'ws',
      path: '/sessions/$sessionId/ws',
    );
    return WebSocketSession.connect(ws, token: _token);
  }

  @override
  Future<void> endSession(String sessionId) =>
      _post('/sessions/$sessionId/end');

  @override
  Future<Digest> digest(String kidId, String date) async => Digest.fromJson(
    await _get('/kids/$kidId/digest?date=$date') as Map<String, dynamic>,
  );

  @override
  Future<Digest> runDigest(String kidId) async => Digest.fromJson(
    await _post('/kids/$kidId/digest/run') as Map<String, dynamic>,
  );

  @override
  Future<Analytics> analytics(String kidId, {int days = 14}) async {
    // PROTOCOL: days is 7-90. Clamp here so a UI bug cannot 400 the gateway.
    final n = days.clamp(7, 90);
    return Analytics.fromJson(
      await _get('/kids/$kidId/analytics?days=$n') as Map<String, dynamic>,
    );
  }

  @override
  Future<List<RevisitConcept>> revisits(String kidId) async {
    final body = await _get('/kids/$kidId/revisits') as Map<String, dynamic>;
    return [
      for (final c in (body['concepts'] as List? ?? const []))
        RevisitConcept.fromJson((c as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<List<WordSeed>> words(String kidId) async {
    final body = await _get('/kids/$kidId/words') as Map<String, dynamic>;
    return [
      for (final w in (body['words'] as List? ?? const []))
        WordSeed.fromJson((w as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<HistoryInsight?> history(String kidId) async {
    try {
      return HistoryInsight.fromJson(
        await _get('/kids/$kidId/history') as Map<String, dynamic>,
      );
    } on ApiException catch (e) {
      // 404 is the normal answer for a household that never opted in, not a
      // failure to show a parent.
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<bool> deleteHistory(String kidId) async {
    final body = await _delete('/kids/$kidId/history');
    // A gateway that answers with an empty body has still deleted it.
    if (body is! Map) return true;
    return body['deleted'] as bool? ?? true;
  }

  @override
  Future<Policy> policy(String kidId) async => Policy.fromJson(
    await _get('/kids/$kidId/policy') as Map<String, dynamic>,
  );

  @override
  Future<Policy> savePolicy(
    String kidId, {
    required List<PolicyAnswer> answers,
    required String notes,
  }) async => Policy.fromJson(
    await _put('/kids/$kidId/policy', {
          // Weight is the server's to work out, but it round-trips rather
          // than being dropped: an answer the parent has not touched keeps
          // the weight it had earned.
          'answers': [for (final a in answers) a.toJson()],
          'notes': notes,
        })
        as Map<String, dynamic>,
  );

  @override
  Future<PolicyQuestions> policyQuestions(String kidId) async =>
      PolicyQuestions.fromJson(
        await _post('/kids/$kidId/policy/questions') as Map<String, dynamic>,
      );

  @override
  Future<List<ParentPrompt>> inbox() async =>
      (await _get('/parent/inbox') as List)
          .map((p) => ParentPrompt.fromJson(p as Map<String, dynamic>))
          .toList();

  @override
  Future<void> decide(String promptId, String decision) =>
      _post('/parent/inbox/$promptId', {'decision': decision});
}

/// Digs the active break out of a 409 body from `POST /sessions`.
///
/// PROTOCOL says the 409 "carries the active break" without pinning the
/// envelope, and FastAPI wraps raised errors in `detail`. So all four shapes
/// the gateway could plausibly send are accepted: the break at the top level,
/// under `break`, under `active_break`, or under `detail` holding any of
/// those. Anything else returns null and the caller rethrows rather than
/// inventing a break out of an error body.
BreakPeriod? breakFromErrorBody(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  return _breakIn(decoded, depth: 0);
}

BreakPeriod? _breakIn(Object? node, {required int depth}) {
  if (node is! Map || depth > 2) return null;
  final j = node.cast<String, dynamic>();
  // A break is recognised by its clock, not by its message: a parent who
  // saved no lines has a real break with nothing in it to speak, and keying
  // off the message would drop that one on the floor.
  if (j['id'] != null && (j['seconds_left'] is num || j['ends_at'] is String)) {
    return BreakPeriod.fromJson(j);
  }
  for (final key in const ['break', 'active_break', 'detail']) {
    final found = _breakIn(j[key], depth: depth + 1);
    if (found != null) return found;
  }
  return null;
}

class ApiException implements Exception {
  ApiException(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'ApiException($status): $body';
}
