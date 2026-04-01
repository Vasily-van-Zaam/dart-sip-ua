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
