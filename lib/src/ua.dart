import 'dart:async';

import 'package:sip_ua/src/transport_type.dart';
import 'package:sip_ua/src/transports/socket_interface.dart';
import 'config.dart' as config;
import 'config.dart';
import 'constants.dart' as DartSIP_C;
import 'constants.dart';
import 'data.dart';
import 'dialog.dart';
import 'event_manager/event_manager.dart';
import 'event_manager/internal_events.dart';
import 'exceptions.dart' as Exceptions;
import 'logger.dart';
import 'message.dart';
import 'options.dart';
import 'parser.dart' as Parser;
import 'registrator.dart';
import 'rtc_session.dart';
import 'sanity_check.dart';
import 'sip_message.dart';
import 'socket_transport.dart';
import 'subscriber.dart';
import 'timers.dart';
import 'transactions/invite_client.dart';
import 'transactions/invite_server.dart';
import 'transactions/non_invite_client.dart';
import 'transactions/non_invite_server.dart';
import 'transactions/transaction_base.dart';
import 'transactions/transactions.dart';
import 'transports/web_socket.dart';
import 'uri.dart';
import 'utils.dart' as Utils;

/// Parse TCP local bind `[ipv6]:port` or `ipv4:port`.
MapEntry<String, int>? _parseLocalSignalingEndpoint(String ep) {
  if (ep.startsWith('[')) {
    final int close = ep.indexOf(']:');
    if (close < 0) return null;
    final String host = ep.substring(1, close);
    final int? p = int.tryParse(ep.substring(close + 2));
    if (p == null) return null;
    return MapEntry<String, int>(host, p);
  }
  final int last = ep.lastIndexOf(':');
  if (last <= 0) return null;
  final String host = ep.substring(0, last);
  final int? p = int.tryParse(ep.substring(last + 1));
  if (p == null || host.isEmpty) return null;
  return MapEntry<String, int>(host, p);
}

class C {
  // UA status codes.
  static const int STATUS_INIT = 0;
  static const int STATUS_READY = 1;
  static const int STATUS_USER_CLOSED = 2;
  static const int STATUS_NOT_READY = 3;

  // UA error codes.
  static const int CONFIGURATION_ERROR = 1;
  static const int NETWORK_ERROR = 2;
}

// TODO(Perondas): Figure out what this is
final bool hasRTCPeerConnection = true;

class DynamicSettings {
  bool? register = false;
}

class Contact {
  Contact(this.uri);

  String? pub_gruu;
  String? temp_gruu;
  bool anonymous = false;
  bool outbound = false;
  URI? uri;

  @override
  String toString() {
    String contact = '<';

    if (anonymous) {
      contact += temp_gruu ?? 'sip:anonymous@anonymous.invalid;transport=ws';
    } else {
      contact += pub_gruu ?? uri.toString();
    }

    if (outbound && (anonymous ? temp_gruu == null : pub_gruu == null)) {
      contact += ';ob';
    }

    contact += '>';
    return contact;
  }
}

/**
 * The User-Agent class.
 * @class DartSIP.UA
 * @param {Object} configuration Configuration parameters.
 * @throws {DartSIP.Exceptions.ConfigurationError} If a configuration parameter is invalid.
 * @throws {TypeError} If no configuration is given.
 */
class UA extends EventManager {
  UA(Settings configuration) {
    logger.d('new() [configuration:${configuration.toString()}]');
    // Load configuration.
    try {
      _loadConfig(configuration);
    } catch (e) {
      _status = C.STATUS_NOT_READY;
      _error = C.CONFIGURATION_ERROR;
      rethrow;
    }

    // Initialize registrator.
    _registrator = Registrator(this);
  }

  final Map<String?, Subscriber> _subscribers = <String?, Subscriber>{};
  final Map<String, dynamic> _cache = <String, dynamic>{
    'credentials': <dynamic>{}
  };

  final Settings _configuration = Settings();
  DynamicSettings? _dynConfiguration = DynamicSettings();

  final Map<String, Dialog> _dialogs = <String, Dialog>{};

  // User actions outside any session/dialog (MESSAGE/OPTIONS).
  final Set<Applicant> _applicants = <Applicant>{};

  final Map<String?, RTCSession> _sessions = <String?, RTCSession>{};
  SocketTransport? _socketTransport;
  Contact? _contact;
  int _status = C.STATUS_INIT;
  int? _error;
  late TransactionBag _transactions;

// Custom UA empty object for high level use.
  final Map<String, dynamic> _data = <String, dynamic>{};

  Timer? _closeTimer;
  late Registrator _registrator;

  int get status => _status;

  Contact? get contact => _contact;

  Settings get configuration => _configuration;

  SocketTransport? get socketTransport => _socketTransport;

  TransactionBag get transactions => _transactions;

  /// Count of sessions that are not fully ended (includes early + confirmed dialogs).
  int get activeSessionCount =>
      _sessions.values.where((RTCSession s) => !s.isEnded()).length;

  // Flag that indicates whether UA is currently stopping
  bool _stopping = false;
  DateTime _lastTransportActivityAt = DateTime.now();
  Timer? _transportOptionsProbeTimer;
  Timer? _transportOptionsProbeResponseTimer;
  Options? _transportOptionsProbeInFlight;
  SIPUASocketInterface? _transportOptionsProbeSocket;
  int _transportOptionsProbeAttempt = 0;
  Timer? _callKeepAliveTimer;
  Timer? _callKeepAliveResponseTimer;
  Options? _callKeepAliveInFlight;
  int _callKeepAliveAttempt = 0;
  Timer? _postReconnectRegisterTimer;
  bool _pendingPostReconnectRegister = false;

  void _cancelPostReconnectRegisterTimer() {
    _postReconnectRegisterTimer?.cancel();
    _postReconnectRegisterTimer = null;
  }

  // ============
  //  High Level API
  // ============

  /**
   * Connect to the server if status = STATUS_INIT.
   * Resume UA after being closed.
   */
  void start() {
    logger.d('start()');

    _transactions = TransactionBag();

    if (_status == C.STATUS_INIT) {
      _socketTransport!.connect();
    } else if (_status == C.STATUS_USER_CLOSED) {
      logger.d('restarting UA');

      // Disconnect.
      if (_closeTimer != null) {
        clearTimeout(_closeTimer);
        _closeTimer = null;
        _socketTransport!.disconnect();
      }

      // Reconnect.
      _status = C.STATUS_INIT;
      _socketTransport!.connect();
    } else if (_status == C.STATUS_READY) {
      logger.d('UA is in READY status, not restarted');
    } else {
      logger.d(
          'ERROR: connection is down, Auto-Recovery system is trying to reconnect');
    }

    // Set dynamic configuration.
    _dynConfiguration!.register = _configuration.register;
  }

  /**
   * Register.
   */
  void register() {
    logger.d('register()');
    _dynConfiguration!.register = true;
    _registrator.register();
  }

  /**
   * Unregister.
   */
  void unregister({bool all = false}) {
    logger.d('unregister()');

    _dynConfiguration!.register = false;
    _registrator.unregister(all);
  }

  /**
   * Create subscriber instance
   */
  Subscriber subscribe(
    String target,
    String eventName,
    String accept, [
    int expires = 900,
    String? contentType,
    String? allowEvents,
    Map<String, dynamic> requestParams = const <String, dynamic>{},
    List<String> extraHeaders = const <String>[],
  ]) {
    logger.d('subscribe()');

    return Subscriber(this, target, eventName, accept, expires, contentType,
        allowEvents, requestParams, extraHeaders);
  }

  /**
   * Get the Registrator instance.
   */
  Registrator? registrator() {
    return _registrator;
  }

  /**
   * Registration state.
   */
  bool isRegistered() {
    return _registrator.registered;
  }

  /**
   * Connection state.
   */
  bool isConnected() {
    return _socketTransport!.isConnected();
  }

  /**
   * Make an outgoing call.
   *
   * -param {String} target
   * -param {Object} [options]
   *
   * -throws {TypeError}
   *
   */
  RTCSession call(String target, Map<String, dynamic> options) {
    logger.d('call()');
    RTCSession session = RTCSession(this);
    session.connect(target, options);
    return session;
  }

  /**
   * Send a message.
   *
   * -param {String} target
   * -param {String} body
   * -param {Object} [options]
   *
   * -throws {TypeError}
   *
   */
  Message sendMessage(String target, String body, Map<String, dynamic>? options,
      Map<String, dynamic>? params) {
    logger.d('sendMessage()');
    Message message = Message(this);
    message.send(target, body, options, params);
    return message;
  }

  /**
   * Send a Options.
   *
   * -param {String} target
   * -param {String} body
   * -param {Object} [options]
   *
   * -throws {TypeError}
   *
   */
  Options sendOptions(
      String target, String body, Map<String, dynamic>? options) {
    logger.d('sendOptions()');
    Options message = Options(this);
    message.send(target, body, options);
    return message;
  }

  /**
   * Terminate ongoing sessions.
   */
  void terminateSessions(Map<String, dynamic> options) {
    logger.d('terminateSessions()');
    _sessions.forEach((String? key, _) {
      if (!_sessions[key]!.isEnded()) {
        _sessions[key]!.terminate(options);
      }
    });
  }

  /**
   * Gracefully close.
   *
   */
  void stop() {
    logger.d('stop()');
    _stopTransportOptionsProbe();
    _stopCallKeepAlive();
    _cancelPostReconnectRegisterTimer();

    // Keep dynamic settings object to avoid null deref on late transport callbacks.
    _dynConfiguration ??= DynamicSettings();

    if (_status == C.STATUS_USER_CLOSED) {
      logger.d('UA already closed');

      return;
    }

    // Close registrator.
    _registrator.close();

    // If there are session wait a bit so CANCEL/BYE can be sent and their responses received.
    int num_sessions = _sessions.length;

    // Run  _terminate_ on every Session.
    _sessions.forEach((String? key, _) {
      if (_sessions.containsKey(key)) {
        logger.d('closing session $key');
        try {
          RTCSession rtcSession = _sessions[key]!;
          if (!rtcSession.isEnded()) {
            rtcSession.terminate();
          }
        } catch (e, s) {
          logger.e(e.toString(), error: e, stackTrace: s);
        }
      }
    });

    // Run _terminate on ever subscription
    _subscribers.forEach((String? key, _) {
      if (_subscribers.containsKey(key)) {
        logger.d('closing subscription $key');
        try {
          Subscriber subscriber = _subscribers[key]!;
          subscriber.terminate(null);
        } catch (e, s) {
          logger.e(e.toString(), error: e, stackTrace: s);
        }
      }
    });

    _stopping = true;

    // Run  _close_ on every applicant.
    for (Applicant applicant in _applicants) {
      try {
        applicant.close();
      } catch (error) {}
    }

    _status = C.STATUS_USER_CLOSED;

    int num_transactions = _transactions.countTransactions();
    if (num_transactions == 0 && num_sessions == 0) {
      _socketTransport!.disconnect();
    } else {
      _closeTimer = setTimeout(() {
        logger.i('Closing connection');
        _closeTimer = null;
        _socketTransport!.disconnect();
      }, 2000);
    }
  }

  /**
   * Normalice a string into a valid SIP request URI
   * -param {String} target
   * -returns {DartSIP.URI|null}
   */
  URI? normalizeTarget(String? target) {
    return Utils.normalizeTarget(target, _configuration.hostport_params);
  }

  /**
   * Allow retrieving configuration and autogenerated fields in runtime.
   */
  String? get(String parameter) {
    switch (parameter) {
      case 'realm':
        return _configuration.realm;

      case 'ha1':
        return _configuration.ha1;

      default:
        logger.e('get() | cannot get "$parameter" parameter in runtime');

        return null;
    }
  }

  /**
   * Allow configuration changes in runtime.
   * Returns true if the parameter could be set.
   */
  bool set(String parameter, dynamic value) {
    switch (parameter) {
      case 'password':
        {
          _configuration.password = value.toString();
          break;
        }

      case 'realm':
        {
          _configuration.realm = value.toString();
          break;
        }

      case 'ha1':
        {
          _configuration.ha1 = value.toString();
          // Delete the plain SIP password.
          _configuration.password = null;
          break;
        }

      case 'display_name':
        {
          _configuration.display_name = value;
          break;
        }

      case 'uri':
        {
          _configuration.uri = value;
          break;
        }

      default:
        logger.e('set() | cannot set "$parameter" parameter in runtime');

        return false;
    }

    return true;
  }

  // ==================
  // Event Handlers.
  // ==================

  /**
   * Transaction
   */
  void newTransaction(TransactionBase transaction) {
    _transactions.addTransaction(transaction);
    emit(EventNewTransaction(transaction: transaction));
  }

  /**
   * Transaction destroyed.
   */
  void destroyTransaction(TransactionBase transaction) {
    _transactions.removeTransaction(transaction);
    emit(EventTransactionDestroyed(transaction: transaction));
  }

  /**
   * Subscriber
   */
  void newSubscriber({required Subscriber sub}) {
    _subscribers[sub.id] = sub;
  }

  /**
   * Subscriber destroyed.
   */
  void destroySubscriber(Subscriber sub) {
    _subscribers.remove(sub.id);
  }

  /**
   * Dialog
   */
  void newDialog(Dialog dialog) {
    _dialogs[dialog.id.toString()] = dialog;
  }

  /**
   * Dialog destroyed.
   */
  void destroyDialog(Dialog dialog) {
    _dialogs.remove(dialog.id.toString());
  }

  /**
   *  Message
   */
  void newMessage(Message message, String originator, dynamic request) {
    if (_stopping) {
      return;
    }
    _applicants.add(message);
    emit(EventNewMessage(
        message: message, originator: originator, request: request));
  }

  /**
   *  Options
   */
  void newOptions(Options message, String originator, dynamic request) {
    if (_stopping) {
      return;
    }
    _applicants.add(message);

    emit(EventNewOptions(
        message: message, originator: originator, request: request));
  }

  /**
   *  Message destroyed.
   */
  void destroyMessage(Message message) {
    if (_stopping) {
      return;
    }
    _applicants.remove(message);
  }

  /**
   *  Options destroyed.
   */
  void destroyOptions(Options message) {
    if (_stopping) {
      return;
    }
    _applicants.remove(message);
  }

  /**
   * RTCSession
   */
  void newRTCSession(
      {required RTCSession session, String? originator, dynamic request}) {
    _sessions[session.id] = session;
    emit(EventNewRTCSession(
        session: session, originator: originator, request: request));
    _startCallKeepAlive();
  }

  /**
   * RTCSession destroyed.
   */
  void destroyRTCSession(RTCSession session) {
    _sessions.remove(session.id);
    if (activeSessionCount == 0) {
      _stopCallKeepAlive();
    }
  }

  /**
   * Registered
   */
  void registered({required dynamic response}) {
    emit(EventRegistered(
        cause: ErrorCause(
            cause: 'registered',
            status_code: response.status_code,
            reason_phrase: response.reason_phrase)));
  }

  /**
   * Unregistered
   */
  void unregistered({dynamic response, String? cause}) {
    emit(EventUnregister(
        cause: ErrorCause(
            cause: cause ?? 'unregistered',
            status_code: response?.status_code ?? 0,
            reason_phrase: response?.reason_phrase ?? '')));
  }

  /**
   * Registration Failed
   */
  void registrationFailed({required dynamic response, String? cause}) {
    emit(EventRegistrationFailed(
        cause: ErrorCause(
            cause: Utils.sipErrorCause(response.status_code),
            status_code: response.status_code,
            reason_phrase: response.reason_phrase)));
  }

  // =================
  // ReceiveRequest.
  // =================

  /**
   * Request reception
   */
  void receiveRequest(IncomingRequest request) {
    DartSIP_C.SipMethod? method = request.method;

    // Check that request URI points to us.
    if (request.ruri!.user != _configuration.uri.user &&
        request.ruri!.user != _contact!.uri!.user) {
      logger.d('Request-URI does not point to us');
      if (request.method != SipMethod.ACK) {
        request.reply_sl(404);
      }

      return;
    }

    // Check request URI scheme.
    if (request.ruri!.scheme == DartSIP_C.SIPS) {
      request.reply_sl(416);

      return;
    }

    // Check transaction.
    if (checkTransaction(_transactions, request)) {
      return;
    }

    // Create the server transaction.
    if (method == SipMethod.INVITE) {
      /* eslint-disable no-*/
      InviteServerTransaction(this, _socketTransport, request);
      /* eslint-enable no-*/
    } else if (method != SipMethod.ACK && method != SipMethod.CANCEL) {
      /* eslint-disable no-*/
      NonInviteServerTransaction(this, _socketTransport, request);
      /* eslint-enable no-*/
    }

    /* RFC3261 12.2.2
     * Requests that do not change in any way the state of a dialog may be
     * received within a dialog (for example, an OPTIONS request).
     * They are processed as if they had been received outside the dialog.
     */
    if (method == SipMethod.OPTIONS) {
      if (!hasListeners(EventNewOptions())) {
        request.reply(200);
        return;
      }
      Options message = Options(this);
      message.init_incoming(request);
      return;
    } else if (method == SipMethod.MESSAGE) {
      if (!hasListeners(EventNewMessage())) {
        request.reply(405);
        return;
      }
      Message message = Message(this);
      message.init_incoming(request);
      return;
    } else if (method == SipMethod.INVITE) {
      // Initial INVITE.
      if (request.to_tag != null && !hasListeners(EventNewRTCSession())) {
        request.reply(405);

        return;
      }
    } else if (method == SipMethod.SUBSCRIBE) {
      // ignore: collection_methods_unrelated_type
      if (listeners['newSubscribe'] == null) {
        request.reply(405);

        return;
      }
    }

    Dialog? dialog;
    RTCSession? session;

    // Initial Request.
    if (request.to_tag == null) {
      switch (method) {
        case SipMethod.INVITE:
          if (hasRTCPeerConnection) {
            if (request.hasHeader('replaces')) {
              ParsedData replaces = request.replaces;

              dialog = _findDialog(
                  replaces.call_id, replaces.from_tag!, replaces.to_tag!);
              if (dialog != null) {
                session = dialog.owner as RTCSession?;
                if (!session!.isEnded()) {
                  session.receiveRequest(request);
                } else {
                  request.reply(603);
                }
              } else {
                request.reply(481);
              }
            } else {
              session = RTCSession(this);
              session.init_incoming(request);
            }
          } else {
            logger.e('INVITE received but WebRTC is not supported');
            request.reply(488);
          }
          break;
        case SipMethod.BYE:
          // Out of dialog BYE received.
          request.reply(481);
          break;
        case SipMethod.CANCEL:
          session =
              _findSession(request.call_id!, request.from_tag, request.to_tag);
          if (session != null) {
            session.receiveRequest(request);
          } else {
            logger.d('received CANCEL request for a non existent session');
          }
          break;
        case SipMethod.ACK:
          /* Absorb it.
           * ACK request without a corresponding Invite Transaction
           * and without To tag.
           */
          break;
        case SipMethod.NOTIFY:
          // Receive sip event.
          emit(EventSipEvent(request: request));
          request.reply(200);
          break;
        case SipMethod.SUBSCRIBE:
          emit(EventOnNewSubscribe(request: request));
          break;
        default:
          request.reply(405);
          break;
      }
    }
    // In-dialog request.
    else {
      dialog =
          _findDialog(request.call_id!, request.from_tag!, request.to_tag!);

      if (dialog != null) {
        dialog.receiveRequest(request);
      } else if (method == SipMethod.NOTIFY) {
        Subscriber? sub = _findSubscriber(
            request.call_id!, request.from_tag!, request.to_tag!);
        if (sub != null) {
          sub.receiveRequest(request);
        } else {
          logger.d('received NOTIFY request for a non existent subscription');
          request.reply(481, 'Subscription does not exist');
        }
      }

      /* RFC3261 12.2.2
       * Request with to tag, but no matching dialog found.
       * Exception: ACK for an Invite request for which a dialog has not
       * been created.
       */
      else if (method != SipMethod.ACK) {
        request.reply(481);
      }
    }
  }

  // ============
  // Utils.
  // ============

  Subscriber? _findSubscriber(String call_id, String from_tag, String to_tag) {
    String id = call_id;
    Subscriber? sub = _subscribers[id];

    return sub;
  }

  /**
   * Get the session to which the request belongs to, if any.
   */
  RTCSession? _findSession(String call_id, String? from_tag, String? to_tag) {
    String sessionIDa = call_id + (from_tag ?? '');
    RTCSession? sessionA = _sessions[sessionIDa];
    String sessionIDb = call_id + (to_tag ?? '');
    RTCSession? sessionB = _sessions[sessionIDb];

    if (sessionA != null) {
      return sessionA;
    } else if (sessionB != null) {
      return sessionB;
    } else {
      return null;
    }
  }

  /**
   * Get the dialog to which the request belongs to, if any.
   */
  Dialog? _findDialog(String call_id, String from_tag, String to_tag) {
    String id = call_id + from_tag + to_tag;
    Dialog? dialog = _dialogs[id];

    if (dialog != null) {
      return dialog;
    } else {
      id = call_id + to_tag + from_tag;
      dialog = _dialogs[id];
      if (dialog != null) {
        return dialog;
      } else {
        return null;
      }
    }
  }

  void _loadConfig(Settings configuration) {
    // Check and load the given configuration.
    try {
      config.load(configuration, _configuration);
    } catch (e) {
      rethrow;
    }

    // Post Configuration Process.

    // Allow passing 0 number as display_name.
    if (_configuration.display_name is num &&
        (_configuration.display_name as num?) == 0) {
      _configuration.display_name = '0';
    }

    // Instance-id for GRUU.
    _configuration.instance_id ??= Utils.newUUID();

    // Jssip_id instance parameter. Static random tag of length 5.
    _configuration.jssip_id = Utils.createRandomToken(5);

    // String containing _configuration.uri without scheme and user.
    URI hostport_params = _configuration.uri.clone();

    _configuration.terminateOnAudioMediaPortZero =
        configuration.terminateOnAudioMediaPortZero;

    hostport_params.user = null;
    _configuration.hostport_params = hostport_params
        .toString()
        .replaceAll(RegExp(r'sip:', caseSensitive: false), '');

    // Websockets Transport

    try {
      _socketTransport = SocketTransport(_configuration.sockets!, <String, int>{
        // Recovery options.
        'max_interval': _configuration.connection_recovery_max_interval,
        'min_interval': _configuration.connection_recovery_min_interval
      });

      // Transport event callbacks.
      _socketTransport!.onconnecting = onTransportConnecting;
      _socketTransport!.onconnect = onTransportConnect;
      _socketTransport!.ondisconnect = onTransportDisconnect;
      _socketTransport!.ondata = onTransportData;
      _socketTransport!.onReconnectScheduled = onTransportReconnectScheduled;
    } catch (e) {
      logger.e('Failed to _loadConfig: ${e.toString()}');
      throw Exceptions.ConfigurationError('sockets', _configuration.sockets);
    }

    // Remove sockets instance from configuration object.
    // TODO(cloudwebrtc):  need dispose??
    _configuration.sockets = null;

    // Check whether authorization_user is explicitly defined.
    // Take '_configuration.uri.user' value if not.
    _configuration.authorization_user ??= _configuration.uri.user;

    // If no 'registrar_server' is set use the 'uri' value without user portion and
    // without URI params/headers.
    if (_configuration.registrar_server == null) {
      URI registrar_server = _configuration.uri.clone();
      registrar_server.user = null;
      registrar_server.clearParams();
      registrar_server.clearHeaders();
      _configuration.registrar_server = registrar_server;
    }

    // User no_answer_timeout.
    _configuration.no_answer_timeout *= 1000;

    //Default transport initialization
    String transport = _configuration.transportType?.name ?? 'WS';

    //Override transport from socket
    if (transport == 'WS' && _socketTransport != null) {
      transport = _socketTransport!.via_transport;
    }

    // Via Host.
    //
    // If `contact_uri` is explicitly set to the same host as the AOR / registrar
    // (typical: `sip:user@pbx.example.com`), copying that host into Via breaks
    // client-initiated TCP/TLS flows: Via would name the PBX, not this endpoint.
    // Keep the default `...invalid` via_host so the server can stamp
    // `received` / `rport` and correlate inbound signaling with this connection.
    if (_configuration.contact_uri != null) {
      final dynamic cu = _configuration.contact_uri;
      if (cu is URI) {
        final String contactHost = cu.host;
        final String aorHost = _configuration.uri.host;
        final dynamic reg = _configuration.registrar_server;
        String? regHost;
        if (reg is URI) {
          regHost = reg.host;
        }
        final bool contactIsRegistrarDomain = contactHost == aorHost ||
            (regHost != null && contactHost == regHost);
        if (!contactIsRegistrarDomain) {
          _configuration.via_host = contactHost;
        }
      }
    }
    // Contact URI.
    else {
      _configuration.contact_uri = URI(
          'sip',
          Utils.createRandomToken(8),
          _configuration.via_host,
          null,
          <dynamic, dynamic>{'transport': transport});
    }
    _contact = Contact(_configuration.contact_uri);
    return;
  }

  /**
   * Transport event handlers
   */

// Transport connecting event.
  void onTransportConnecting(SIPUASocketInterface? socket, int? attempts) {
    logger.d('Transport connecting (recoveryAttempt: ${attempts ?? 0})');
    emit(EventSocketConnecting(
        socket: socket, recoveryAttempt: attempts ?? 0));
  }

  void onTransportReconnectScheduled(int attempt, int delaySeconds) {
    logger.d('Transport reconnect scheduled in ${delaySeconds}s (attempt $attempt)');
    emit(EventSocketReconnectScheduled(
        attempt: attempt, delaySeconds: delaySeconds));
  }

// Transport connected event.
  void onTransportConnect(SocketTransport transport) {
    logger.d('Transport connected');
    if (_status == C.STATUS_USER_CLOSED) {
      return;
    }
    _status = C.STATUS_READY;
    _error = null;

    emit(EventSocketConnected(socket: transport.socket));
    _lastTransportActivityAt = DateTime.now();
    _startTransportOptionsProbe();

    final String? localEp = transport.socket.localSignalingEndpoint;
    if (localEp != null && _configuration.transportType == TransportType.TCP) {
      _configuration.via_host = localEp;
      final MapEntry<String, int>? parsed =
          _parseLocalSignalingEndpoint(localEp);
      final String? user = _configuration.uri.user;
      if (parsed != null && user != null) {
        _configuration.contact_uri = URI(
          'sip',
          user,
          parsed.key,
          parsed.value,
          <dynamic, dynamic>{'transport': 'tcp'},
        );
        _contact = Contact(_configuration.contact_uri);
      }
    }

    if (_dynConfiguration!.register!) {
      // Use [register] so subclasses (e.g. OAuth headers) can hook the path.
      _cancelPostReconnectRegisterTimer();
      final int delayMs = _configuration.post_reconnect_register_delay_ms;
      if (delayMs > 0 && _pendingPostReconnectRegister) {
        _pendingPostReconnectRegister = false;
        logger.d(
            'register() in ${delayMs}ms after transport recovery (post_reconnect_register_delay_ms)');
        _postReconnectRegisterTimer =
            Timer(Duration(milliseconds: delayMs), () {
          _postReconnectRegisterTimer = null;
          if (_status == C.STATUS_USER_CLOSED) {
            return;
          }
          if (_socketTransport != null &&
              !_socketTransport!.isConnected()) {
            logger.d(
                'register() after reconnect delay skipped: transport not connected');
            return;
          }
          register();
        });
      } else {
        _pendingPostReconnectRegister = false;
        register();
      }
    } else {
      _pendingPostReconnectRegister = false;
    }
  }

// Transport disconnected event.
  void onTransportDisconnect(SIPUASocketInterface? socket, ErrorCause cause) {
    _stopTransportOptionsProbe();
    // Don't stop call keepalive here — let it exhaust all attempts so the
    // transport has a chance to recover before we force-close.
    _cancelPostReconnectRegisterTimer();
    if (_status != C.STATUS_USER_CLOSED) {
      _pendingPostReconnectRegister = true;
    }
    // Run _onTransportError_ callback on every client transaction using _transport_.
    _transactions.removeAll().forEach((TransactionBase transaction) {
      transaction.onTransportError();
    });

    emit(EventSocketDisconnected(socket: socket, cause: cause));

    // Call registrator _onTransportClosed_.
    _registrator.onTransportClosed();

    if (_status != C.STATUS_USER_CLOSED) {
      _status = C.STATUS_NOT_READY;
      _error = C.NETWORK_ERROR;
    }
  }

// Transport data event.
  void onTransportData(SocketTransport transport, String messageData) {
    try {
      _lastTransportActivityAt = DateTime.now();
      _restartCallKeepAliveTimer();
      IncomingMessage? message = Parser.parseMessage(messageData, this);

      if (message == null) {
        return;
      }

      if (_status == C.STATUS_USER_CLOSED && message is IncomingRequest) {
        return;
      }

      // Do some sanity check.
      if (!sanityCheck(message, this, transport)) {
        logger.w(
            'Incoming message did not pass sanity test, dumping it: \n\n $message');
        return;
      }

      if (message is IncomingRequest) {
        message.transport = transport;
        receiveRequest(message);
      } else if (message is IncomingResponse) {
        /* Unike stated in 18.1.2, if a response does not match
      * any transaction, it is discarded here and no passed to the core
      * in order to be discarded there.
      */

        switch (message.method) {
          case SipMethod.INVITE:
            InviteClientTransaction? transaction = _transactions.getTransaction(
                InviteClientTransaction, message.via_branch!);
            if (transaction != null) {
              transaction.receiveResponse(message.status_code, message);
            } else if (message.status_code >= 200) {
              logger.d(
                '📍 SIP-DIAG [LATE-RESPONSE] '
                'status=${message.status_code} '
                'branch=${message.via_branch} '
                'call_id=${message.call_id} '
                'cseq=${message.cseq} '
                'from_tag=${message.from_tag} '
                'to_tag=${message.to_tag} '
                'active_sessions=${_sessions.keys.toList()} '
                '— transaction already destroyed (Timer B fired?)',
              );
            }
            break;
          case SipMethod.ACK:
            // Just in case ;-).
            break;
          default:
            NonInviteClientTransaction? transaction = _transactions
                .getTransaction(NonInviteClientTransaction, message.via_branch!);
            if (transaction != null) {
              transaction.receiveResponse(message.status_code, message);
            }
            break;
        }
      }
    } catch (e, s) {
      logger.e('onTransportData crash: $e', error: e, stackTrace: s);
    }
  }

  // ── In-call keepalive via SIP OPTIONS ──────────────────────────────

  void _startCallKeepAlive() {
    if (!_configuration.call_keep_alive_enabled) {
      return;
    }
    if (_callKeepAliveTimer != null) {
      // Already running.
      return;
    }
    _callKeepAliveAttempt = 0;
    final int intervalSec = _configuration.call_keep_alive_interval_sec > 0
        ? _configuration.call_keep_alive_interval_sec
        : 10;
    _callKeepAliveTimer =
        Timer.periodic(Duration(seconds: intervalSec), (_) {
      _checkCallKeepAlive();
    });
    logger.d('Call keepalive started (interval=${intervalSec}s)');
  }

  /// Restart the keepalive timer so the next probe fires a full interval
  /// after the most recent incoming data.  Called from onTransportData().
  void _restartCallKeepAliveTimer() {
    if (_callKeepAliveTimer == null) {
      return; // keepalive not running
    }
    _callKeepAliveAttempt = 0;
    _callKeepAliveTimer!.cancel();
    final int intervalSec = _configuration.call_keep_alive_interval_sec > 0
        ? _configuration.call_keep_alive_interval_sec
        : 10;
    _callKeepAliveTimer =
        Timer.periodic(Duration(seconds: intervalSec), (_) {
      _checkCallKeepAlive();
    });
  }

  void _stopCallKeepAlive() {
    _callKeepAliveTimer?.cancel();
    _callKeepAliveTimer = null;
    _callKeepAliveResponseTimer?.cancel();
    _callKeepAliveResponseTimer = null;
    try {
      _callKeepAliveInFlight?.close();
    } catch (_) {}
    _callKeepAliveInFlight = null;
    _callKeepAliveAttempt = 0;
  }

  void _checkCallKeepAlive() {
    if (activeSessionCount == 0) {
      _stopCallKeepAlive();
      return;
    }
    if (_callKeepAliveInFlight != null) {
      // Previous probe still in flight — wait for its result.
      return;
    }

    // Timer is restarted on every incoming message (onTransportData),
    // so if we got here — a full interval passed with no incoming data.
    _sendCallKeepAlive();
  }

  void _sendCallKeepAlive() {
    final int maxAttempts = _configuration.call_keep_alive_max_attempts > 0
        ? _configuration.call_keep_alive_max_attempts
        : 3;

    if (_callKeepAliveAttempt >= maxAttempts) {
      logger.w(
          'Call keepalive failed $_callKeepAliveAttempt/$maxAttempts — '
          'force-closing transport.');
      _stopCallKeepAlive();
      _socketTransport?.disconnect();
      return;
    }

    _callKeepAliveAttempt += 1;
    final int attempt = _callKeepAliveAttempt;

    final EventManager handlers = EventManager();
    handlers.on(EventSucceeded(), (EventSucceeded _) {
      _onCallKeepAliveSuccess();
    });
    handlers.on(EventCallFailed(), (EventCallFailed _) {
      _onCallKeepAliveFailure();
    });

    try {
      logger.d(
          'Call keepalive OPTIONS attempt $attempt/$maxAttempts');
      _callKeepAliveInFlight = sendOptions(
        _transportOptionsProbeTarget(),
        'ping',
        <String, dynamic>{
          'eventHandlers': handlers,
          'contentType': 'text/plain',
        },
      );
      _startCallKeepAliveResponseTimer();
    } catch (e) {
      logger.w('Call keepalive OPTIONS send failed: $e');
      _callKeepAliveInFlight = null;
      // Don't retry immediately — let the next periodic tick handle it
      // via _checkCallKeepAlive() so transport has time to recover.
    }
  }

  void _startCallKeepAliveResponseTimer() {
    _callKeepAliveResponseTimer?.cancel();
    final int intervalSec = _configuration.call_keep_alive_interval_sec > 0
        ? _configuration.call_keep_alive_interval_sec
        : 10;
    _callKeepAliveResponseTimer =
        Timer(Duration(seconds: intervalSec), () {
      logger.w('Call keepalive OPTIONS response timeout after ${intervalSec}s');
      try {
        _callKeepAliveInFlight?.close();
      } catch (_) {}
      _callKeepAliveInFlight = null;
      _onCallKeepAliveFailure();
    });
  }

  void _onCallKeepAliveSuccess() {
    _callKeepAliveResponseTimer?.cancel();
    _callKeepAliveResponseTimer = null;
    _callKeepAliveInFlight = null;
    // attempt counter and timer are reset by _restartCallKeepAliveTimer()
    // called from onTransportData() when the 200 OK arrives.
    logger.d('Call keepalive OPTIONS succeeded');
  }

  void _onCallKeepAliveFailure() {
    _callKeepAliveResponseTimer?.cancel();
    _callKeepAliveResponseTimer = null;
    try {
      _callKeepAliveInFlight?.close();
    } catch (_) {}
    _callKeepAliveInFlight = null;

    final int maxAttempts = _configuration.call_keep_alive_max_attempts > 0
        ? _configuration.call_keep_alive_max_attempts
        : 3;

    if (_callKeepAliveAttempt >= maxAttempts) {
      logger.w(
          'Call keepalive failed $_callKeepAliveAttempt/$maxAttempts — '
          'force-closing transport.');
      _stopCallKeepAlive();
      _socketTransport?.disconnect();
      return;
    }

    // Retry immediately.
    _sendCallKeepAlive();
  }

  // ── Idle transport OPTIONS probe ─────────────────────────────────

  bool _isTransportOptionsProbeEnabled() {
    return _configuration.transport_options_probe_enabled;
  }

  String _transportOptionsProbeTarget() {
    final configured = _configuration.transport_options_probe_target;
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    return _configuration.uri.toString();
  }

  void _startTransportOptionsProbe() {
    _stopTransportOptionsProbe();
    if (!_isTransportOptionsProbeEnabled()) {
      return;
    }
    _lastTransportActivityAt = DateTime.now();
    _transportOptionsProbeTimer =
        Timer.periodic(const Duration(seconds: 1), (_) {
      _checkTransportOptionsProbe();
    });
  }

  void _stopTransportOptionsProbe() {
    _transportOptionsProbeTimer?.cancel();
    _transportOptionsProbeTimer = null;
    _transportOptionsProbeResponseTimer?.cancel();
    _transportOptionsProbeResponseTimer = null;
    try {
      _transportOptionsProbeInFlight?.close();
    } catch (_) {}
    _transportOptionsProbeInFlight = null;
    _transportOptionsProbeSocket = null;
    _transportOptionsProbeAttempt = 0;
  }

  bool _isStaleTransportOptionsProbe() {
    final currentSocket = _socketTransport?.socket;
    if (_transportOptionsProbeSocket == null || currentSocket == null) {
      return false;
    }
    // Probe belongs to an old socket instance after reconnect.
    return !identical(_transportOptionsProbeSocket, currentSocket);
  }

  void _checkTransportOptionsProbe() {
    if (!_isTransportOptionsProbeEnabled()) {
      return;
    }
    if (_status != C.STATUS_READY) {
      return;
    }
    // Don't run idle probe while a call is active — call keepalive handles that.
    if (activeSessionCount > 0) {
      return;
    }
    if (_socketTransport == null || !_socketTransport!.isConnected()) {
      return;
    }
    if (_transportOptionsProbeInFlight != null) {
      return;
    }
    final int idleSec = _configuration.transport_options_probe_idle_sec > 0
        ? _configuration.transport_options_probe_idle_sec
        : 20;
    final int idleFor =
        DateTime.now().difference(_lastTransportActivityAt).inSeconds;
    if (idleFor < idleSec) {
      return;
    }
    _sendTransportOptionsProbe();
  }

  void _sendTransportOptionsProbe() {
    if (_transportOptionsProbeInFlight != null) {
      return;
    }
    final int maxAttempts = _configuration.transport_options_probe_max_attempts > 0
        ? _configuration.transport_options_probe_max_attempts
        : 2;
    if (_transportOptionsProbeAttempt >= maxAttempts) {
      logger.w(
          'Transport OPTIONS probe failed ${_transportOptionsProbeAttempt}/$maxAttempts. Disconnecting transport with recovery.');
      _socketTransport?.disconnectWithRecovery();
      _transportOptionsProbeAttempt = 0;
      return;
    }
    _transportOptionsProbeAttempt += 1;
    final int attempt = _transportOptionsProbeAttempt;

    final EventManager handlers = EventManager();
    handlers.on(EventSucceeded(), (EventSucceeded _) {
      _onTransportOptionsProbeSuccess();
    });
    handlers.on(EventCallFailed(), (EventCallFailed _) {
      _onTransportOptionsProbeFailure();
    });

    try {
      logger.w(
          'Transport idle detected. Sending OPTIONS probe attempt $attempt/$maxAttempts');
      _transportOptionsProbeSocket = _socketTransport?.socket;
      _transportOptionsProbeInFlight = sendOptions(
        _transportOptionsProbeTarget(),
        'ping',
        <String, dynamic>{
          'eventHandlers': handlers,
          'contentType': 'text/plain',
        },
      );
      _startTransportOptionsProbeResponseTimer();
    } catch (e) {
      logger.w('OPTIONS probe send failed: $e');
      _onTransportOptionsProbeFailure();
    }
  }

  void _startTransportOptionsProbeResponseTimer() {
    _transportOptionsProbeResponseTimer?.cancel();
    final int timeoutSec =
        _configuration.transport_options_probe_response_timeout_sec > 0
            ? _configuration.transport_options_probe_response_timeout_sec
            : 6;
    _transportOptionsProbeResponseTimer =
        Timer(Duration(seconds: timeoutSec), () {
      logger.w('OPTIONS probe response timeout after ${timeoutSec}s');
      try {
        _transportOptionsProbeInFlight?.close();
      } catch (_) {}
      _transportOptionsProbeInFlight = null;
      _onTransportOptionsProbeFailure();
    });
  }

  void _onTransportOptionsProbeSuccess() {
    _transportOptionsProbeResponseTimer?.cancel();
    _transportOptionsProbeResponseTimer = null;
    _transportOptionsProbeInFlight = null;
    _transportOptionsProbeSocket = null;
    _transportOptionsProbeAttempt = 0;
    _lastTransportActivityAt = DateTime.now();
    logger.d('OPTIONS probe succeeded');
  }

  void _onTransportOptionsProbeFailure() {
    if (_isStaleTransportOptionsProbe()) {
      logger.d('Ignore stale OPTIONS probe failure after transport switch');
      _transportOptionsProbeResponseTimer?.cancel();
      _transportOptionsProbeResponseTimer = null;
      _transportOptionsProbeInFlight = null;
      _transportOptionsProbeSocket = null;
      _transportOptionsProbeAttempt = 0;
      return;
    }
    _transportOptionsProbeResponseTimer?.cancel();
    _transportOptionsProbeResponseTimer = null;
    try {
      _transportOptionsProbeInFlight?.close();
    } catch (_) {}
    _transportOptionsProbeInFlight = null;
    _transportOptionsProbeSocket = null;

    final int maxAttempts = _configuration.transport_options_probe_max_attempts > 0
        ? _configuration.transport_options_probe_max_attempts
        : 2;
    if (_transportOptionsProbeAttempt >= maxAttempts) {
      logger.w(
          'OPTIONS probe failed ${_transportOptionsProbeAttempt}/$maxAttempts. Marking transport as lost and scheduling recovery.');
      _socketTransport?.disconnectWithRecovery();
      _transportOptionsProbeAttempt = 0;
      return;
    }
    _sendTransportOptionsProbe();
  }
}

mixin Applicant {
  void close();
}
