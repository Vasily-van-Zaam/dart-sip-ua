import 'dart:convert';
import 'dart:typed_data';

import 'package:sip_ua/sip_ua.dart';
import 'package:sip_ua/src/transports/socket_interface.dart';
import 'package:sip_ua/src/transports/tcp_socket_impl.dart';
import '../logger.dart';

/// Upper bound for a single assembled SIP-over-TCP message (headers + body), in **octets**.
/// Stops unbounded RAM use if headers never complete or Content-Length is bogus.
/// Typical SIP+SDP is well below 64 KiB; 512 KiB is a generous safety margin.
const int _maxSipTcpAssembledMessageBytes = 512 * 1024;

int? _contentLengthFromHeaderSection(String headerSection) {
  int? last;
  for (final String line in headerSection.split('\r\n')) {
    // RFC 3261 §7.3.3: compact form of Content-Length is `l`.
    // If we treat SDP responses as CL:0, the TCP byte stream desyncs and
    // every following request/response looks "dead" (typical after transfer bursts).
    final RegExpMatch? m = RegExp(
      r'^\s*(?:Content-Length|l)\s*:\s*(\d+)\s*$',
      caseSensitive: false,
    ).firstMatch(line);
    if (m != null) {
      last = int.tryParse(m.group(1)!);
    }
  }
  return last;
}

/// Returns index of `\r\n\r\n` in [buf], or -1.
int _indexOfDoubleCrlf(List<int> buf) {
  final int n = buf.length;
  for (int i = 0; i + 3 < n; i++) {
    if (buf[i] == 0x0d &&
        buf[i + 1] == 0x0a &&
        buf[i + 2] == 0x0d &&
        buf[i + 3] == 0x0a) {
      return i;
    }
  }
  return -1;
}

class SIPUATcpSocket extends SIPUASocketInterface {
  SIPUATcpSocket(String host, String port,
      {required int messageDelay,
      TcpSocketSettings? tcpSocketSettings,
      int? weight})
      : _messageDelay = messageDelay {
    logger.d('new() [host:$host:$port]');
    String transport_scheme = 'tcp';
    _weight = weight;
    _host = host;
    _port = port;

    _sip_uri = 'sip:$host:$port;transport=$transport_scheme';
    logger.d('TCPC SIP URI: $_sip_uri');
    _via_transport = transport_scheme.toUpperCase();
    _tcpSocketSettings = tcpSocketSettings ?? TcpSocketSettings();
  }

  final int _messageDelay;

  String? _host;
  String? _port;
  String? _sip_uri;
  late String _via_transport;
  final String _tcp_socket_protocol = 'sip';
  SIPUATcpSocketImpl? _tcpSocketImpl;
  bool _closed = false;
  bool _connected = false;
  bool _connecting = false;
  bool _disconnectEmitted = false;
  int? _weight;
  int? status;
  late TcpSocketSettings _tcpSocketSettings;

  /// SIP over TCP: one logical message can span multiple [Socket] reads. Buffer
  /// until headers + Content-Length **octets** are complete (RFC 3261 §18.3).
  /// Uses a byte buffer so [Content-Length] matches wire octets (UTF-8 bodies).
  final List<int> _inboundBuffer = <int>[];

  @override
  String get via_transport => _via_transport;

  @override
  set via_transport(String value) {
    _via_transport = value.toUpperCase();
  }

  @override
  int? get weight => _weight;

  @override
  String? get sip_uri => _sip_uri;

  String? get host => _host;

  String? get port => _port;

  @override
  String? get localSignalingEndpoint {
    if (!_connected || _tcpSocketImpl == null) return null;
    return _tcpSocketImpl!.localEndpointString;
  }

  @override
  void connect() async {
    logger.d('connect()');

    if (_host == null) {
      throw AssertionError('Invalid argument: _host');
    }
    if (_port == null) {
      throw AssertionError('Invalid argument: _port');
    }

    if (isConnected()) {
      logger.d('TCPSocket $_host:$_port is already connected');
      return;
    } else if (isConnecting()) {
      logger.d('TCPSocket $_host:$_port is connecting');
      return;
    }
    if (_tcpSocketImpl != null) {
      disconnect();
    }
    logger.d('connecting to TcpSocket $_host:$_port');
    _connecting = true;
    try {
      _disconnectEmitted = false;
      _tcpSocketImpl = SIPUATcpSocketImpl(
          _messageDelay, _host ?? '0.0.0.0', _port ?? '5060');

      _tcpSocketImpl!.onOpen = () {
        _closed = false;
        _connected = true;
        _connecting = false;
        _inboundBuffer.clear();
        logger.d('Tcp Socket is now connected?');
        _onOpen();
      };

      _tcpSocketImpl!.onData = (dynamic data) {
        _onMessage(data);
      };

      _tcpSocketImpl!.onClose = (int? closeCode, String? closeReason,
          {required bool wasClean}) {
        logger.d('Closed [$closeCode, $closeReason] clean=$wasClean');
        _connected = false;
        _connecting = false;
        _onClose(wasClean, closeCode, closeReason);
      };

      _tcpSocketImpl!.connect(
          protocols: <String>[_tcp_socket_protocol],
          tcpSocketSettings: _tcpSocketSettings);
    } catch (e, s) {
      logger.e(e.toString(), stackTrace: s);
      _connected = false;
      _connecting = false;
      logger.e('TcpSocket error: $e');
    }
  }

  @override
  void disconnect() {
    logger.d('disconnect()');
    if (_closed) return;
    // Don't wait for the WebSocket 'close' event, do it now.
    _closed = true;
    _connected = false;
    _connecting = false;
    _inboundBuffer.clear();
    _onClose(true, 0, 'Client send disconnect');
    try {
      if (_tcpSocketImpl != null) {
        _tcpSocketImpl!.close();
        _tcpSocketImpl = null;
      }
    } catch (error) {
      logger.e('close() | error closing the TcpSocket: $error');
      _tcpSocketImpl = null;
    }
  }

  @override
  bool send(dynamic message) {
    logger.d('send()');
    if (_closed) {
      throw 'transport closed';
    }
    try {
      _tcpSocketImpl!.send(message);
      return true;
    } catch (error) {
      logger.e('send() | error sending message: $error');
      rethrow;
    }
  }

  @override
  bool isConnected() => _connected;

  /**
   * TcpSocket Event Handlers
   */
  void _onOpen() {
    logger.d('TcpSocket $_host:$port connected');
    onconnect!();
  }

  void _onClose(bool wasClean, int? code, String? reason) {
    if (_disconnectEmitted) {
      return;
    }
    _disconnectEmitted = true;
    logger.d('TcpSocket $_host:$port closed');
    if (!wasClean) {
      logger.d('TcpSocket abrupt disconnection');
    }
    ondisconnect!(this, !wasClean, code, reason);
  }

  Uint8List _chunkToBytes(dynamic data) {
    if (data is Uint8List) {
      return data;
    }
    if (data is List<int>) {
      return Uint8List.fromList(data);
    }
    if (data is String) {
      return Uint8List.fromList(utf8.encode(data));
    }
    return Uint8List.fromList(utf8.encode(data.toString()));
  }

  void _onMessage(dynamic data) {
    logger.d('Received TcpSocket data');
    if (data == null) {
      return;
    }
    final Uint8List chunk = _chunkToBytes(data);
    if (chunk.isEmpty) {
      logger.d('Received and ignored empty packet');
      return;
    }
    _inboundBuffer.addAll(chunk);
    if (_inboundBuffer.length > _maxSipTcpAssembledMessageBytes) {
      logger.w(
          'SIP TCP inbound assembly buffer exceeded '
          '$_maxSipTcpAssembledMessageBytes bytes; resetting (stream may need reconnect)');
      _inboundBuffer.clear();
      return;
    }

    while (true) {
      if (_inboundBuffer.length >= 2 &&
          _inboundBuffer[0] == 0x0d &&
          _inboundBuffer[1] == 0x0a) {
        _inboundBuffer.removeRange(0, 2);
        continue;
      }
      if (_inboundBuffer.isEmpty) {
        break;
      }

      final int headerEnd = _indexOfDoubleCrlf(_inboundBuffer);
      if (headerEnd < 0) {
        break;
      }

      final String headerPart =
          utf8.decode(_inboundBuffer.sublist(0, headerEnd), allowMalformed: true);
      final int bodyLen = _contentLengthFromHeaderSection(headerPart) ?? 0;
      if (bodyLen > _maxSipTcpAssembledMessageBytes) {
        logger.w(
            'SIP TCP Content-Length $bodyLen exceeds cap '
            '$_maxSipTcpAssembledMessageBytes; resetting assembly buffer');
        _inboundBuffer.clear();
        return;
      }
      final int totalLen = headerEnd + 4 + bodyLen;
      if (_inboundBuffer.length < totalLen) {
        break;
      }

      final String message =
          utf8.decode(_inboundBuffer.sublist(0, totalLen), allowMalformed: true);
      _inboundBuffer.removeRange(0, totalLen);
      if (message.trim().isNotEmpty) {
        ondata!(message);
      }
    }
  }

  @override
  bool isConnecting() => _connecting;

  @override
  String? get url {
    if (_host == null || _port == null) {
      return null;
    }
    return '$_host:$_port';
  }
}
