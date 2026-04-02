import 'dart:async';
import 'dart:html';
import 'dart:js_util' as JSUtils;

import 'package:sip_ua/src/sip_ua_helper.dart';
import '../logger.dart';

typedef OnMessageCallback = void Function(dynamic msg);
typedef OnCloseCallback = void Function(int? code, String? reason,
    {required bool wasClean});
typedef OnOpenCallback = void Function();

class SIPUAWebSocketImpl {
  SIPUAWebSocketImpl(this._url, this.messageDelay);

  final String _url;
  WebSocket? _socket;
  OnOpenCallback? onOpen;
  OnMessageCallback? onMessage;
  OnCloseCallback? onClose;
  final int messageDelay;
  bool _closeEmitted = false;
  Timer? _connectTimeoutTimer;

  void connect(
      {Iterable<String>? protocols,
      required WebSocketSettings webSocketSettings}) async {
    _closeEmitted = false;
    logger.i('connect $_url, ${webSocketSettings.extraHeaders}, $protocols');
    try {
      final int connectTimeoutSec = webSocketSettings.connectionConnectTimeoutSec;
      final Duration connectTimeout =
          Duration(seconds: connectTimeoutSec > 0 ? connectTimeoutSec : 8);
      _socket = WebSocket(_url, 'sip');
      _connectTimeoutTimer?.cancel();
      _connectTimeoutTimer = Timer(connectTimeout, () {
        if (_socket != null && _socket!.readyState == WebSocket.CONNECTING) {
          try {
            _socket!.close();
          } catch (_) {}
          _emitClose(408, 'connect timeout', wasClean: false);
        }
      });
      _socket!.onOpen.listen((Event e) {
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        onOpen?.call();
      });

      _socket!.onMessage.listen((MessageEvent e) async {
        if (e.data is Blob) {
          dynamic arrayBuffer = await JSUtils.promiseToFuture(
              JSUtils.callMethod(e.data, 'arrayBuffer', <Object>[]));
          String message = String.fromCharCodes(arrayBuffer.asUint8List());
          onMessage?.call(message);
        } else {
          onMessage?.call(e.data);
        }
      });

      _socket!.onClose.listen((CloseEvent e) {
        _connectTimeoutTimer?.cancel();
        _connectTimeoutTimer = null;
        _emitClose(e.code, e.reason, wasClean: e.wasClean ?? false);
      });
    } catch (e) {
      _connectTimeoutTimer?.cancel();
      _connectTimeoutTimer = null;
      _emitClose(0, e.toString(), wasClean: false);
    }
  }

  void send(dynamic data) {
    if (_socket != null && _socket!.readyState == WebSocket.OPEN) {
      _socket!.send(data);
      logger.d('send: \n\n$data');
    } else {
      logger.e('WebSocket not connected, message $data not sent');
    }
  }

  bool isConnecting() {
    return _socket != null && _socket!.readyState == WebSocket.CONNECTING;
  }

  void close() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
    _socket?.close();
  }

  /// Same contract as [dart:io] impl: wait until the browser has finished the
  /// close handshake before opening another socket (see SIPUAWebSocket wrapper).
  Future<void> closeAndWaitForDone({
    Duration waitForDone = const Duration(seconds: 3),
  }) async {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
    final WebSocket? s = _socket;
    _socket = null;
    if (s == null) {
      return;
    }
    final Completer<void> done = Completer<void>();
    late final StreamSubscription<dynamic> sub;
    sub = s.onClose.listen((dynamic _) {
      if (!done.isCompleted) {
        done.complete();
      }
    });
    try {
      s.close();
    } catch (_) {}
    try {
      await done.future.timeout(waitForDone);
    } on TimeoutException {
      logger.w(
          'WebSocket close wait timed out after ${waitForDone.inMilliseconds}ms');
    } catch (_) {}
    try {
      await sub.cancel();
    } catch (_) {}
  }

  void _emitClose(int? code, String? reason, {required bool wasClean}) {
    if (_closeEmitted) {
      return;
    }
    _closeEmitted = true;
    onClose?.call(code, reason, wasClean: wasClean);
  }
}
