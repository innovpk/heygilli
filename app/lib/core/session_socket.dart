import 'dart:async';

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

  /// Opens the socket. The caller sends `hello` once it is listening, so the
  /// `ready` reply is never missed.
  ///
  /// The token goes in the query string, not a header, because **a browser
  /// cannot set headers on a WebSocket at all**. The header version compiled
  /// and ran on Android and silently never connected on the web, which is why
  /// a nine-minute video went by without a single question: the session was
  /// created over REST and then nothing drove it. `?token=` is what the
  /// gateway reads (PROTOCOL "Session socket"), so one path now serves every
  /// platform rather than one that works and one that quietly does not.
  static Future<WebSocketSession> connect(Uri uri, {String? token}) async {
    final channel = WebSocketChannel.connect(
      token == null || token.isEmpty
          ? uri
          : uri.replace(queryParameters: {'token': token}),
    );
    await channel.ready.timeout(const Duration(seconds: 8));
    return WebSocketSession._(channel);
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
