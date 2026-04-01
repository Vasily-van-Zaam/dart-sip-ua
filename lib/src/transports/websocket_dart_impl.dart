import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  void connect(
      {Iterable<String>? protocols,
      required WebSocketSettings webSocketSettings}) async {
    _closeEmitted = false;
    handleQueue();
    logger.i('connect $_url, ${webSocketSettings.extraHeaders}, $protocols');
    try {
      final int connectTimeoutSec = webSocketSettings.connectionConnectTimeoutSec;
      final Duration connectTimeout = Duration(
          seconds: connectTimeoutSec > 0 ? connectTimeoutSec : 8);
      if (webSocketSettings.allowBadCertificate) {
        /// Allow self-signed certificate, for test only.
        _socket = await _connectForBadCertificate(_url, webSocketSettings)
            .timeout(connectTimeout);
      } else {
        _socket = await WebSocket.connect(_url,
                protocols: protocols, headers: webSocketSettings.extraHeaders)
            .timeout(connectTimeout);
      }

      onOpen?.call();
      _socket!.listen((dynamic data) {
        onMessage?.call(data);
      }, onDone: () {
        final int? code = _socket?.closeCode;
        final String reason = _socket?.closeReason ?? '';
        final bool clean = code == 1000 || code == 1001;
        _emitClose(code, reason, wasClean: clean);
      }, onError: (Object e, StackTrace _) {
        _emitClose(499, e.toString(), wasClean: false);
      });
    } on TimeoutException {
      _emitClose(408, 'connect timeout', wasClean: false);
    } catch (e) {
      _emitClose(500, e.toString(), wasClean: false);
    }
  }

  final StreamController<dynamic> queue = StreamController<dynamic>.broadcast();
  void handleQueue() async {
    queue.stream.asyncMap((dynamic event) async {
      await Future<void>.delayed(Duration(milliseconds: messageDelay));
      return event;
    }).listen((dynamic event) async {
      _socket!.add(event);
      logger.d('send: \n\n$event');
    });
  }

  void send(dynamic data) async {
    if (_socket != null) {
      queue.add(data);
    }
  }

  void close() {
    if (_socket != null) _socket!.close();
  }

  bool isConnecting() {
    return _socket != null && _socket!.readyState == WebSocket.connecting;
  }

  void _emitClose(int? code, String? reason, {required bool wasClean}) {
    if (_closeEmitted) {
      return;
    }
    _closeEmitted = true;
    onClose?.call(code, reason, wasClean: wasClean);
  }

  /// For test only.
  Future<WebSocket> _connectForBadCertificate(
      String url, WebSocketSettings webSocketSettings) async {
    try {
      Random r = Random();
      String key = base64.encode(List<int>.generate(16, (_) => r.nextInt(255)));
      SecurityContext securityContext = SecurityContext();
      HttpClient client = HttpClient(context: securityContext);

      if (webSocketSettings.userAgent != null) {
        client.userAgent = webSocketSettings.userAgent;
      }

      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
        logger.w('Allow self-signed certificate => $host:$port. ');
        return true;
      };

      Uri parsed_uri = Uri.parse(url);
      Uri uri = parsed_uri.replace(
          scheme: parsed_uri.scheme == 'wss' ? 'https' : 'http');

      HttpClientRequest request =
          await client.getUrl(uri); // form the correct url here
      request.headers.add('Connection', 'Upgrade', preserveHeaderCase: true);
      request.headers.add('Upgrade', 'websocket', preserveHeaderCase: true);
      request.headers.add('Sec-WebSocket-Version', '13',
          preserveHeaderCase: true); // insert the correct version here
      request.headers.add('Sec-WebSocket-Key', key.toLowerCase(),
          preserveHeaderCase: true);
      request.headers
          .add('Sec-WebSocket-Protocol', 'sip', preserveHeaderCase: true);

      webSocketSettings.extraHeaders.forEach((String key, dynamic value) {
        request.headers.add(key, value, preserveHeaderCase: true);
      });

      HttpClientResponse response = await request.close();
      Socket socket = await response.detachSocket();
      WebSocket webSocket = WebSocket.fromUpgradedSocket(
        socket,
        protocol: 'sip',
        serverSide: false,
      );

      return webSocket;
    } catch (e) {
      logger.e('error $e');
      rethrow;
    }
  }
}
