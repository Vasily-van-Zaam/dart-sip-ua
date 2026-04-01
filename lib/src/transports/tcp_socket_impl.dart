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

Future<Set<String>> _tcpLookupHostIpv4(String host) async {
  final Set<String> out = <String>{};
  final String h = host.trim();
  if (h.isEmpty) {
    return out;
  }
  try {
    for (final InternetAddress a in await InternetAddress.lookup(h)) {
      if (a.type == InternetAddressType.IPv4) {
        out.add(a.address);
      }
    }
  } catch (_) {
    // ignore
  }
  return out;
}

bool _tcpIfaceNameLooksLikeVpn(String? name) {
  final String n = (name ?? '').toLowerCase();
  return n.contains('vpn') ||
      n.contains('tap') ||
      n.contains('tun') ||
      n.contains('wireguard') ||
      n.contains('wg') ||
      n.contains('utun') ||
      n.contains('ppp') ||
      n.contains('ipsec');
}

/// Local IPv4 usable for SIP Contact/Via, excluding PBX IPs [peerIps].
Future<String?> _tcpPickLocalIpv4NotIn(Set<String> peerIps) async {
  try {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    InternetAddress? best;
    bool bestVpn = true;
    for (final NetworkInterface iface in interfaces) {
      final bool v = _tcpIfaceNameLooksLikeVpn(iface.name);
      for (final InternetAddress addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) {
          continue;
        }
        if (peerIps.contains(addr.address)) {
          continue;
        }
        if (best == null || (bestVpn && !v)) {
          best = addr;
          bestVpn = v;
        }
      }
    }
    return best?.address;
  } catch (_) {
    return null;
  }
}

class SIPUATcpSocketImpl {
  SIPUATcpSocketImpl(this.messageDelay, this._host, this._port);

  final String _host;
  final String _port;

  Socket? _socket;
  StreamSubscription<dynamic>? _queueSubscription;
  bool _sendDrained = false;
  /// Host for Contact/Via; may differ from [Socket.address] if the runtime
  /// reports the PBX IP (same as DNS A-record) as the local endpoint.
  String? _advertisedHost;
  OnOpenCallback? onOpen;
  OnMessageCallback? onData;
  OnCloseCallback? onClose;
  final int messageDelay;

  void connect(
      {Iterable<String>? protocols,
      required TcpSocketSettings tcpSocketSettings}) async {
    handleQueue();
    logger.i('connect $_host:$_port');
    try {
      if (tcpSocketSettings.allowBadCertificate) {
        // /// Allow self-signed certificate, for test only.
        // _socket = await _connectForBadCertificate(_url, tcpSocketSettings);
      } else {
        final String? bindHost = tcpSocketSettings.localBindHost?.trim();
        InternetAddress? bindAddr;
        if (bindHost != null && bindHost.isNotEmpty) {
          try {
            bindAddr = InternetAddress(bindHost);
          } catch (_) {
            logger.w('Ignoring invalid tcp localBindHost: $bindHost');
          }
        }
        try {
          _socket = await Socket.connect(
            _host,
            int.parse(_port),
            sourceAddress: bindAddr,
          );
        } catch (e) {
          if (bindAddr != null) {
            logger.w(
              'Socket.connect with sourceAddress=$bindHost failed ($e), retrying without bind',
            );
            _socket = await Socket.connect(
              _host,
              int.parse(_port),
            );
          } else {
            rethrow;
          }
        }
      }

      if (_socket == null) {
        onClose?.call(500, 'TCP socket not connected', wasClean: false);
        return;
      }

      final Set<String> peerIps = await _tcpLookupHostIpv4(_host);
      final String rawLocal = _socket!.address.address;
      final String remoteIp = _socket!.remoteAddress.address;
      String advertised = rawLocal;
      if (peerIps.isNotEmpty &&
          (peerIps.contains(rawLocal) || rawLocal == remoteIp)) {
        logger.w(
          'TCP socket local address $rawLocal matches PBX IP (DNS for $_host) or remote; '
          'picking another interface IP for SIP Contact/Via',
        );
        final String? bh = tcpSocketSettings.localBindHost?.trim();
        if (bh != null && bh.isNotEmpty && !peerIps.contains(bh)) {
          advertised = bh;
        } else {
          final String? picked = await _tcpPickLocalIpv4NotIn(peerIps);
          if (picked != null) {
            advertised = picked;
          }
        }
      }
      _advertisedHost = advertised;

      // Allow sends before [onOpen]: stack may emit CONNECTED and register immediately.
      _sendDrained = false;

      _socket!.listen((dynamic data) {
        onData?.call(data);
      }, onDone: () {
        _drainSendQueue();
        onClose?.call(0, 'connection closed', wasClean: true);
      }, onError: (Object e, StackTrace _) {
        _drainSendQueue();
        onClose?.call(500, e.toString(), wasClean: false);
      });

      onOpen?.call();
    } catch (e) {
      onClose?.call(500, e.toString(), wasClean: false);
    }
  }

  final StreamController<dynamic> queue =
      StreamController<dynamic>.broadcast();

  void _drainSendQueue() {
    _sendDrained = true;
    _queueSubscription?.cancel();
    _queueSubscription = null;
  }

  void handleQueue() {
    _queueSubscription?.cancel();
    _queueSubscription =
        queue.stream.asyncMap((dynamic event) async {
      await Future<void>.delayed(Duration(milliseconds: messageDelay));
      return event;
    }).listen((dynamic event) async {
      if (_sendDrained) {
        logger.d('TCP send dropped: queue drained (socket closing)');
        return;
      }
      final Socket? s = _socket;
      if (s == null) {
        logger.d('TCP send dropped: socket is null');
        return;
      }
      try {
        // Match WebSocket behavior: SIP text must be UTF-8 bytes. Using
        // `codeUnits` corrupts non-Latin1 (e.g. MESSAGE JSON) and breaks
        // Content-Length framing on the TCP byte stream.
        s.add(utf8.encode(event.toString()));
        logger.d('send: \n\n$event');
      } catch (e) {
        logger.w('TCP send failed (socket closed?): $e');
      }
    });
  }

  void send(dynamic data) async {
    if (_sendDrained || _socket == null) {
      logger.d(
        'TCP send ignored: drained=$_sendDrained socketNull=${_socket == null}',
      );
      return;
    }
    try {
      queue.add(data);
    } catch (e) {
      logger.w('TCP queue add failed: $e');
    }
  }

  void close() {
    _drainSendQueue();
    try {
      _socket?.destroy();
    } catch (_) {
      // ignore
    } finally {
      _socket = null;
    }
  }

  /// `host:port` for Via / Contact (IPv6: `[addr]:port`).
  String? get localEndpointString {
    final Socket? s = _socket;
    if (s == null) return null;
    final int port = s.port;
    final String host = _advertisedHost ?? s.address.address;
    if (host.contains(':') && !host.startsWith('[')) {
      return '[$host]:$port';
    }
    return '$host:$port';
  }
}
