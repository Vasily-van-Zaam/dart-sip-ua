import 'package:sip_ua/src/transports/socket_interface.dart';
import '../transports/web_socket.dart';
import 'events.dart';

class EventSocketConnected extends EventType {
  EventSocketConnected({this.socket});
  SIPUASocketInterface? socket;
}

class EventSocketConnecting extends EventType {
  EventSocketConnecting({this.socket, this.recoveryAttempt = 0});
  SIPUASocketInterface? socket;

  /// 0 = initial connect; >0 = recovery after a drop (matches SocketTransport backoff).
  int recoveryAttempt;
}

class EventSocketDisconnected extends EventType {
  EventSocketDisconnected({SIPUASocketInterface? socket, this.cause});
  SIPUASocketInterface? socket;
  ErrorCause? cause;
}

/// Emitted after a transport drop, before the next [EventSocketConnecting] (backoff timer).
class EventSocketReconnectScheduled extends EventType {
  EventSocketReconnectScheduled({this.attempt = 0, this.delaySeconds = 0});
  int attempt;
  int delaySeconds;
}

/// Emitted when max reconnection attempts are exhausted.
class EventSocketReconnectFailed extends EventType {
  EventSocketReconnectFailed({this.attempts = 0});
  int attempts;
}

/// In-call keepalive OPTIONS — первая попытка не получила ответа в срок.
/// Socket формально ещё CONNECTED, но трафик не идёт. Раннее предупреждение
/// для UI («связь нездорова») до того как sip_ua убьёт звонок по RTP Timeout
/// и до фактического DISCONNECT транспорта.
class EventCallKeepAliveDegraded extends EventType {
  EventCallKeepAliveDegraded({this.attempt = 1});
  int attempt;
}

/// In-call keepalive восстановился после серии degraded — получили 200 OK
/// (или любой SIP-ответ) на повторный OPTIONS. UI снимает «нездоровое» состояние.
class EventCallKeepAliveRecovered extends EventType {
  EventCallKeepAliveRecovered();
}
