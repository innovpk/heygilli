import 'dart:convert';

import 'package:http/http.dart' as http;

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
  Future<SessionStart> startSession({
    required String kidId,
    required String videoId,
    required String device,
  }) async => SessionStart.fromJson(
    await _post('/sessions', {
          'kid_id': kidId,
          'video_id': videoId,
          'device': device,
        })
        as Map<String, dynamic>,
  );

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
  Future<List<ParentPrompt>> inbox() async =>
      (await _get('/parent/inbox') as List)
          .map((p) => ParentPrompt.fromJson(p as Map<String, dynamic>))
          .toList();

  @override
  Future<void> decide(String promptId, String decision) =>
      _post('/parent/inbox/$promptId', {'decision': decision});
}

class ApiException implements Exception {
  ApiException(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'ApiException($status): $body';
}
