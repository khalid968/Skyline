import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../version.dart';
import '../api/api_client.dart';

enum ConnectionStatus { offline, connecting, online }

/// One frame from the server. The socket is server-to-client only: nudges
/// ("inbox": go and pull), receipts and typing signals. Nothing is sent up it.
class RealtimeEvent {
  RealtimeEvent(this.type, this.from, this.payload);
  final String type;
  final String? from;
  final Map<String, Object?> payload;
}

/// Keeps a WebSocket open while the app runs, reconnecting with backoff.
/// Every (re)connection starts with a pull, so nothing is missed while away.
class RealtimeClient {
  RealtimeClient({required this.api, required this.uri});

  final ApiClient api;
  final Uri uri;

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _status = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus _current = ConnectionStatus.offline;
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _running = false;
  bool _paused = false;

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<ConnectionStatus> get status => _status.stream;
  ConnectionStatus get current => _current;

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _set(ConnectionStatus.offline);
  }

  /// The app went to the background (phones only): close the socket
  /// cleanly. The phone would kill it soon anyway without telling us, and a
  /// closed socket tells the server this device is away, so it sends a push
  /// instead of writing to a dead connection.
  Future<void> pause() async {
    if (!_running || _paused) return;
    _paused = true;
    _retry?.cancel();
    await _drop();
    _set(ConnectionStatus.offline);
  }

  /// Back in the foreground: connect now. Never wait for a keep-alive to
  /// discover that the old socket died, and forget any backoff (Phase 14a).
  Future<void> resume() async {
    if (!_running) return;
    _paused = false;
    _retry?.cancel();
    _attempt = 0;
    await _drop();
    _set(ConnectionStatus.offline);
    unawaited(_connect());
  }

  /// Closes the current socket without treating it as a failure (no retry).
  Future<void> _drop() async {
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    await sub?.cancel();
    await channel?.sink.close();
  }

  /// Try again now (e.g. the app came to the foreground).
  void nudge() {
    if (!_running || _current != ConnectionStatus.offline) return;
    _retry?.cancel();
    _connect();
  }

  void _set(ConnectionStatus s) {
    if (_current == s) return;
    _current = s;
    _status.add(s);
  }

  Future<void> _connect() async {
    if (!_running || _paused) return;
    _set(ConnectionStatus.connecting);
    try {
      final session = await api.session();
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {'authorization': 'Bearer ${session.accessToken}', 'x-skyline-app': appVersionHeader},
        pingInterval: const Duration(seconds: 25),
      );
      await channel.ready;
      if (!_running || _paused) {
        // Went to the background while connecting.
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _sub = channel.stream.listen(
        _onFrame,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
    } on SignedOutException {
      _running = false;
      _set(ConnectionStatus.offline);
      _events.add(RealtimeEvent('signed_out', null, const {}));
    } on Object {
      _onClosed();
    }
  }

  void _onFrame(Object? raw) {
    Map<String, Object?> frame;
    try {
      frame = jsonDecode(raw as String) as Map<String, Object?>;
    } on Object {
      return;
    }
    final type = frame['type'];
    if (type is! String) return;
    if (type == 'ready') {
      _attempt = 0;
      _set(ConnectionStatus.online);
      // Whatever arrived while we were away.
      _events.add(RealtimeEvent('inbox', null, const {}));
      return;
    }
    final payload = frame['payload'];
    _events.add(RealtimeEvent(
      type,
      frame['from'] as String?,
      payload is Map<String, Object?> ? payload : const {},
    ));
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _set(ConnectionStatus.offline);
    if (!_running || _paused) return;
    // 1s, 2s, 4s ... capped at 30s, with jitter so many phones do not
    // reconnect in lockstep after a server restart.
    final seconds = min(30, pow(2, _attempt).toInt());
    _attempt++;
    final jitter = Random().nextInt(1000);
    _retry = Timer(Duration(seconds: seconds, milliseconds: jitter), _connect);
  }
}
