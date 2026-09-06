import 'dart:convert';
import 'dart:io';

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

  /// True when the gateway answers on the base URL. Used once at startup to
  /// choose between live and demo mode.
  Future<bool> reachable() async {
    try {
      final r = await _http
          .get(Uri.parse('$baseUrl/kids'), headers: _headers())
          .timeout(const Duration(seconds: 2));
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
  Future<Session> signInWithGoogle(String serverAuthCode) async {
    final session = Session.fromJson(
      await _post('/auth/google', {'server_auth_code': serverAuthCode})
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
    List<String> channelIds,
  ) async => ImportResult.fromJson(
    await _post('/kids/$kidId/channels/import', {'channel_ids': channelIds})
        as Map<String, dynamic>,
  );

  @override
  Future<TakeoutPreview> importTakeout(File zip) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/import/takeout'),
    );
    if (_token != null) request.headers['Authorization'] = 'Bearer $_token';
    // fromPath streams off disk: a Takeout export is routinely hundreds of MB
    // and must never be read into memory here. No timeout for the same reason.
    request.files.add(await http.MultipartFile.fromPath('file', zip.path));
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
  Future<List<HomeRow>> home(String kidId) async {
    final j = await _get('/kids/$kidId/home') as Map<String, dynamic>;
    return (j['rows'] as List? ?? const [])
        .map((r) => HomeRow.fromJson(r as Map<String, dynamic>))
        .toList();
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
  }) async => Kid.fromJson(
    await _patch('/kids/$kidId/limits', {
          // Omitted fields are left alone by the gateway, so a screen that
          // only touched one setting sends only that one.
          'daily_minutes': ?dailyMinutes,
          'break_after_minutes': ?breakAfterMinutes,
          'break_minutes': ?breakMinutes,
          'max_video_minutes': ?maxVideoMinutes,
        })
        as Map<String, dynamic>,
  );

  @override
  Future<MovementBreak> ackBreak(String kidId) async => MovementBreak.fromJson(
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
MovementBreak? breakFromErrorBody(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  return _breakIn(decoded, depth: 0);
}

MovementBreak? _breakIn(Object? node, {required int depth}) {
  if (node is! Map || depth > 2) return null;
  final j = node.cast<String, dynamic>();
  // A break is recognised by its task, which is the part the screen needs.
  if (j['task'] is Map) return MovementBreak.fromJson(j);
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
