import 'package:sip_ua/sip_ua.dart';
import 'package:sip_ua/src/transports/socket_interface.dart';
import '../grammar.dart';
import '../logger.dart';

import 'websocket_dart_impl.dart'
    if (dart.library.js) 'websocket_web_impl.dart';

class SIPUAWebSocket extends SIPUASocketInterface {
  SIPUAWebSocket(String url,
      {required int messageDelay,
      WebSocketSettings? webSocketSettings,
      int? weight})
      : _messageDelay = messageDelay {
    logger.d('new() [url:$url]');
    _url = url;
    _weight = weight;
    dynamic parsed_url = Grammar.parse(url, 'absoluteURI');
    if (parsed_url == -1) {
      logger.e('invalid WebSocket URI: $url');
      throw AssertionError('Invalid argument: $url');
    } else if (parsed_url.scheme != 'wss' && parsed_url.scheme != 'ws') {
      logger.e('invalid WebSocket URI scheme: ${parsed_url.scheme}');
      throw AssertionError('Invalid argument: $url');
    } else {
      String transport_scheme = webSocketSettings != null &&
              webSocketSettings.transport_scheme != null
          ? webSocketSettings.transport_scheme!.toLowerCase()
          : parsed_url.scheme;

      String port = parsed_url.port != null ? ':${parsed_url.port}' : '';
      _sip_uri = 'sip:${parsed_url.host}$port;transport=$transport_scheme';
      logger.d('SIP URI: $_sip_uri');
      _via_transport = transport_scheme.toUpperCase();
    }
    _webSocketSettings = webSocketSettings ?? WebSocketSettings();
  }
  final int _messageDelay;

  String? _url;
  String? _sip_uri;
  late String _via_transport;
  final String _websocket_protocol = 'sip';
  SIPUAWebSocketImpl? _ws;
  Future<void>? _socketCloseFuture;
  bool _closed = false;
  bool _connected = false;
  bool _disconnectEmitted = false;
  int? _weight;
  int? status;
  late WebSocketSettings _webSocketSettings;

  @override
  String get via_transport => _via_transport;

  @override
  set via_transport(String value) {
    _via_transport = value.toUpperCase();
  }

  @override
  String? get sip_uri => _sip_uri;

  @override
  int? get weight => _weight;

  @override
  String? get url => _url;

  @override
  void connect() async {
    logger.d('connect()');

    if (_url == null) {
      throw AssertionError('Invalid argument: _url');
    }

    if (isConnected()) {
      logger.d('WebSocket $_url is already connected');
      return;
    } else if (isConnecting()) {
      logger.d('WebSocket $_url is connecting');
      return;
    }
    // Do NOT call [disconnect] here: it emits [ondisconnect] and makes
    // [SocketTransport._onDisconnect] schedule a second reconnect timer while this
    // same [connect] is already running (CONNECTING). That produces back-to-back
    // recoveries and bogus rapid DISCONNECTED events. Only replace the impl.
    await _silentDisposeSocketImpl();
    logger.d('connecting to WebSocket $_url');
    try {
      _disconnectEmitted = false;
      final SIPUAWebSocketImpl impl =
          SIPUAWebSocketImpl(_url!, _messageDelay);
      _ws = impl;

      impl.onOpen = () {
        if (!identical(impl, _ws)) {
          return;
        }
        _closed = false;
        _connected = true;
        logger.d('Web Socket is now connected');
        _onOpen();
      };

      impl.onMessage = (dynamic data) {
        if (!identical(impl, _ws)) {
          return;
        }
        _onMessage(data);
      };

      impl.onClose = (int? closeCode, String? closeReason,
          {required bool wasClean}) {
        if (!identical(impl, _ws)) {
          logger.d(
              'Ignore stale WebSocket close (replaced impl) [$closeCode, $closeReason]');
          return;
        }
        logger.d('Closed [$closeCode, $closeReason] clean=$wasClean');
        _connected = false;
        _onClose(wasClean, closeCode, closeReason);
      };

      impl.connect(
          protocols: <String>[_websocket_protocol],
          webSocketSettings: _webSocketSettings);
    } catch (e, s) {
      logger.e(e.toString(), error: e, stackTrace: s);
      _connected = false;
      logger.e('WebSocket $_url error: $e');
    }
  }

  /// Closes the current native socket without notifying [ondisconnect].
  /// Used when swapping implementations during [connect]; transport already
  /// manages recovery and must not see an extra logical disconnect per attempt.
  Future<void> _awaitOutstandingSocketClose() async {
    final Future<void>? f = _socketCloseFuture;
    _socketCloseFuture = null;
    if (f != null) {
      try {
        await f;
      } catch (_) {}
    }
  }

  Future<void> _silentDisposeSocketImpl() async {
    await _awaitOutstandingSocketClose();
    if (_ws == null) {
      return;
    }
    logger.d('WebSocket silent dispose before new connect');
    final SIPUAWebSocketImpl impl = _ws!;
    _ws = null;
    try {
      // Drop listener callbacks so a late [onDone] on the old [WebSocket] cannot
      // reach [SocketTransport] / UA after the new impl is already REGISTERed.
      impl.onOpen = null;
      impl.onMessage = null;
      impl.onClose = null;
      _socketCloseFuture = impl.closeAndWaitForDone();
      await _socketCloseFuture;
    } catch (error) {
      logger.e('silent dispose | error: $error');
    } finally {
      _socketCloseFuture = null;
    }
    _connected = false;
    _closed = false;
  }

  @override
  void disconnect() {
    logger.d('disconnect()');
    if (_closed) return;
    // Don't wait for the WebSocket 'close' event, do it now.
    _closed = true;
    _connected = false;
    final SIPUAWebSocketImpl? impl = _ws;
    _ws = null;
    if (impl != null) {
      impl.onOpen = null;
      impl.onMessage = null;
      impl.onClose = null;
      _onClose(true, 0, 'Client send disconnect');
      try {
        _socketCloseFuture = impl.closeAndWaitForDone();
      } catch (error) {
        logger.e('close() | error closing the WebSocket: $error');
      }
    } else {
      _onClose(true, 0, 'Client send disconnect');
    }
  }

  @override
  bool send(dynamic message) {
    logger.d('send()');
    if (_closed) {
      throw 'transport closed';
    }
    try {
      _ws!.send(message);
      return true;
    } catch (error) {
      logger.e('send() | error sending message: $error');
      rethrow;
    }
  }

  @override
  bool isConnected() {
    return _connected;
  }

  @override
  bool isConnecting() {
    return _ws != null && _ws!.isConnecting();
  }

  /**
   * WebSocket Event Handlers
   */
  void _onOpen() {
    logger.d('WebSocket $_url connected');
    onconnect!();
  }

  void _onClose(bool wasClean, int? code, String? reason) {
    if (_disconnectEmitted) {
      return;
    }
    _disconnectEmitted = true;
    logger.d('WebSocket $_url closed');
    if (!wasClean) {
      logger.d('WebSocket abrupt disconnection');
    }
    ondisconnect!(this, !wasClean, code, reason);
  }

  void _onMessage(dynamic data) {
    logger.d('Received WebSocket message');
    if (data != null) {
      if (data.toString().trim().length > 0) {
        ondata!(data);
      } else {
        logger.d('Received and ignored empty packet');
      }
    }
  }
}
