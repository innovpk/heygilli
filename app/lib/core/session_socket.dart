import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

/// A live session: typed messages in, typed messages out.
///
/// The session screen only talks to this interface, so the same screen runs
/// against the real gateway ([WebSocketSession]) and the in-app demo
/// (FakeGateway provides its own implementation).
abstract class SessionSocket {
  Stream<ServerMessage> get messages;
  void send(ClientMessage message);
  Future<void> close();
}

/// `ws://host/sessions/{id}/ws` per docs/PROTOCOL.md.
class WebSocketSession implements SessionSocket {
  WebSocketSession._(this._channel)
    : messages = _channel.stream
          .map((frame) => ServerMessage.decode(frame as String))
          .asBroadcastStream();

  /// Opens the socket and sends `hello`. The REST bearer token is sent as a
  /// header; PROTOCOL.md does not spell out WS auth, so the gateway should
  /// accept the same `Authorization` header here.
  static Future<WebSocketSession> connect(Uri uri, {String? token}) async {
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: token == null ? null : {'Authorization': 'Bearer $token'},
      connectTimeout: const Duration(seconds: 5),
    );
    await channel.ready;
    final session = WebSocketSession._(channel);
    session.send(const HelloMessage());
    return session;
  }

  final WebSocketChannel _channel;

  @override
  final Stream<ServerMessage> messages;

  @override
  void send(ClientMessage message) => _channel.sink.add(message.encode());

  @override
  Future<void> close() async {
    try {
      send(const ByeMessage());
    } catch (_) {
      // Socket may already be gone; bye is best-effort.
    }
    await _channel.sink.close();
  }
}
