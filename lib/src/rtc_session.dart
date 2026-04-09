import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart' as sdp_transform;
import 'package:sdp_transform/sdp_transform.dart';

import 'package:sip_ua/sip_ua.dart';
import 'constants.dart' as DartSIP_C;
import 'constants.dart';
import 'dialog.dart';
import 'event_manager/event_manager.dart';
import 'event_manager/internal_events.dart';
import 'exceptions.dart' as Exceptions;
import 'logger.dart';
import 'name_addr_header.dart';
import 'request_sender.dart';
import 'rtc_session/dtmf.dart' as RTCSession_DTMF;
import 'rtc_session/dtmf.dart';
import 'rtc_session/info.dart' as RTCSession_Info;
import 'rtc_session/info.dart';
import 'rtc_session/refer_notifier.dart';
import 'rtc_session/refer_subscriber.dart';
import 'timers.dart';
import 'transactions/transaction_base.dart';
import 'ua.dart';
import 'utils.dart' as utils;

class C {
  // RTCSession states.
  static const int STATUS_NULL = 0;
  static const int STATUS_INVITE_SENT = 1;
  static const int STATUS_1XX_RECEIVED = 2;
  static const int STATUS_INVITE_RECEIVED = 3;
  static const int STATUS_WAITING_FOR_ANSWER = 4;
  static const int STATUS_ANSWERED = 5;
  static const int STATUS_WAITING_FOR_ACK = 6;
  static const int STATUS_CANCELED = 7;
  static const int STATUS_TERMINATED = 8;
  static const int STATUS_CONFIRMED = 9;
}

/**
 * Local variables.
 */
const List<String?> holdMediaTypes = <String?>['audio', 'video'];

class SIPTimers {
  Timer? ackTimer;
  Timer? expiresTimer;
  Timer? invite2xxTimer;
  Timer? userNoAnswerTimer;
}

class RFC4028Timers {
  RFC4028Timers(this.enabled, this.refreshMethod, this.defaultExpires,
      this.currentExpires, this.running, this.refresher, this.timer);
  bool enabled;
  SipMethod refreshMethod;
  int? defaultExpires;
  int? currentExpires;
  bool running;
  bool refresher;
  Timer? timer;
}

class RTCSession extends EventManager implements Owner {
  RTCSession(this._ua) {
    logger.d('new');
    // Session Timers (RFC 4028).
    _sessionTimers = RFC4028Timers(
        _ua.configuration.session_timers,
        _ua.configuration.session_timers_refresh_method,
        DartSIP_C.SESSION_EXPIRES,
        null,
        false,
        false,
        null);

    receiveRequest = _receiveRequest;
  }

  final UA _ua;

  String? _id;
  int _status = C.STATUS_NULL;
  Dialog? _dialog;
  final Map<String?, Dialog> _earlyDialogs = <String?, Dialog>{};
  String? _contact;
  String? _from_tag;
  String? get from_tag => _from_tag;
  String? _to_tag;
  String? get to_tag => _to_tag;

  // The RTCPeerConnection instance (public attribute).
  RTCPeerConnection? _connection;

  // Incoming/Outgoing request being currently processed.
  dynamic _request;

  // Cancel state for initial outgoing request.
  bool _is_canceled = false;
  String? _cancel_reason = '';

  // RTCSession confirmation flag.
  bool _is_confirmed = false;

  // Is late SDP being negotiated.
  bool _late_sdp = false;

  /// Set while answering an **incoming** call whose offer was legacy RTP/AVP and
  /// was shimmed with local ICE/DTLS for WebRTC. After ACK we send one re-INVITE
  /// so FreeSWITCH returns a real SRTP answer; without that, media often stays
  /// silent until a manual hold/unhold renegotiation.
  bool _needsPostAckMediaRenegotiation = false;

  /// Coalesces ICE-restart renegotiations and staggers them when several calls are up
  /// (attended transfer), avoiding overlapping re-INVITEs on the same TCP leg.
  Timer? _iceRestartDebounceTimer;

  /// One in-dialog client re-INVITE at a time **for this session** (RFC 3261).
  /// UA-global serialization wrongly blocked re-INVITEs on other dialogs sharing
  /// one TCP/WSS transport (attended transfer: hold leg + consult leg).
  Future<void> _serializedClientReinviteChain = Future<void>.value();

  Future<void> _runSerializedClientReinvite(Future<void> Function() work) {
    final Future<void> f = _serializedClientReinviteChain.then((_) async {
      try {
        await work();
      } catch (e, st) {
        logger.e('runSerializedClientReinvite failed: $e',
            error: e, stackTrace: st);
      }
    });
    _serializedClientReinviteChain =
        f.catchError((Object _, StackTrace __) => Future<void>.value());
    return f;
  }

  // Default rtcOfferConstraints and rtcAnswerConstrainsts (passed in connect() or answer()).
  Map<String, dynamic>? _rtcOfferConstraints;
  Map<String, dynamic>? _rtcAnswerConstraints;

  // Local MediaStream.
  MediaStream? _localMediaStream;
  bool _localMediaStreamLocallyGenerated = false;

  // Flag to indicate PeerConnection ready for actions.
  bool _rtcReady = true;

  // SIP Timers.
  final SIPTimers _timers = SIPTimers();

  // Session info.
  String? _direction;
  NameAddrHeader? _local_identity;
  NameAddrHeader? _remote_identity;
  DateTime? _start_time;
  DateTime? _end_time;
  String? _tones;

  // Mute/Hold state.
  bool _audioMuted = false;
  bool _videoMuted = false;
  bool _localHold = false;
  bool _remoteHold = false;

  late RFC4028Timers _sessionTimers;

  // Map of ReferSubscriber instances indexed by the REFER's CSeq number.
  final Map<int?, ReferSubscriber> _referSubscribers =
      <int?, ReferSubscriber>{};

  /// Prevents duplicate public ENDED/FAILED emission if teardown is re-entered
  /// (e.g. FS BYE while local hangup is in progress).
  bool _sessionTerminationNotified = false;

  // Custom session empty object for high level use.
  Map<String, dynamic>? data = <String, dynamic>{};

  RTCIceGatheringState? _iceGatheringState;

  Future<void> dtmfFuture = (Completer<void>()..complete()).future;

  @override
  late Function(IncomingRequest) receiveRequest;

  /**
   * User API
   */

  // Expose session failed/ended causes as a property of the RTCSession instance.
  Type get causes => DartSIP_C.CausesType;

  String? get id => _id;

  dynamic get request => _request;

  RTCPeerConnection? get connection => _connection;

  @override
  int get TerminatedCode => C.STATUS_TERMINATED;

  Future<RTCDTMFSender?> getDtmfSender() async {
    final conn = _connection;
    if (conn == null) {
      throw Exceptions.InvalidStateError(
          'Cannot create DTMF sender: peerConnection is null');
    }
    final senders = await conn.getSenders();
    final audioSender = senders.where(
      (s) => s.track?.kind == 'audio',
    ).firstOrNull;
    if (audioSender == null) {
      throw Exceptions.InvalidStateError(
          'Cannot create DTMF sender: no audio sender found');
    }
    final audioTrack = audioSender.track!;
    return conn.createDtmfSender(audioTrack);
  }

  String? get contact => _contact;

  String? get direction => _direction;

  NameAddrHeader? get local_identity => _local_identity;

  NameAddrHeader? get remote_identity => _remote_identity;

  DateTime? get start_time => _start_time;

  DateTime? get end_time => _end_time;

  @override
  UA get ua => _ua;

  @override
  int get status => _status;

  bool isInProgress() {
    switch (_status) {
      case C.STATUS_NULL:
      case C.STATUS_INVITE_SENT:
      case C.STATUS_1XX_RECEIVED:
      case C.STATUS_INVITE_RECEIVED:
      case C.STATUS_WAITING_FOR_ANSWER:
        return true;
      default:
        return false;
    }
  }

  bool isEstablished() {
    switch (_status) {
      case C.STATUS_ANSWERED:
      case C.STATUS_WAITING_FOR_ACK:
      case C.STATUS_CONFIRMED:
        return true;
      default:
        return false;
    }
  }

  bool isEnded() {
    switch (_status) {
      case C.STATUS_CANCELED:
      case C.STATUS_TERMINATED:
        return true;
      default:
        return false;
    }
  }

  Map<String, dynamic> isMuted() {
    return <String, dynamic>{'audio': _audioMuted, 'video': _videoMuted};
  }

  Map<String, dynamic> isOnHold() {
    return <String, dynamic>{'local': _localHold, 'remote': _remoteHold};
  }

  void connect(dynamic target,
      [Map<String, dynamic>? options,
      InitSuccessCallback? initCallback]) async {
    logger.d('connect()');

    options = options ?? <String, dynamic>{};
    dynamic originalTarget = target;
    EventManager eventHandlers = options['eventHandlers'] ?? EventManager();
    List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);
    Map<String, dynamic> mediaConstraints = options['mediaConstraints'] ??
        <String, dynamic>{'audio': true, 'video': true};
    MediaStream? mediaStream = options['mediaStream'];
    Map<String, dynamic> pcConfig =
        options['pcConfig'] ?? <String, dynamic>{'iceServers': <dynamic>[]};
    Map<String, dynamic> rtcConstraints =
        options['rtcConstraints'] ?? <String, dynamic>{};
    Map<String, dynamic> rtcOfferConstraints =
        options['rtcOfferConstraints'] ?? <String, dynamic>{};
    _rtcOfferConstraints = rtcOfferConstraints;
    _rtcAnswerConstraints =
        options['rtcAnswerConstraints'] ?? <String, dynamic>{};
    data = options['data'] ?? data;
    data?['video'] = !(options['mediaConstraints']['video'] == false);

    // Check target.
    if (target == null) {
      throw Exceptions.TypeError('Not enough arguments');
    }

    // Check Session Status.
    if (_status != C.STATUS_NULL) {
      throw Exceptions.InvalidStateError(_status);
    }

    // Check WebRTC support.
    // TODO(cloudwebrtc): change support for flutter-webrtc
    //if (RTCPeerConnection == null)
    //{
    //  throw Exceptions.NotSupportedError('WebRTC not supported');
    //}

    // Check target validity.
    target = _ua.normalizeTarget(target);
    if (target == null) {
      throw Exceptions.TypeError('Invalid target: $originalTarget');
    }

    // Session Timers.
    if (_sessionTimers.enabled) {
      if (utils.isDecimal(options['sessionTimersExpires'])) {
        if (options['sessionTimersExpires'] >= DartSIP_C.MIN_SESSION_EXPIRES) {
          _sessionTimers.defaultExpires = options['sessionTimersExpires'];
        } else {
          _sessionTimers.defaultExpires = DartSIP_C.SESSION_EXPIRES;
        }
      }
    }

    // Set event handlers.
    addAllEventHandlers(eventHandlers);

    // Session parameter initialization.
    _from_tag = utils.newTag();

    // Set anonymous property.
    bool anonymous = options['anonymous'] ?? false;
    Map<String, dynamic> requestParams = <String, dynamic>{
      'from_tag': _from_tag,
      'to_display_name': options['to_display_name'] ?? '',
    };
    _ua.contact!.anonymous = anonymous;
    _ua.contact!.outbound = true;
    _contact = _ua.contact.toString();

    bool isFromUriOptionPresent = options['from_uri'] != null;

    //set from_uri and from_display_name if present
    if (isFromUriOptionPresent) {
      requestParams['from_display_name'] = options['from_display_name'] ?? '';
      requestParams['from_uri'] = URI.parse(options['from_uri']);
      extraHeaders
          .add('P-Preferred-Identity: ${_ua.configuration.uri.toString()}');
    }

    if (anonymous) {
      requestParams['from_display_name'] = 'Anonymous';
      requestParams['from_uri'] = URI('sip', 'anonymous', 'anonymous.invalid');
      extraHeaders
          .add('P-Preferred-Identity: ${_ua.configuration.uri.toString()}');
      extraHeaders.add('Privacy: id');
    }

    extraHeaders.add('Contact: $_contact');
    extraHeaders.add('Content-Type: application/sdp');
    if (_sessionTimers.enabled) {
      extraHeaders.add('Session-Expires: ${_sessionTimers.defaultExpires}');
    }

    _request =
        InitialOutgoingInviteRequest(target, _ua, requestParams, extraHeaders);

    _id = _request.call_id + _from_tag;

    // Create a RTCPeerConnection instance.
    await _createRTCConnection(pcConfig, rtcConstraints);

    // Set internal properties.
    _direction = 'outgoing';
    _local_identity = _request.from;
    _remote_identity = _request.to;

    // User explicitly provided a newRTCSession callback for this session.
    if (initCallback != null) {
      initCallback(this);
    }

    _newRTCSession('local', _request);
    await _sendInitialRequest(
        pcConfig, mediaConstraints, rtcOfferConstraints, mediaStream);
  }

  void init_incoming(IncomingRequest request,
      [Function(RTCSession)? initCallback]) {
    logger.d('init_incoming()');

    int? expires;
    String? contentType = request.getHeader('Content-Type');

    // Check body and content type.
    if (request.body != null && (contentType != 'application/sdp')) {
      request.reply(415);
      return;
    }

    // Session parameter initialization.
    _status = C.STATUS_INVITE_RECEIVED;
    _from_tag = request.from_tag;
    _id = request.call_id! + _from_tag!;
    _request = request;
    _contact = _ua.contact.toString();

    // Get the Expires header value if exists.
    if (request.hasHeader('expires')) {
      try {
        expires = (request.getHeader('expires') is num
                ? request.getHeader('expires')
                : num.tryParse(request.getHeader('expires'))!) *
            1000;
      } catch (e) {
        logger.e(
            'Invalid Expires header value: ${request.getHeader('expires')}, error $e');
      }
    }

    /* Set the to_tag before
     * replying a response code that will create a dialog.
     */
    request.to_tag = utils.newTag();

    // An error on dialog creation will fire 'failed' event.
    if (!_createDialog(request, 'UAS', true)) {
      request.reply(500, 'Missing Contact header field');
      return;
    }

    if (request.body != null) {
      _late_sdp = false;
    } else {
      _late_sdp = true;
    }

    _status = C.STATUS_WAITING_FOR_ANSWER;

    // Set userNoAnswerTimer.
    _timers.userNoAnswerTimer = setTimeout(() {
      if (_status == C.STATUS_TERMINATED) return;
      request.reply(408);
      _failed('local', null, null, null, 408, DartSIP_C.CausesType.NO_ANSWER,
          'No Answer');
    }, _ua.configuration.no_answer_timeout);

    /* Set expiresTimer
     * RFC3261 13.3.1
     */
    if (expires != null) {
      _timers.expiresTimer = setTimeout(() {
        if (_status == C.STATUS_WAITING_FOR_ANSWER) {
          request.reply(487);
          _failed('system', null, null, null, 487, DartSIP_C.CausesType.EXPIRES,
              'Timeout');
        }
      }, expires);
    }

    // Set internal properties.
    _direction = 'incoming';
    _local_identity = request.to;
    _remote_identity = request.from;

    // A init callback was specifically defined.
    if (initCallback != null) {
      initCallback(this);
    }

    // Fire 'newRTCSession' event.
    _newRTCSession('remote', request);

    // The user may have rejected the call in the 'newRTCSession' event.
    if (_status == C.STATUS_TERMINATED) {
      return;
    }

    // Reply 180.
    request.reply(180, null, <dynamic>['Contact: $_contact']);

    // Fire 'progress' event.
    // TODO(cloudwebrtc): Document that 'response' field in 'progress' event is null for incoming calls.
    _progress('local', null);
  }

  /**
   * Answer the call.
   */
  void answer(Map<String, dynamic> options) async {
    logger.d('answer()');
    dynamic request = _request;
    List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);
    Map<String, dynamic> mediaConstraints =
        options['mediaConstraints'] ?? <String, dynamic>{};
    MediaStream? mediaStream = options['mediaStream'] ?? null;
    Map<String, dynamic> pcConfig =
        options['pcConfig'] ?? <String, dynamic>{'iceServers': <dynamic>[]};
    Map<String, dynamic> rtcConstraints =
        options['rtcConstraints'] ?? <String, dynamic>{};
    Map<String, dynamic> rtcAnswerConstraints =
        options['rtcAnswerConstraints'] ?? <String, dynamic>{};

    List<MediaStreamTrack> tracks;
    bool peerHasAudioLine = false;
    bool peerHasVideoLine = false;
    bool peerOffersFullAudio = false;
    bool peerOffersFullVideo = false;

    // In future versions, unified-plan will be used by default
    String? sdpSemantics = 'unified-plan';
    if (pcConfig['sdpSemantics'] != null) {
      sdpSemantics = pcConfig['sdpSemantics'];
    }

    _rtcAnswerConstraints = rtcAnswerConstraints;
    _rtcOfferConstraints = options['rtcOfferConstraints'] ?? null;

    data = options['data'] ?? data;

    // Check Session Direction and Status.
    if (_direction != 'incoming') {
      throw Exceptions.NotSupportedError(
          '"answer" not supported for outgoing RTCSession');
    }

    // Check Session status.
    if (_status != C.STATUS_WAITING_FOR_ANSWER) {
      throw Exceptions.InvalidStateError(_status);
    }

    // Session Timers.
    if (_sessionTimers.enabled) {
      if (utils.isDecimal(options['sessionTimersExpires'])) {
        if (options['sessionTimersExpires'] >= DartSIP_C.MIN_SESSION_EXPIRES) {
          _sessionTimers.defaultExpires = options['sessionTimersExpires'];
        } else {
          _sessionTimers.defaultExpires = DartSIP_C.SESSION_EXPIRES;
        }
      }
    }

    _status = C.STATUS_ANSWERED;

    // An error on dialog creation will fire 'failed' event.
    if (!_createDialog(request, 'UAS')) {
      request.reply(500, 'Error creating dialog');

      return;
    }

    clearTimeout(_timers.userNoAnswerTimer);
    extraHeaders.insert(0, 'Contact: $_contact');

    // Determine incoming media from incoming SDP offer (if any).
    Map<String, dynamic> sdp = request.parseSDP();

    // Make sure sdp['media'] is an array, not the case if there is only one media.
    if (sdp['media'] is! List) {
      sdp['media'] = <dynamic>[sdp['media']];
    }

    // Go through all medias in SDP to find offered capabilities to answer with.
    for (Map<String, dynamic> m in sdp['media']) {
      if (m['type'] == 'audio') {
        peerHasAudioLine = true;
        if (m['direction'] == null || m['direction'] == 'sendrecv') {
          peerOffersFullAudio = true;
        }
      }
      if (m['type'] == 'video') {
        peerHasVideoLine = true;
        if (m['direction'] == null || m['direction'] == 'sendrecv') {
          peerOffersFullVideo = true;
        }
      }
    }

    // Remove audio from mediaStream if suggested by mediaConstraints.
    if (mediaStream != null && mediaConstraints['audio'] == false) {
      tracks = mediaStream.getAudioTracks();
      for (MediaStreamTrack track in tracks) {
        mediaStream.removeTrack(track);
      }
    }

    // Remove video from mediaStream if suggested by mediaConstraints.
    if (mediaStream != null && mediaConstraints['video'] == false) {
      tracks = mediaStream.getVideoTracks();
      for (MediaStreamTrack track in tracks) {
        mediaStream.removeTrack(track);
      }
    }

    // Set audio constraints based on incoming stream if not supplied.
    if (mediaStream == null && mediaConstraints['audio'] == null) {
      mediaConstraints['audio'] = peerOffersFullAudio;
    }

    // Set video constraints based on incoming stream if not supplied.
    if (mediaStream == null && mediaConstraints['video'] == null) {
      mediaConstraints['video'] = peerOffersFullVideo;
    }

    // Don't ask for audio if the incoming offer has no audio section.
    if (mediaStream == null && !peerHasAudioLine) {
      mediaConstraints['audio'] = false;
    }

    // Don't ask for video if the incoming offer has no video section.
    if (mediaStream == null && !peerHasVideoLine) {
      mediaConstraints['video'] = false;
    }

    // Create a RTCPeerConnection instance.
    // TODO(cloudwebrtc): This may throw an error, should react.
    await _createRTCConnection(pcConfig, rtcConstraints);

    MediaStream? stream;
    // A local MediaStream is given, use it.
    if (mediaStream != null) {
      stream = mediaStream;
      emit(EventStream(session: this, originator: 'local', stream: stream));
    }
    // Audio and/or video requested, prompt getUserMedia.
    else if (mediaConstraints['audio'] != null ||
        mediaConstraints['video'] != null) {
      _localMediaStreamLocallyGenerated = true;
      try {
        stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
        emit(EventStream(session: this, originator: 'local', stream: stream));
      } catch (error) {
        if (_status == C.STATUS_TERMINATED) {
          throw Exceptions.InvalidStateError('terminated');
        }
        request.reply(480);
        _failed(
            'local',
            null,
            null,
            null,
            480,
            DartSIP_C.CausesType.USER_DENIED_MEDIA_ACCESS,
            'User Denied Media Access');
        logger.e('emit "getusermediafailed" [error:${error.toString()}]');
        emit(EventGetUserMediaFailed(exception: error));
        throw Exceptions.InvalidStateError('getUserMedia() failed');
      }
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    // Attach MediaStream to RTCPeerconnection.
    _localMediaStream = stream;

    if (stream != null) {
      stream.getTracks().forEach((MediaStreamTrack track) {
        _connection!.addTrack(track, stream!);
      });
    }

    // Set remote description.
    if (_late_sdp) return;

    logger.d('emit "sdp"');
    final String? processedSDP = await _sdpOfferToWebRtcAsync(request.body);
    emit(EventSdp(originator: 'remote', type: 'offer', sdp: processedSDP));

    RTCSessionDescription offer = RTCSessionDescription(processedSDP, 'offer');
    try {
      await _connection!.setRemoteDescription(offer);
    } catch (error) {
      request.reply(488);
      _failed(
          'system',
          null,
          null,
          null,
          488,
          DartSIP_C.CausesType.WEBRTC_ERROR,
          'SetRemoteDescription(offer) failed');
      logger.e(
          'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
      emit(EventSetRemoteDescriptionFailed(exception: error));
      // [answer] is not always awaited by app code; do not throw into an unhandled zone.
      return;
    }

    // Create local description.
    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    // TODO(cloudwebrtc): Is this event already useful?
    _connecting(request);
    RTCSessionDescription desc;
    try {
      if (!_late_sdp) {
        desc = await _createLocalDescription('answer', rtcAnswerConstraints);
      } else {
        desc = await _createLocalDescription('offer', _rtcOfferConstraints);
      }
    } catch (error) {
      request.reply(500);
      _failed(
          'system',
          null,
          null,
          null,
          500,
          DartSIP_C.CausesType.WEBRTC_ERROR,
          'CreateLocalDescription (answer) failed');
      logger.e(
          'emit "peerconnection:createlocaldescriptionfailed" [error:${error.toString()}]');
      emit(EventSetLocalDescriptionFailed(exception: error));
      // [answer] is not always awaited; avoid throwing into PlatformDispatcher.onError / Sentry noise.
      return;
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    // Send reply.
    try {
      _handleSessionTimersInIncomingRequest(request, extraHeaders);
      request.reply(200, null, extraHeaders, desc.sdp, () {
        _status = C.STATUS_WAITING_FOR_ACK;
        _setInvite2xxTimer(request, desc.sdp);
        _setACKTimer();
        _accepted('local');
      }, () {
        _failed('system', null, null, null, 500,
            DartSIP_C.CausesType.CONNECTION_ERROR, 'Transport Error');
      });
    } catch (error, s) {
      if (_status == C.STATUS_TERMINATED) {
        return;
      }
      logger.e('Failed to answer(): ${error.toString()}',
          error: error, stackTrace: s);
    }
  }

  /**
   * Terminate the call.
   */
  void terminate([Map<String, dynamic>? options]) {
    logger.d('terminate()');

    options = options ?? <String, dynamic>{};

    Object cause = options['cause'] ?? DartSIP_C.CausesType.BYE;

    List<dynamic> extraHeaders = options['extraHeaders'] != null
        ? utils.cloneArray(options['extraHeaders'])
        : <dynamic>[];
    Object? body = options['body'];

    String? cancel_reason;
    int? status_code = options['status_code'] as int?;
    String? reason_phrase = options['reason_phrase'] as String?;

    // Check Session Status.
    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError(_status);
    }

    switch (_status) {
      // - UAC -
      case C.STATUS_NULL:
      case C.STATUS_INVITE_SENT:
      case C.STATUS_1XX_RECEIVED:
        logger.d('canceling session');

        if (status_code != null && (status_code < 200 || status_code >= 700)) {
          throw Exceptions.TypeError('Invalid status_code: $status_code');
        } else if (status_code != null) {
          reason_phrase = reason_phrase ?? DartSIP_C.REASON_PHRASE[status_code];
          cancel_reason = 'SIP ;cause=$status_code ;text="$reason_phrase"';
        }

        // Check Session Status.
        if (_status == C.STATUS_NULL || _status == C.STATUS_INVITE_SENT) {
          _is_canceled = true;
          _cancel_reason = cancel_reason;
        } else if (_status == C.STATUS_1XX_RECEIVED) {
          _request.cancel(cancel_reason ?? '');
        }

        _status = C.STATUS_CANCELED;
        cancel_reason = cancel_reason ?? 'Canceled by local';
        status_code = status_code ?? 100;
        _failed('local', null, null, null, status_code,
            DartSIP_C.CausesType.CANCELED, cancel_reason);
        break;

      // - UAS -
      case C.STATUS_WAITING_FOR_ANSWER:
      case C.STATUS_ANSWERED:
        logger.d('rejecting session');

        status_code = status_code ?? 480;

        if (status_code < 300 || status_code >= 700) {
          throw Exceptions.InvalidStateError(
              'Invalid status_code: $status_code');
        }

        _request.reply(status_code, reason_phrase, extraHeaders, body);
        _failed('local', null, null, null, status_code,
            DartSIP_C.CausesType.REJECTED, reason_phrase);
        break;

      case C.STATUS_WAITING_FOR_ACK:
      case C.STATUS_CONFIRMED:
        logger.d('terminating session');

        final bool skipBye = options['skipBye'] == true;

        reason_phrase = options['reason_phrase'] as String? ??
            DartSIP_C.REASON_PHRASE[status_code ?? 0];

        if (status_code != null && (status_code < 200 || status_code >= 700)) {
          throw Exceptions.InvalidStateError(
              'Invalid status_code: $status_code');
        } else if (status_code != null && !skipBye) {
          extraHeaders
              .add('Reason: SIP ;cause=$status_code; text="$reason_phrase"');
        }

        /* RFC 3261 section 15 (Terminating a session):
          *
          * "...the callee's UA MUST NOT send a BYE on a confirmed dialog
          * until it has received an ACK for its 2xx response or until the server
          * transaction times out."
          */
        if (_status == C.STATUS_WAITING_FOR_ACK &&
            _direction == 'incoming' &&
            _request.server_transaction.state != TransactionState.TERMINATED) {
          /// Save the dialog for later restoration.
          Dialog dialog = _dialog!;

          // Send the BYE as soon as the ACK is received...
          receiveRequest = (IncomingMessage request) {
            if (request.method == SipMethod.ACK) {
              sendRequest(SipMethod.BYE, <String, dynamic>{
                'extraHeaders': extraHeaders,
                'body': body
              });
              dialog.terminate();
            }
          };

          // .., or when the INVITE transaction times out
          _request.server_transaction.on(EventStateChanged(),
              (_) {
            if (_request.server_transaction.state ==
                TransactionState.TERMINATED) {
              sendRequest(SipMethod.BYE, <String, dynamic>{
                'extraHeaders': extraHeaders,
                'body': body
              });
              dialog.terminate();
            }
            // Ensure callback is typed as `void Function(...)` (not returning `Null`),
            // otherwise runtime may throw:
            // "type '(EventStateChanged) => Null' is not a subtype of '(EventType) => void'"
            return;
          });

          _ended(
              'local',
              null,
              ErrorCause(
                  cause: cause as String?,
                  status_code: status_code,
                  reason_phrase: reason_phrase));

          // Restore the dialog into 'this' in order to be able to send the in-dialog BYE :-).
          _dialog = dialog;

          // Restore the dialog into 'ua' so the ACK can reach 'this' session.
          _ua.newDialog(dialog);
        } else if (skipBye) {
          // 408/481 on in-dialog request: peer no longer has this dialog (RFC 3261
          // §12.2.1.2). Do not send BYE — it yields 481 "Call Does Not Exist".
          logger.d('terminating session (skip BYE: peer dialog already cleared)');
          final int sc = status_code ?? 481;
          final String phrase = reason_phrase ?? 'Dialog Error';
          _ended(
              'remote',
              null,
              ErrorCause(
                  cause: cause as String?,
                  status_code: sc,
                  reason_phrase: phrase));
        } else {
          sendRequest(SipMethod.BYE,
              <String, dynamic>{'extraHeaders': extraHeaders, 'body': body});
          reason_phrase = reason_phrase ?? 'Terminated by local';
          status_code = status_code ?? 200;
          _ended(
              'local',
              null,
              ErrorCause(
                  cause: cause as String?,
                  status_code: status_code,
                  reason_phrase: reason_phrase));
        }
    }
  }

  /// tones may be a single character or a string of dtmf digits
  void sendDTMF(dynamic tones, [Map<String, dynamic>? options]) {
    logger.d('sendDTMF() | tones: ${tones.toString()}');

    options = options ?? <String, dynamic>{};

    DtmfMode mode = _ua.configuration.dtmf_mode;

    // sensible defaults
    int duration = options['duration'] ?? RTCSession_DTMF.C.DEFAULT_DURATION;
    int interToneGap =
        options['interToneGap'] ?? RTCSession_DTMF.C.DEFAULT_INTER_TONE_GAP;
    int sendInterval = options['sendInterval'] ?? duration + interToneGap;

    if (tones == null) {
      throw Exceptions.TypeError('Not enough arguments');
    }

    // Check Session Status.
    if (_status != C.STATUS_CONFIRMED && _status != C.STATUS_WAITING_FOR_ACK) {
      throw Exceptions.InvalidStateError(_status);
    }

    // Convert to string.
    if (tones is num) {
      tones = tones.toString();
    }

    // Check tones.
    if (tones == null ||
        tones is! String ||
        !tones.contains(RegExp(r'^[0-9A-DR#*,]+$', caseSensitive: false))) {
      throw Exceptions.TypeError('Invalid tones: ${tones.toString()}');
    }

    // Check duration.
    if (duration == null) {
      duration = RTCSession_DTMF.C.DEFAULT_DURATION;
    } else if (duration < RTCSession_DTMF.C.MIN_DURATION) {
      logger.d(
          '"duration" value is lower than the minimum allowed, setting it to ${RTCSession_DTMF.C.MIN_DURATION} milliseconds');
      duration = RTCSession_DTMF.C.MIN_DURATION;
    } else if (duration > RTCSession_DTMF.C.MAX_DURATION) {
      logger.d(
          '"duration" value is greater than the maximum allowed, setting it to ${RTCSession_DTMF.C.MAX_DURATION} milliseconds');
      duration = RTCSession_DTMF.C.MAX_DURATION;
    } else {
      duration = duration.abs();
    }
    options['duration'] = duration;

    // Check interToneGap.
    if (interToneGap == null) {
      interToneGap = RTCSession_DTMF.C.DEFAULT_INTER_TONE_GAP;
    } else if (interToneGap < RTCSession_DTMF.C.MIN_INTER_TONE_GAP) {
      logger.d(
          '"interToneGap" value is lower than the minimum allowed, setting it to ${RTCSession_DTMF.C.MIN_INTER_TONE_GAP} milliseconds');
      interToneGap = RTCSession_DTMF.C.MIN_INTER_TONE_GAP;
    } else {
      interToneGap = interToneGap.abs();
    }

    options['interToneGap'] = interToneGap;

    //// ***************** and follows the actual code to queue DTMF tone(s) **********************

    ///using dtmfFuture to queue the playing of the tones

    for (int i = 0; i < tones.length; i++) {
      String tone = tones[i];
      if (tone == ',') {
        // queue the delay
        dtmfFuture = dtmfFuture.then((_) async {
          if (_status == C.STATUS_TERMINATED) {
            return;
          }
          await Future<void>.delayed(Duration(milliseconds: 2000), () {});
        });
      } else {
        // queue playing the tone
        dtmfFuture = dtmfFuture.then((_) async {
          if (_status == C.STATUS_TERMINATED) {
            return;
          }

          RTCSession_DTMF.DTMF dtmf = RTCSession_DTMF.DTMF(this, mode: mode);

          EventManager handlers = EventManager();
          handlers.on(EventCallFailed(), (EventCallFailed event) {
            logger.e('Failed to send DTMF ${event.cause}');
          });

          options!['eventHandlers'] = handlers;

          await dtmf.send(tone, options);
          await Future<void>.delayed(
              Duration(milliseconds: sendInterval), () {});
        });
      }
    }
  }

  void sendInfo(String contentType, String body, Map<String, dynamic> options) {
    logger.d('sendInfo()');

    // Check Session Status.
    if (_status != C.STATUS_CONFIRMED && _status != C.STATUS_WAITING_FOR_ACK) {
      throw Exceptions.InvalidStateError(_status);
    }

    RTCSession_Info.Info info = RTCSession_Info.Info(this);

    info.send(contentType, body, options);
  }

  /**
   * Mute
   */
  void mute([bool audio = true, bool video = true]) {
    logger.d('mute()');
    bool changed = false;

    if (!_audioMuted && audio) {
      _audioMuted = true;
      changed = true;
      _toggleMuteAudio(true);
    }

    if (!_videoMuted && video) {
      _videoMuted = true;
      changed = true;
      _toggleMuteVideo(true);
    }

    if (changed) {
      _onmute(_audioMuted, _videoMuted);
    }
  }

  /**
   * Unmute
   */
  void unmute([bool audio = true, bool video = true]) {
    logger.d('unmute()');
    bool changed = false;

    if (_audioMuted == true && audio) {
      _audioMuted = false;

      if (_localHold == false) {
        changed = true;
        _toggleMuteAudio(false);
      }
    }

    if (_videoMuted == true && video) {
      _videoMuted = false;

      if (_localHold == false) {
        changed = true;
        _toggleMuteVideo(false);
      }
    }

    if (changed) {
      _onunmute(!_audioMuted, !_videoMuted);
    }
  }

  /**
   * Hold
   */
  bool hold([Map<String, dynamic>? options, Function(IncomingMessage?)? done]) {
    logger.d('hold()');

    options = options ?? <String, dynamic>{};

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return false;
    }

    if (_localHold == true) {
      return false;
    }

    if (!_isReadyToReOffer()) {
      return false;
    }

    _localHold = true;
    _onhold('local');

    EventManager handlers = EventManager();

    handlers.on(EventSucceeded(), (EventSucceeded event) {
      if (done != null) {
        done(event.response);
      }
    });
    handlers.on(EventCallFailed(), (EventCallFailed event) {
      terminate(<String, dynamic>{
        'cause': DartSIP_C.CausesType.WEBRTC_ERROR,
        'status_code': 500,
        'reason_phrase': 'Hold Failed'
      });
    });

    if (options['useUpdate'] != null) {
      _sendUpdate(<String, dynamic>{
        'sdpOffer': true,
        'eventHandlers': handlers,
        'extraHeaders': options['extraHeaders']
      });
    } else {
      _sendReinvite(<String, dynamic>{
        'eventHandlers': handlers,
        'extraHeaders': options['extraHeaders'],
        // Hold offers may be port 9 / no ICE per stack; skipping re-INVITE
        // breaks attended transfer (one leg must be on hold for FS).
        'bypassReinviteSdpViability': true,
        'icePoisonReinviteMaxRetries': 8,
      });
    }

    return true;
  }

  bool unhold(
      [Map<String, dynamic>? options, Function(IncomingMessage?)? done]) {
    logger.d('unhold()');

    options = options ?? <String, dynamic>{};

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return false;
    }

    if (_localHold == false) {
      return false;
    }

    if (!_isReadyToReOffer()) {
      return false;
    }

    _localHold = false;
    _onunhold('local');

    EventManager handlers = EventManager();
    handlers.on(EventSucceeded(), (EventSucceeded event) {
      if (done != null) {
        done(event.response);
      }
    });
    handlers.on(EventCallFailed(), (EventCallFailed event) {
      terminate(<String, dynamic>{
        'cause': DartSIP_C.CausesType.WEBRTC_ERROR,
        'status_code': 500,
        'reason_phrase': 'Unhold Failed'
      });
    });

    if (options['useUpdate'] != null) {
      _sendUpdate(<String, dynamic>{
        'sdpOffer': true,
        'eventHandlers': handlers,
        'extraHeaders': options['extraHeaders']
      });
    } else {
      _sendReinvite(<String, dynamic>{
        'eventHandlers': handlers,
        'extraHeaders': options['extraHeaders'],
        'bypassReinviteSdpViability': true,
        'icePoisonReinviteMaxRetries': 8,
      });
    }

    return true;
  }

  bool renegotiate(
      {Map<String, dynamic>? options,
      bool useUpdate = false,
      Function(IncomingMessage?)? done}) {
    logger.d('renegotiate()');

    options = options ?? <String, dynamic>{};
    EventManager handlers = options['eventHandlers'] ?? EventManager();

    Map<String, dynamic>? rtcOfferConstraints =
        options['rtcOfferConstraints'] ?? _rtcOfferConstraints;

    Map<String, dynamic> mediaConstraints =
        options['mediaConstraints'] ?? <String, dynamic>{};

    dynamic sdpSemantics =
        options['pcConfig']?['sdpSemantics'] ?? 'unified-plan';

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return false;
    }

    bool? upgradeToVideo;
    try {
      // Only upgrade to video when the caller explicitly requested video.
      // Important: `null != false` is true in Dart, so the old logic could
      // incorrectly treat "video not specified" as "video enabled".
      final dynamic requestedVideo = options['mediaConstraints']?['video'];
      final dynamic requestedMandatoryVideo =
          options['mediaConstraints']?['mandatory']?['video'];

      final bool explicitlyWantsVideo =
          requestedVideo != null && requestedVideo != false;

      upgradeToVideo =
          (explicitlyWantsVideo || requestedMandatoryVideo != null) &&
              rtcOfferConstraints?['offerToReceiveVideo'] == null;
    } catch (e) {
      print('Failed to determine upgrade to video: $e');
    }

    if (!_isReadyToReOffer()) {
      return false;
    }

    handlers.on(EventSucceeded(), (EventSucceeded event) {
      if (done != null && event.response != null) {
        done(event.response!);
      }
    });

    handlers.on(EventCallFailed(), (EventCallFailed event) {
      terminate(<String, dynamic>{
        'cause': DartSIP_C.CausesType.WEBRTC_ERROR,
        'status_code': 500,
        'reason_phrase': 'Media Renegotiation Failed'
      });
    });

    _setLocalMediaStatus();

    if (options['useUpdate'] != null) {
      _sendUpdate(<String, dynamic>{
        'sdpOffer': true,
        'eventHandlers': handlers,
        'rtcOfferConstraints': rtcOfferConstraints,
        'extraHeaders': options['extraHeaders']
      });
    } else {
      if (upgradeToVideo ?? false) {
        _sendVideoUpgradeReinvite(<String, dynamic>{
          'eventHandlers': handlers,
          'sdpSemantics': sdpSemantics,
          'rtcOfferConstraints': rtcOfferConstraints,
          'mediaConstraints': mediaConstraints,
          'extraHeaders': options['extraHeaders']
        });
      } else {
        _sendReinvite(<String, dynamic>{
          'eventHandlers': handlers,
          'rtcOfferConstraints': rtcOfferConstraints,
          'extraHeaders': options['extraHeaders'],
          // After REFER/replace, WebRTC often needs a few ms before candidates
          // appear; a single offer can be m=audio 9 / no a=candidate — retry
          // instead of skipping re-INVITE (else RTP times out on same TCP).
          'icePoisonReinviteMaxRetries': 10,
          // Short delays + recreateOffer are not enough: trickle updates the
          // existing local description. Poll getLocalDescription until ICE
          // populates or timeout (attended-transfer consult leg).
          'reinviteIcePollMaxMs': 5000,
        });
      }
    }

    return true;
  }

  /**
   * Refer
   */
  ReferSubscriber? refer(dynamic target, [Map<String, dynamic>? options]) {
    logger.d('refer()');

    options = options ?? <String, dynamic>{};

    dynamic originalTarget = target;

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return null;
    }

    // Check target validity.
    target = _ua.normalizeTarget(target);
    if (target == null) {
      throw Exceptions.TypeError('Invalid target: $originalTarget');
    }

    ReferSubscriber referSubscriber = ReferSubscriber(this);

    referSubscriber.sendRefer(target, options);

    // Store in the map.
    int? id = referSubscriber.id;

    _referSubscribers[id] = referSubscriber;

    // Listen for ending events so we can remove it from the map.
    referSubscriber.on(EventReferRequestFailed(),
        (EventReferRequestFailed data) {
      _referSubscribers.remove(id);
    });
    referSubscriber.on(EventReferAccepted(), (EventReferAccepted data) {
      _referSubscribers.remove(id);
    });
    referSubscriber.on(EventReferFailed(), (EventReferFailed data) {
      _referSubscribers.remove(id);
    });

    return referSubscriber;
  }

  /**
   * Send a generic in-dialog Request
   */
  OutgoingRequest sendRequest(SipMethod method,
      [Map<String, dynamic>? options]) {
    logger.d('sendRequest()');

    final dialog = _dialog;
    if (dialog == null) {
      throw Exceptions.InvalidStateError(
          'Cannot send ${method.name}: dialog is null (session not established or already closed)');
    }
    return dialog.sendRequest(method, options);
  }

  /**
   * In dialog Request Reception
   */
  void _receiveRequest(IncomingRequest request) async {
    logger.d('receiveRequest()');

    if (request.method == SipMethod.CANCEL) {
      /* RFC3261 15 States that a UAS may have accepted an invitation while a CANCEL
      * was in progress and that the UAC MAY continue with the session established by
      * any 2xx response, or MAY terminate with BYE. DartSIP does continue with the
      * established session. So the CANCEL is processed only if the session is not yet
      * established.
      */

      /*
      * Terminate the whole session in case the user didn't accept (or yet send the answer)
      * nor reject the request opening the session.
      */
      if (_status == C.STATUS_WAITING_FOR_ANSWER ||
          _status == C.STATUS_ANSWERED) {
        _status = C.STATUS_CANCELED;
        _request.reply(487);
        _failed('remote', null, request, null, 487,
            DartSIP_C.CausesType.CANCELED, request.reason_phrase);
      }
    } else {
      // Requests arriving here are in-dialog requests.
      switch (request.method) {
        case SipMethod.ACK:
          if (_status != C.STATUS_WAITING_FOR_ACK) {
            return;
          }
          // Update signaling status.
          _status = C.STATUS_CONFIRMED;
          clearTimeout(_timers.ackTimer);
          clearTimeout(_timers.invite2xxTimer);

          if (_late_sdp) {
            if (request.body == null) {
              terminate(<String, dynamic>{
                'cause': DartSIP_C.CausesType.MISSING_SDP,
                'status_code': 400
              });
              break;
            }

            logger.d('emit "sdp"');
            emit(EventSdp(
                originator: 'remote', type: 'answer', sdp: request.body));

            RTCSessionDescription answer =
                RTCSessionDescription(request.body, 'answer');
            try {
              await _connection!.setRemoteDescription(answer);
            } catch (error) {
              terminate(<String, dynamic>{
                'cause': DartSIP_C.CausesType.BAD_MEDIA_DESCRIPTION,
                'status_code': 488
              });
              logger.e(
                  'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
              emit(EventSetRemoteDescriptionFailed(exception: error));
            }
          }
          if (!_is_confirmed) {
            _confirmed('remote', request);
          }
          break;
        case SipMethod.BYE:
          if (_status == C.STATUS_CONFIRMED) {
            request.reply(200);
            final reasonHeader =
                request.hasHeader('Reason') ? '${request.getHeader('Reason')}' : null;
            _ended(
                'remote',
                request,
                ErrorCause(
                    cause: DartSIP_C.CausesType.BYE,
                    status_code: 200,
                    reason_phrase: reasonHeader ?? 'BYE Received'));
          } else if (_status == C.STATUS_INVITE_RECEIVED) {
            request.reply(200);
            _request.reply(487, 'BYE Received');
            final reasonHeader =
                request.hasHeader('Reason') ? '${request.getHeader('Reason')}' : null;
            _ended(
                'remote',
                request,
                ErrorCause(
                    cause: DartSIP_C.CausesType.BYE,
                    status_code: request.status_code,
                    reason_phrase: reasonHeader ?? request.reason_phrase));
          } else {
            request.reply(403);
          }
          break;
        case SipMethod.INVITE:
          if (_status == C.STATUS_CONFIRMED) {
            if (request.hasHeader('replaces')) {
              _receiveReplaces(request);
            } else {
              _receiveReinvite(request);
            }
          } else {
            request.reply(403);
          }
          break;
        case SipMethod.INFO:
          if (_status == C.STATUS_1XX_RECEIVED ||
              _status == C.STATUS_WAITING_FOR_ANSWER ||
              _status == C.STATUS_ANSWERED ||
              _status == C.STATUS_WAITING_FOR_ACK ||
              _status == C.STATUS_CONFIRMED) {
            String? contentType = request.getHeader('content-type');
            if (contentType != null &&
                contentType.contains(RegExp(r'^application\/dtmf-relay',
                    caseSensitive: false))) {
              RTCSession_DTMF.DTMF(this).init_incoming(request);
            } else if (contentType != null) {
              RTCSession_Info.Info(this).init_incoming(request);
            } else {
              request.reply(415);
            }
          } else {
            request.reply(403);
          }
          break;
        case SipMethod.UPDATE:
          if (_status == C.STATUS_CONFIRMED) {
            _receiveUpdate(request);
          } else {
            request.reply(403);
          }
          break;
        case SipMethod.REFER:
          if (_status == C.STATUS_CONFIRMED) {
            _receiveRefer(request);
          } else {
            request.reply(403);
          }
          break;
        case SipMethod.NOTIFY:
          logger.d('SipMethod.NOTIFY status: $_status');
          if (_status == C.STATUS_CONFIRMED) {
            _receiveNotifyRefer(request);
          } else if (_status == C.STATUS_WAITING_FOR_ANSWER ||
              _status == C.STATUS_WAITING_FOR_ACK ||
              _status == C.STATUS_ANSWERED) {
            _receiveNotify(request);
          } else {
            request.reply(403);
          }

          break;
        default:
          request.reply(501);
      }
    }
  }

  /**
   * Session Callbacks
   */
  void onTransportError() {
    logger.e('onTransportError()');
    if (_status != C.STATUS_TERMINATED) {
      terminate(<String, dynamic>{
        'status_code': 500,
        'reason_phrase': DartSIP_C.CausesType.CONNECTION_ERROR,
        'cause': DartSIP_C.CausesType.CONNECTION_ERROR
      });
    }
  }

  void onRequestTimeout() {
    logger.e('onRequestTimeout()');

    logger.d(
      '📍 SIP-DIAG [REQUEST-TIMEOUT] session=$id '
      'status=$_status '
      'direction=$_direction '
      'call_id=${_request?.call_id} '
      '— will terminate with 408',
    );

    if (_status != C.STATUS_TERMINATED) {
      terminate(<String, dynamic>{
        'status_code': 408,
        'reason_phrase': DartSIP_C.CausesType.REQUEST_TIMEOUT,
        'cause': DartSIP_C.CausesType.REQUEST_TIMEOUT
      });
    }
  }

  void onDialogError([IncomingMessage? dialogErrorResponse]) {
    logger.e('onDialogError()');

    if (_status == C.STATUS_TERMINATED) {
      return;
    }
    final int? code = dialogErrorResponse is IncomingResponse
        ? dialogErrorResponse.status_code
        : null;
    // Dialog layer maps 408/481 to EventOnDialogError — peer cleared the dialog.
    if (code == 481 || code == 408) {
      terminate(<String, dynamic>{
        'skipBye': true,
        'status_code': code,
        'reason_phrase': dialogErrorResponse?.reason_phrase ??
            DartSIP_C.CausesType.DIALOG_ERROR,
        'cause': DartSIP_C.CausesType.DIALOG_ERROR,
      });
      return;
    }
    terminate(<String, dynamic>{
      'status_code': 500,
      'reason_phrase': DartSIP_C.CausesType.DIALOG_ERROR,
      'cause': DartSIP_C.CausesType.DIALOG_ERROR
    });
  }

  // Called from DTMF handler.
  void newDTMF(String originator, DTMF dtmf, dynamic request) {
    logger.d('newDTMF()');

    emit(EventNewDTMF(originator: originator, dtmf: dtmf, request: request));
  }

  // Called from Info handler.
  void newInfo(String originator, Info info, dynamic request) {
    logger.d('newInfo()');

    emit(EventNewInfo(originator: originator, info: info, request: request));
  }

  /**
   * Check if RTCSession is ready for an outgoing re-INVITE or UPDATE with SDP.
   */
  bool _isReadyToReOffer() {
    if (!_rtcReady) {
      logger.d('_isReadyToReOffer() | internal WebRTC status not ready');

      return false;
    }

    // No established yet.
    if (_dialog == null) {
      logger.d('_isReadyToReOffer() | session not established yet');

      return false;
    }

    // Another INVITE transaction is in progress.
    if (_dialog!.uac_pending_reply == true ||
        _dialog!.uas_pending_reply == true) {
      logger.d(
          '_isReadyToReOffer() | there is another INVITE/UPDATE transaction in progress');

      return false;
    }

    return true;
  }

  Future<void> _close() async {
    logger.d('close()');
    if (_status == C.STATUS_TERMINATED) {
      return;
    }
    _status = C.STATUS_TERMINATED;
    // Terminate RTC.
    if (_connection != null) {
      try {
        await _connection!.close();
        await _connection!.dispose();
        _connection = null;
      } catch (error) {
        logger.e(
            'close() | error closing the RTCPeerConnection: ${error.toString()}');
      }
    }
    // Close local MediaStream if it was not given by the user.
    if (_localMediaStream != null && _localMediaStreamLocallyGenerated) {
      logger.d('close() | closing local MediaStream');
      await _localMediaStream!.dispose();
      _localMediaStream = null;
    }

    // Terminate signaling.

    // Clear SIP timers.
    clearTimeout(_timers.ackTimer);
    clearTimeout(_timers.expiresTimer);
    clearTimeout(_timers.invite2xxTimer);
    clearTimeout(_timers.userNoAnswerTimer);
    _iceRestartDebounceTimer?.cancel();
    _iceRestartDebounceTimer = null;

    // Clear Session Timers.
    clearTimeout(_sessionTimers.timer);

    // Terminate confirmed dialog.
    if (_dialog != null) {
      _dialog!.terminate();
      _dialog = null;
    }

    // Terminate early dialogs.
    _earlyDialogs.forEach((String? key, _) {
      _earlyDialogs[key]!.terminate();
    });
    _earlyDialogs.clear();

    // Terminate REFER subscribers.
    _referSubscribers.clear();

    logger.d(
      '📍 SIP-DIAG [SESSION-CLOSE] session=$id '
      'call_id=${_request?.call_id} '
      'direction=$_direction '
      '— removed from ua._sessions',
    );
    _ua.destroyRTCSession(this);
  }

  /**
   * Private API.
   */

  /**
   * RFC3261 13.3.1.4
   * Response retransmissions cannot be accomplished by transaction layer
   *  since it is destroyed when receiving the first 2xx answer
   */
  void _setInvite2xxTimer(dynamic request, String? body) {
    int timeout = Timers.T1;

    void invite2xxRetransmission() {
      if (_status != C.STATUS_WAITING_FOR_ACK) {
        return;
      }
      request.reply(200, null, <String>['Contact: $_contact'], body);
      if (timeout < Timers.T2) {
        timeout = timeout * 2;
        if (timeout > Timers.T2) {
          timeout = Timers.T2;
        }
      }
      _timers.invite2xxTimer = setTimeout(invite2xxRetransmission, timeout);
    }

    _timers.invite2xxTimer = setTimeout(invite2xxRetransmission, timeout);
  }

  /**
   * RFC3261 14.2
   * If a UAS generates a 2xx response and never receives an ACK,
   *  it SHOULD generate a BYE to terminate the dialog.
   */
  void _setACKTimer() {
    _timers.ackTimer = setTimeout(() {
      if (_status == C.STATUS_TERMINATED) return;
      if (_status == C.STATUS_WAITING_FOR_ACK) {
        logger.d('no ACK received, terminating the session');

        clearTimeout(_timers.invite2xxTimer);
        sendRequest(SipMethod.BYE);
        _ended(
            'remote',
            null,
            ErrorCause(
                cause: DartSIP_C.CausesType.NO_ACK,
                status_code: 408, // Request Timeout
                reason_phrase: 'no ACK received, terminating the session'));
      }
    }, Timers.TIMER_H);
  }

  void _iceRestart() {
    _iceRestartDebounceTimer?.cancel();
    final int baseDebounceMs = 380;
    final int staggerMs = _ua.activeSessionCount > 1
        ? 120 + (identityHashCode(this) % 520)
        : 0;
    _iceRestartDebounceTimer =
        Timer(Duration(milliseconds: baseDebounceMs + staggerMs), () {
      _iceRestartDebounceTimer = null;
      if (_status == C.STATUS_TERMINATED || _connection == null) {
        return;
      }
      final Map<String, dynamic> offerConstraints = _rtcOfferConstraints ??
          <String, dynamic>{
            'mandatory': <String, dynamic>{},
            'optional': <dynamic>[],
          };
      offerConstraints['mandatory']['IceRestart'] = true;
      if (!renegotiate(options: offerConstraints)) {
        logger.d('ICE restart renegotiate skipped (dialog busy or not ready)');
      }
    });
  }

  Future<void> _createRTCConnection(Map<String, dynamic> pcConfig,
      Map<String, dynamic> rtcConstraints) async {
    _connection = await createPeerConnection(pcConfig, rtcConstraints);
    _connection!.onIceConnectionState = (RTCIceConnectionState state) {
      // TODO(cloudwebrtc): Do more with different states.
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        // Do NOT pass status_code here: when the session is still in the
        // INVITE/1XX phase, terminate() builds a CANCEL. If status_code is
        // set, it adds a "Reason: SIP ;cause=<code>" header.  FreeSWITCH
        // treats CANCEL with cause=408 ("RTP Timeout") as a network-level
        // event and may NOT propagate it to the B-leg, leaving zombie
        // channels.  Omitting status_code sends a plain CANCEL (no Reason
        // header) which FS always forwards correctly.
        terminate(<String, dynamic>{
          'cause': DartSIP_C.CausesType.RTP_TIMEOUT,
        });
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _iceRestart();
      }
    };

    // In future versions, unified-plan will be used by default
    String? sdpSemantics = 'unified-plan';
    if (pcConfig['sdpSemantics'] != null) {
      sdpSemantics = pcConfig['sdpSemantics'];
    }

    _connection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        emit(EventStream(
            session: this, originator: 'remote', stream: event.streams[0]));
      }
    };

    logger.d('emit "peerconnection"');
    emit(EventPeerConnection(_connection));
    return;
  }

  Future<RTCSessionDescription> _createLocalDescription(
      String type, Map<String, dynamic>? constraints) async {
    logger.d('createLocalDescription()');
    if (_connection == null || _status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError(
          'createLocalDescription() | peer connection gone or session ended');
    }
    _iceGatheringState ??= RTCIceGatheringState.RTCIceGatheringStateNew;
    Completer<RTCSessionDescription> completer =
        Completer<RTCSessionDescription>();

    constraints = constraints ??
        <String, dynamic>{
          'mandatory': <String, dynamic>{},
          'optional': <dynamic>[],
        };

    List<Future<RTCSessionDescription> Function(RTCSessionDescription)>
        modifiers = constraints['offerModifiers'] ??
            <Future<RTCSessionDescription> Function(RTCSessionDescription)>[];

    constraints['offerModifiers'] = null;

    if (type != 'offer' && type != 'answer') {
      completer.completeError(Exceptions.TypeError(
          'createLocalDescription() | invalid type "$type"'));
    }

    _rtcReady = false;
    late RTCSessionDescription desc;
    if (type == 'offer') {
      try {
        final pc = _connection;
        if (pc == null) {
          _rtcReady = true;
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | peer connection disposed before createOffer'));
          return completer.future;
        }
        desc = await pc.createOffer(constraints);
      } catch (error) {
        logger.e(
            'emit "peerconnection:createofferfailed" [error:${error.toString()}]');
        emit(EventCreateOfferFailed(exception: error));
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      }
    } else {
      try {
        final pc = _connection;
        if (pc == null) {
          _rtcReady = true;
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | peer connection disposed before createAnswer'));
          return completer.future;
        }
        desc = await pc.createAnswer(constraints);
      } catch (error) {
        logger.e(
            'emit "peerconnection:createanswerfailed" [error:${error.toString()}]');
        emit(EventCreateAnswerFialed(exception: error));
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      }
    }

    // Add 'pc.onicencandidate' event handler to resolve on last candidate.
    bool finished = false;

    for (Future<RTCSessionDescription> Function(RTCSessionDescription) modifier
        in modifiers) {
      desc = await modifier(desc);
    }

    Future<void> ready() async {
      if (finished || _status == C.STATUS_TERMINATED) {
        return;
      }
      final RTCPeerConnection? pc = _connection;
      if (pc == null) {
        if (!completer.isCompleted) {
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | peer connection disposed'));
        }
        return;
      }
      finished = true;
      pc.onIceCandidate = null;
      pc.onIceGatheringState = null;
      _iceGatheringState = RTCIceGatheringState.RTCIceGatheringStateComplete;
      _rtcReady = true;
      RTCSessionDescription? gathered;
      try {
        gathered = await pc.getLocalDescription();
      } catch (e) {
        if (e.toString().contains('peerConnection is null')) {
          if (!completer.isCompleted) {
            completer.completeError(Exceptions.InvalidStateError(
                'createLocalDescription() | peer connection disposed'));
          }
          return;
        }
        rethrow;
      }
      if (gathered == null) {
        if (!completer.isCompleted) {
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | missing local SDP'));
        }
        return;
      }
      logger.d('emit "sdp"');
      emit(EventSdp(originator: 'local', type: type, sdp: gathered.sdp));
      completer.complete(gathered);
    }

    if (_connection == null) {
      _rtcReady = true;
      if (!completer.isCompleted) {
        completer.completeError(Exceptions.InvalidStateError(
            'createLocalDescription() | peer connection disposed before ICE setup'));
      }
      return completer.future;
    }

    _connection!.onIceGatheringState = (RTCIceGatheringState state) {
      _iceGatheringState = state;
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        ready();
      }
    };

    bool hasCandidate = false;
    _connection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate != null) {
        emit(EventIceCandidate(candidate, ready));
        if (!hasCandidate) {
          hasCandidate = true;
          /**
           *  Just wait for 0.5 seconds. In the case of multiple network connections,
           *  the RTCIceGatheringStateComplete event needs to wait for 10 ~ 30 seconds.
           *  Because trickle ICE is not defined in the sip protocol, the delay of
           * initiating a call to answer the call waiting will be unacceptable.
           */
          if (ua.configuration.ice_gathering_timeout != 0) {
            setTimeout(() => ready(), ua.configuration.ice_gathering_timeout);
          }
        }
      }
    };

    try {
      final pc = _connection;
      if (pc == null) {
        _rtcReady = true;
        if (!completer.isCompleted) {
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | peer connection disposed before setLocalDescription'));
        }
        return completer.future;
      }
      await pc.setLocalDescription(desc);
    } catch (error) {
      _rtcReady = true;
      final errStr = error.toString();
      if (errStr.contains('peerConnection is null')) {
        logger.w('setLocalDescription skipped: peerConnection already disposed');
        if (!completer.isCompleted) {
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | peer connection disposed during setLocalDescription'));
        }
        return completer.future;
      }
      logger.e(
          'emit "peerconnection:setlocaldescriptionfailed" [error:$errStr]');
      emit(EventSetLocalDescriptionFailed(exception: error));
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    // Resolve right away if 'pc.iceGatheringState' is 'complete'.
    if (_iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      _rtcReady = true;
      final RTCPeerConnection? pc = _connection;
      if (pc == null) {
        completer.completeError(Exceptions.InvalidStateError(
            'createLocalDescription() | peer connection disposed'));
        return completer.future;
      }
      try {
        RTCSessionDescription? desc = await pc.getLocalDescription();
        if (desc?.sdp == null) {
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | missing local SDP'));
          return completer.future;
        }
        logger.d('emit "sdp"');
        emit(EventSdp(originator: 'local', type: type, sdp: desc!.sdp));
        return desc;
      } catch (e) {
        final msg = e.toString();
        if (msg.contains('peerConnection is null')) {
          completer.completeError(Exceptions.InvalidStateError(
              'createLocalDescription() | peer connection disposed'));
          return completer.future;
        }
        rethrow;
      }
    }

    return completer.future;
  }

  /**
   * Dialog Management
   */
  bool _createDialog(dynamic message, String type, [bool early = false]) {
    String? local_tag = (type == 'UAS') ? message.to_tag : message.from_tag;
    String? remote_tag = (type == 'UAS') ? message.from_tag : message.to_tag;
    String? id = message.call_id + local_tag + remote_tag;
    Dialog? early_dialog = _earlyDialogs[id];

    // Early Dialog.
    if (early) {
      if (early_dialog != null) {
        return true;
      } else {
        try {
          early_dialog = Dialog(this, message, type, DialogStatus.STATUS_EARLY);
        } catch (error) {
          logger.d('$error');
          _failed(
              'remote',
              message,
              null,
              null,
              500,
              DartSIP_C.CausesType.INTERNAL_ERROR,
              'Can\'t create Early Dialog');
          return false;
        }
        // Dialog has been successfully created.
        _earlyDialogs[id] = early_dialog;
        return true;
      }
    } else {
      // Confirmed Dialog.
      _from_tag = message.from_tag;
      _to_tag = message.to_tag;

      // In case the dialog is in _early_ state, update it.
      if (early_dialog != null) {
        early_dialog.update(message, type);
        _dialog = early_dialog;
        _earlyDialogs.remove(id);
        return true;
      }

      try {
        // Otherwise, create a _confirmed_ dialog.
        _dialog = Dialog(this, message, type);
        return true;
      } catch (error) {
        logger.d(error.toString());
        _failed(
            'remote',
            message,
            null,
            null,
            500,
            DartSIP_C.CausesType.INTERNAL_ERROR,
            'Can\'t create Confirmed Dialog');
        return false;
      }
    }
  }

  /// In dialog INVITE Reception
  void _receiveReinvite(IncomingRequest request) async {
    logger.d('receiveReinvite()');
    String? contentType = request.getHeader('Content-Type');

    void sendAnswer(String? sdp) async {
      List<String> extraHeaders = <String>['Contact: $_contact'];

      _handleSessionTimersInIncomingRequest(request, extraHeaders);

      if (_late_sdp) {
        sdp = _mangleOffer(sdp);
      }

      request.reply(200, null, extraHeaders, sdp, () {
        _status = C.STATUS_WAITING_FOR_ACK;
        _setInvite2xxTimer(request, sdp);
        _setACKTimer();
      });

      // If callback is given execute it.
      if (data!['callback'] is Function) {
        data!['callback']();
      }
    }

    _late_sdp = false;

    // Request without SDP.
    if (request.body == null) {
      _late_sdp = true;

      try {
        RTCSessionDescription desc =
            await _createLocalDescription('offer', _rtcOfferConstraints);
        sendAnswer(desc.sdp);
      } catch (_) {
        request.reply(500);
      }
      return;
    }

    // Request without SDP.
    if (contentType != 'application/sdp') {
      logger.d('invalid Content-Type');
      request.reply(415);
      return;
    }

    bool reject(dynamic options) {
      int status_code = options['status_code'] ?? 403;
      String? reason_phrase = options['reason_phrase'];
      List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);

      if (_status != C.STATUS_CONFIRMED) {
        return false;
      }

      if (status_code < 300 || status_code >= 700) {
        throw Exceptions.TypeError('Invalid status_code: $status_code');
      }
      print('Rejecting with status code: $status_code, reason: $reason_phrase');
      request.reply(status_code, reason_phrase, extraHeaders);
      return true;
    }

    // _processInDialogSdpOffer sends appropriate SIP error responses and returns
    // null on failure (including session terminated during negotiation).
    late final RTCSessionDescription? desc;
    try {
      desc = await _processInDialogSdpOffer(request);
    } catch (error, stackTrace) {
      logger.e(
        're-INVITE: in-dialog SDP offer failed (SIP response may already be sent): $error\n$stackTrace',
      );
      return;
    }
    if (desc == null) {
      return;
    }
    final RTCSessionDescription reinviteAnswer = desc;

    Future<bool> acceptReInvite(dynamic options) async {
      try {
        // Send answer.
        if (_status == C.STATUS_TERMINATED) {
          return false;
        }
        sendAnswer(reinviteAnswer.sdp);
      } catch (error) {
        logger.e('Got anerror on re-INVITE: ${error.toString()}');
      }

      return true;
    }

    String body = request.body ?? '';
    bool hasAudio = false;
    bool hasVideo = false;
    if (request.sdp == null && body.isNotEmpty) {
      request.sdp = sdp_transform.parse(body);
    }
    List<dynamic> media = request.sdp?['media'];
    for (Map<String, dynamic> m in media) {
      if (m['type'] == 'audio') {
        hasAudio = true;
      } else if (m['type'] == 'video') {
        hasVideo = true;
      }
    }
    emit(EventReInvite(
        request: request,
        hasAudio: hasAudio,
        hasVideo: hasVideo,
        callback: acceptReInvite,
        reject: reject));
  }

  /**
   * In dialog UPDATE Reception
   */
  void _receiveUpdate(IncomingRequest request) async {
    logger.d('receiveUpdate()');

    bool rejected = false;

    bool reject(Map<String, dynamic> options) {
      rejected = true;

      int status_code = options['status_code'] ?? 403;
      String reason_phrase = options['reason_phrase'] ?? '';
      List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);

      if (_status != C.STATUS_CONFIRMED) {
        return false;
      }

      if (status_code < 300 || status_code >= 700) {
        throw Exceptions.TypeError('Invalid status_code: $status_code');
      }

      request.reply(status_code, reason_phrase, extraHeaders);
      return true;
    }

    String? contentType = request.getHeader('Content-Type');

    void sendAnswer(String? sdp) {
      List<String> extraHeaders = <String>['Contact: $_contact'];
      _handleSessionTimersInIncomingRequest(request, extraHeaders);
      request.reply(200, null, extraHeaders, sdp);
    }

    // Emit 'update'.
    emit(EventUpdate(request: request, callback: null, reject: reject));

    if (rejected) {
      return;
    }

    if (request.body == null || request.body!.isEmpty) {
      sendAnswer(null);
      return;
    }

    if (contentType != 'application/sdp') {
      logger.d('invalid Content-Type');

      request.reply(415);

      return;
    }

    try {
      RTCSessionDescription? desc = await _processInDialogSdpOffer(request);
      if (desc == null || _status == C.STATUS_TERMINATED) return;
      // Send answer.
      sendAnswer(desc.sdp);
    } catch (error) {
      logger.e('Got error on UPDATE: ${error.toString()}');
    }
  }

  Future<RTCSessionDescription?> _processInDialogSdpOffer(
      IncomingRequest request) async {
    logger.d('_processInDialogSdpOffer()');

    Map<String, dynamic>? sdp = request.parseSDP();

    bool hold = false;
    bool upgradeToVideo = false;
    if (sdp != null) {
      List<dynamic> mediaList = sdp['media'];

      // Loop media list items for video upgrade
      for (Map<String, dynamic> media in mediaList) {
        if (holdMediaTypes.indexOf(media['type']) == -1) continue;
        if (media['type'] == 'video') upgradeToVideo = true;
      }
      // Loop media list items for hold
      for (Map<String, dynamic> media in mediaList) {
        if (holdMediaTypes.indexOf(media['type']) == -1) continue;
        String direction = media['direction'] ?? sdp['direction'] ?? 'sendrecv';
        if (direction == 'sendonly' || direction == 'inactive') {
          hold = true;
        }
        // If at least one of the streams is active don't emit 'hold'.
        else {
          hold = false;
        }
      }
    }

    if (upgradeToVideo) {
      Map<String, dynamic> mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': <String, dynamic>{
          'mandatory': <String, dynamic>{
            'minWidth': '640',
            'minHeight': '480',
            'minFrameRate': '30',
          },
          'facingMode': 'user',
        }
      };
      bool hasCamera = false;
      try {
        List<MediaDeviceInfo> devices =
            await navigator.mediaDevices.enumerateDevices();
        for (MediaDeviceInfo device in devices) {
          if (device.kind == 'videoinput') hasCamera = true;
        }
      } catch (e) {
        logger.w('Failed to enumerate devices: $e');
      }
      if (hasCamera) {
        MediaStream localStream =
            await navigator.mediaDevices.getUserMedia(mediaConstraints);
        if (localStream.getVideoTracks().isEmpty) {
          logger.w(
              'Remote wants to upgrade to video but failed to get local video');
        }
        for (MediaStreamTrack track in localStream.getTracks()) {
          if (track.kind == 'video') {
            _connection!.addTrack(track, localStream);
          }
        }
        emit(EventStream(
            session: this, originator: 'local', stream: localStream));
      } else {
        logger.w(
            'Remote wants to upgrade to video but no camera available to send');
      }
    }

    logger.d('emit "sdp"');
    final String? processedSDP = await _sdpOfferToWebRtcAsync(request.body);
    emit(EventSdp(originator: 'remote', type: 'offer', sdp: processedSDP));

    RTCSessionDescription offer = RTCSessionDescription(processedSDP, 'offer');

    if (_status == C.STATUS_TERMINATED) {
      try {
        request.reply(481);
      } catch (e, st) {
        logger.e('reply(481) after terminated (pre setRemoteDescription): $e\n$st');
      }
      return null;
    }
    try {
      await _connection!.setRemoteDescription(offer);
    } catch (error) {
      try {
        request.reply(488);
      } catch (e, st) {
        logger.e('reply(488) after setRemoteDescription failure: $e\n$st');
      }
      logger.e(
          'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');

      emit(EventSetRemoteDescriptionFailed(exception: error));

      return null;
    }

    if (_status == C.STATUS_TERMINATED) {
      try {
        request.reply(500);
      } catch (e, st) {
        logger.e('reply(500) after terminated (post setRemoteDescription): $e\n$st');
      }
      return null;
    }

    if (_remoteHold == true && hold == false) {
      _remoteHold = false;
      _onunhold('remote');
    } else if (_remoteHold == false && hold == true) {
      _remoteHold = true;
      _onhold('remote');
    }

    // Create local description.

    if (_status == C.STATUS_TERMINATED) {
      try {
        request.reply(500);
      } catch (e, st) {
        logger.e(
            'reply(500) after terminated (before createLocalDescription): $e\n$st');
      }
      return null;
    }

    try {
      return await _createLocalDescription('answer', _rtcAnswerConstraints);
    } catch (_) {
      try {
        request.reply(500);
      } catch (e, st) {
        logger.e('reply(500) after _createLocalDescription failure: $e\n$st');
      }
      return null;
    }
  }

  /**
   * In dialog Refer Reception
   */
  void _receiveRefer(IncomingRequest request) {
    logger.d('receiveRefer()');

    if (request.refer_to == null) {
      logger.d('no Refer-To header field present in REFER');
      request.reply(400);

      return;
    }

    if (request.refer_to.uri.scheme != DartSIP_C.SIP) {
      logger.d('Refer-To header field points to a non-SIP URI scheme');
      request.reply(416);
      return;
    }

    // Reply before the transaction timer expires.
    request.reply(202);

    ReferNotifier notifier = ReferNotifier(this, request.cseq);

    bool accept2(
        InitSuccessCallback? initCallback, Map<String, dynamic> options) {
      initCallback = (initCallback is Function) ? initCallback : null;

      if (_status != C.STATUS_WAITING_FOR_ACK &&
          _status != C.STATUS_CONFIRMED) {
        return false;
      }

      RTCSession session = RTCSession(_ua);

      session.on(EventCallProgress(), (EventCallProgress event) {
        notifier.notify(
            event.response.status_code, event.response.reason_phrase);
      });

      session.on(EventCallAccepted(), (EventCallAccepted event) {
        notifier.notify(
            event.response.status_code, event.response.reason_phrase);
      });

      session.on(EventFailedUnderScore(), (EventFailedUnderScore data) {
        if (data.cause != null) {
          notifier.notify(data.cause!.status_code, data.cause!.reason_phrase);
        } else {
          notifier.notify(487, data.cause!.cause);
        }
      });
      // Consider the Replaces header present in the Refer-To URI.
      if (request.refer_to.uri.hasHeader('replaces')) {
        String replaces = utils
            .decodeURIComponent(request.refer_to.uri.getHeader('replaces'));

        options['extraHeaders'] = utils.cloneArray(options['extraHeaders']);
        options['extraHeaders'].add('Replaces: $replaces');
      }
      session.connect(request.refer_to.uri.toAor(), options, initCallback);
      return true;
    }

    void reject() {
      notifier.notify(603);
    }

    logger.d('emit "refer"');

    // Emit 'refer'.
    emit(EventCallRefer(
        session: this,
        aor: request.refer_to.uri.toAor(),
        accept:
            (InitSuccessCallback initCallback, Map<String, dynamic> options) {
          accept2(initCallback, options);
        },
        reject: (_) {
          reject();
        }));
  }

  void _receiveNotifyRefer(IncomingRequest request) {
    logger.d('receiveNotifyRefer()');

    if (request.event == null) {
      request.reply(400);
    }

    switch (request.event!.event) {
      case 'refer':
        int? id;
        ReferSubscriber? referSubscriber;

        if (request.event!.params!['id'] != null) {
          id = int.tryParse(request.event!.params!['id'], radix: 10);
          referSubscriber = _referSubscribers[id];
        } else if (_referSubscribers.length == 1) {
          referSubscriber =
              _referSubscribers[_referSubscribers.keys.toList()[0]];
        } else {
          request.reply(400, 'Missing event id parameter');

          return;
        }

        if (referSubscriber == null) {
          request.reply(481, 'Subscription does not exist');

          return;
        }

        // Ack NOTIFY before emitting EventReferAccepted so FS sees 200 OK
        // before any app handler that may BYE the dialog.
        request.reply(200);
        referSubscriber.receiveNotify(request);

        break;

      case 'talk':
        request.reply(200);
        break;
      default:
        request.reply(489);
    }
  }

  /**
   * In dialog Notify Reception
   */
  void _receiveNotify(IncomingRequest request) {
    logger.d('receiveNotify()');
    if (request.event == null) {
      request.reply(400);
    }
    switch (request.event!.event) {
      case 'talk':
        request.reply(200);
        break;
      default:
        request.reply(489);
    }
  }

  /**
   * INVITE with Replaces Reception
   */
  void _receiveReplaces(IncomingRequest request) {
    logger.d('receiveReplaces()');

    bool accept(InitSuccessCallback initCallback) {
      if (_status != C.STATUS_WAITING_FOR_ACK &&
          _status != C.STATUS_CONFIRMED) {
        return false;
      }

      RTCSession session = RTCSession(_ua);

      // Terminate the current session when the one is confirmed.
      session.on(EventCallConfirmed(), (EventCallConfirmed data) {
        terminate();
      });

      session.init_incoming(request, initCallback);
      return true;
    }

    void reject() {
      logger.d('Replaced INVITE rejected by the user');
      request.reply(486);
    }

    // Emit 'replace'.
    emit(EventReplaces(
        request: request,
        accept: (InitSuccessCallback initCallback) {
          accept(initCallback);
        },
        reject: () {
          reject();
        }));
  }

  /**
   * Initial Request Sender
   */
  Future<void> _sendInitialRequest(
      Map<String, dynamic> pcConfig,
      Map<String, dynamic> mediaConstraints,
      Map<String, dynamic> rtcOfferConstraints,
      MediaStream? mediaStream) async {
    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      onRequestTimeout();
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      onTransportError();
    });
    handlers.on(EventOnAuthenticated(), (EventOnAuthenticated event) {
      _request = event.request;
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      _receiveInviteResponse(event.response);
    });

    RequestSender request_sender = RequestSender(_ua, _request, handlers);

    // In future versions, unified-plan will be used by default
    String? sdpSemantics = 'unified-plan';
    if (pcConfig['sdpSemantics'] != null) {
      sdpSemantics = pcConfig['sdpSemantics'];
    }

    // This Promise is resolved within the next iteration, so the app has now
    // a chance to set events such as 'peerconnection' and 'connecting'.
    MediaStream? stream;
    // A stream is given, var the app set events such as 'peerconnection' and 'connecting'.
    if (mediaStream != null) {
      stream = mediaStream;
      emit(EventStream(session: this, originator: 'local', stream: stream));
    } // Request for user media access.
    else if (mediaConstraints['audio'] != null ||
        mediaConstraints['video'] != null) {
      _localMediaStreamLocallyGenerated = true;
      try {
        stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
        emit(EventStream(session: this, originator: 'local', stream: stream));
      } catch (error) {
        if (_status == C.STATUS_TERMINATED) {
          throw Exceptions.InvalidStateError('terminated');
        }
        _failed(
            'local',
            null,
            null,
            null,
            500,
            DartSIP_C.CausesType.USER_DENIED_MEDIA_ACCESS,
            'User Denied Media Access');
        logger.e('emit "getusermediafailed" [error:${error.toString()}]');
        emit(EventGetUserMediaFailed(exception: error));
        rethrow;
      }
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    _localMediaStream = stream;

    if (stream != null) {
      stream.getTracks().forEach((MediaStreamTrack track) {
        _connection!.addTrack(track, stream!);
      });
    }

    // TODO(cloudwebrtc): should this be triggered here?
    _connecting(_request);
    try {
      RTCSessionDescription desc =
          await _createLocalDescription('offer', rtcOfferConstraints);
      if (_is_canceled || _status == C.STATUS_TERMINATED) {
        throw Exceptions.InvalidStateError('terminated');
      }

      _request.body = desc.sdp;
      _status = C.STATUS_INVITE_SENT;

      logger.d('emit "sending" [request]');

      // Emit 'sending' so the app can mangle the body before the request is sent.
      emit(EventSending(request: _request));

      request_sender.send();
    } catch (error, s) {
      logger.e(error.toString(), error: error, stackTrace: s);
      _failed('local', null, null, null, 500, DartSIP_C.CausesType.WEBRTC_ERROR,
          'Can\'t create local SDP');
      if (_status == C.STATUS_TERMINATED) {
        return;
      }
      logger.e('Failed to _sendInitialRequest: ${error.toString()}');
      rethrow;
    }
  }

  /// Reception of Response for Initial INVITE
  void _receiveInviteResponse(IncomingResponse? response) async {
    logger.d('receiveInviteResponse()  current status: $_status ');

    if (response == null) {
      logger.d('No response received');
      return;
    }
    response.sdp = sdp_transform.parse(response.body ?? '');

    /// Handle 2XX retransmissions and responses from forked requests.
    if (_dialog != null &&
        (response.status_code >= 200 && response.status_code <= 299)) {
      ///
      /// If it is a retransmission from the endpoint that established
      /// the dialog, send an ACK
      ///
      if (_dialog!.id!.call_id == response.call_id &&
          _dialog!.id!.local_tag == response.from_tag &&
          _dialog!.id!.remote_tag == response.to_tag) {
        sendRequest(SipMethod.ACK);
        return;
      } else {
        // If not, send an ACK  and terminate.
        try {
          // ignore: unused_local_variable
          Dialog dialog = Dialog(this, response, 'UAC');
        } catch (error) {
          logger.d(error.toString());
          return;
        }
        sendRequest(SipMethod.ACK);
        sendRequest(SipMethod.BYE);
        return;
      }
    }

    // Proceed to cancellation if the user requested.
    if (_is_canceled) {
      if (response.status_code >= 100 && response.status_code < 200) {
        _request.cancel(_cancel_reason);
      } else if (response.status_code >= 200 && response.status_code < 299) {
        _acceptAndTerminate(response);
      }
      return;
    }

    if (_status != C.STATUS_INVITE_SENT && _status != C.STATUS_1XX_RECEIVED) {
      return;
    }

    String status_code = response.status_code.toString();

    if (utils.test100(status_code)) {
      // 100 trying
      _status = C.STATUS_1XX_RECEIVED;
    } else if (utils.test1XX(status_code)) {
      // 1XX
      // Do nothing with 1xx responses without To tag.
      if (response.to_tag == null) {
        logger.d('1xx response received without to tag');
        return;
      }

      // Create Early Dialog if 1XX comes with contact.
      if (response.hasHeader('contact')) {
        // An error on dialog creation will fire 'failed' event.
        if (!_createDialog(response, 'UAC', true)) {
          return;
        }
      }

      _status = C.STATUS_1XX_RECEIVED;
      _progress('remote', response, int.parse(status_code));

      if (response.body == null || response.body!.isEmpty) {
        return;
      }

      logger.d('emit "sdp"');
      emit(EventSdp(originator: 'remote', type: 'answer', sdp: response.body));

      RTCSessionDescription answer =
          RTCSessionDescription(response.body, 'answer');

      try {
        await _connection!.setRemoteDescription(answer);
      } catch (error) {
        logger.e(
            'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
        emit(EventSetRemoteDescriptionFailed(exception: error));
      }
    } else if (utils.test2XX(status_code)) {
      // 2XX
      _status = C.STATUS_CONFIRMED;

      if (response.body == null || response.body!.isEmpty) {
        _acceptAndTerminate(response, 400, DartSIP_C.CausesType.MISSING_SDP);
        _failed('remote', null, null, response, 400,
            DartSIP_C.CausesType.BAD_MEDIA_DESCRIPTION, 'Missing SDP');
        return;
      }

      dynamic mediaPort = response.sdp?['media'][0]['port'] ?? 0;

      if (mediaPort == 0 && _ua.configuration.terminateOnAudioMediaPortZero) {
        _acceptAndTerminate(response, 400, DartSIP_C.CausesType.MISSING_SDP);
        _failed('remote', null, null, response, 400,
            DartSIP_C.CausesType.BAD_MEDIA_DESCRIPTION, 'Media port is zero');
        return;
      }

      // An error on dialog creation will fire 'failed' event.
      if (_createDialog(response, 'UAC') == null) {
        return;
      }

      logger.d('emit "sdp"');
      emit(EventSdp(originator: 'remote', type: 'answer', sdp: response.body));

      RTCSessionDescription answer =
          RTCSessionDescription(response.body, 'answer');

      // Be ready for 200 with SDP after a 180/183 with SDP.
      // We created a SDP 'answer' for it, so check the current signaling state.
      final RTCPeerConnection? pc200 = _connection;
      if (pc200 != null &&
          (pc200.signalingState ==
                  RTCSignalingState.RTCSignalingStateStable ||
              pc200.signalingState ==
                  RTCSignalingState.RTCSignalingStateHaveLocalOffer)) {
        try {
          RTCSessionDescription offer =
              await pc200.createOffer(_rtcOfferConstraints!);
          // Re-check: connection may have been disposed during async createOffer.
          if (_connection == null) {
            logger.w('peerConnection disposed between createOffer and setLocalDescription (200 OK handler)');
          } else {
            await _connection!.setLocalDescription(offer);
          }
        } catch (error) {
          final errStr = error.toString();
          if (errStr.contains('peerConnection is null')) {
            logger.w('setLocalDescription skipped in 200 OK handler: peerConnection already disposed');
          } else {
            _acceptAndTerminate(response, 500, errStr);
            _failed(
                'local',
                null,
                null,
                response,
                500,
                DartSIP_C.CausesType.WEBRTC_ERROR,
                'Can\'t create offer $errStr');
          }
        }
      }

      try {
        if (_connection == null) {
          logger.w('peerConnection disposed before setRemoteDescription (200 OK handler)');
          return;
        }
        await _connection!.setRemoteDescription(answer);
        // Handle Session Timers.
        _handleSessionTimersInIncomingResponse(response);
        _accepted('remote', response);
        OutgoingRequest ack = sendRequest(SipMethod.ACK);
        _confirmed('local', ack);
      } catch (error) {
        final errStr = error.toString();
        if (errStr.contains('peerConnection is null')) {
          logger.w('setRemoteDescription skipped in 200 OK handler: peerConnection already disposed');
          return;
        }
        _acceptAndTerminate(response, 488, 'Not Acceptable Here');
        _failed('remote', null, null, response, 488,
            DartSIP_C.CausesType.BAD_MEDIA_DESCRIPTION, 'Not Acceptable Here');
        logger.e(
            'emit "peerconnection:setremotedescriptionfailed" [error:$errStr]');
        emit(EventSetRemoteDescriptionFailed(exception: error));
      }
    } else {
      String cause = utils.sipErrorCause(response.status_code);
      _failed('remote', null, null, response, response.status_code, cause,
          response.reason_phrase);
    }
  }

  /// While local offer is ICE-poison (e.g. m=audio 9), the same offer often
  /// becomes valid as candidates arrive — without a new createOffer.
  Future<String?> _pollMangledOfferUntilIceNotPoison(Duration maxWait) async {
    final DateTime deadline = DateTime.now().add(maxWait);
    while (DateTime.now().isBefore(deadline)) {
      final RTCPeerConnection? pc = _connection;
      if (_status == C.STATUS_TERMINATED || pc == null) {
        return null;
      }
      RTCSessionDescription? loc;
      try {
        loc = await pc.getLocalDescription();
      } catch (e) {
        if (e.toString().contains('peerConnection is null')) {
          return null;
        }
        rethrow;
      }
      if (loc?.sdp != null) {
        final String? mangled = _mangleOffer(loc!.sdp);
        if (mangled != null && !_isReinviteOfferSdpIcePoison(mangled)) {
          return mangled;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /**
   * Send Re-INVITE
   */
  void _sendReinvite([Map<String, dynamic>? options]) async {
    logger.d('sendReinvite()');
    final Map<String, dynamic> opts = options ?? <String, dynamic>{};

    await _runSerializedClientReinvite(() async {
      final Completer<void> inviteTransactionDone = Completer<void>();
      void markInviteTransactionDone() {
        if (!inviteTransactionDone.isCompleted) {
          inviteTransactionDone.complete();
        }
      }

      if (_status == C.STATUS_TERMINATED || _connection == null) {
        markInviteTransactionDone();
        return;
      }

      List<dynamic> extraHeaders = opts['extraHeaders'] != null
          ? utils.cloneArray(opts['extraHeaders'])
          : <dynamic>[];
      EventManager eventHandlers = opts['eventHandlers'] ?? EventManager();
      Map<String, dynamic>? rtcOfferConstraints =
          opts['rtcOfferConstraints'] ?? _rtcOfferConstraints;

      bool succeeded = false;

      extraHeaders.add('Contact: $_contact');
      extraHeaders.add('Content-Type: application/sdp');

      // Session Timers.
      if (_sessionTimers.running) {
        extraHeaders.add(
            'Session-Expires: ${_sessionTimers.currentExpires};refresher=${_sessionTimers.refresher ? 'uac' : 'uas'}');
      }

      void onFailed([dynamic response]) {
        if (_status != C.STATUS_TERMINATED) {
          eventHandlers.emit(EventCallFailed(session: this, response: response));
        }
        markInviteTransactionDone();
      }

      void onSucceeded(IncomingResponse? response) async {
        if (_status == C.STATUS_TERMINATED) {
          markInviteTransactionDone();
          return;
        }

        sendRequest(SipMethod.ACK);

        // If it is a 2XX retransmission exit now.
        if (succeeded) {
          markInviteTransactionDone();
          return;
        }

        // Handle Session Timers.
        _handleSessionTimersInIncomingResponse(response);

        // Must have SDP answer.
        if (response!.body == null || response.body!.isEmpty) {
          onFailed();
          return;
        } else if (response.getHeader('Content-Type') != 'application/sdp') {
          onFailed();
          return;
        }

        logger.d('emit "sdp"');
        emit(EventSdp(originator: 'remote', type: 'answer', sdp: response.body));

        RTCSessionDescription answer =
            RTCSessionDescription(response.body, 'answer');

        try {
          await _connection!.setRemoteDescription(answer);
          eventHandlers.emit(EventSucceeded(response: response));
        } catch (error) {
          onFailed();
          logger.e(
              'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
          emit(EventSetRemoteDescriptionFailed(exception: error));
          return;
        }
        markInviteTransactionDone();
      }

      try {
        RTCSessionDescription desc =
            await _createLocalDescription('offer', rtcOfferConstraints);
        String? sdp = _mangleOffer(desc.sdp);

        final int icePollMaxMs = (opts['reinviteIcePollMaxMs'] is int)
            ? opts['reinviteIcePollMaxMs'] as int
            : 0;
        if (icePollMaxMs > 0 && _isReinviteOfferSdpIcePoison(sdp)) {
          logger.d(
              'sendReinvite() | ICE poison after createOffer, polling local SDP up to ${icePollMaxMs}ms');
          final String? polled = await _pollMangledOfferUntilIceNotPoison(
              Duration(milliseconds: icePollMaxMs));
          if (polled != null) {
            sdp = polled;
          }
        }

        final int icePoisonMaxRetries =
            (opts['icePoisonReinviteMaxRetries'] is int)
                ? opts['icePoisonReinviteMaxRetries'] as int
                : 0;
        int poisonAttempt = 0;
        while (_isReinviteOfferSdpIcePoison(sdp)) {
          if (poisonAttempt >= icePoisonMaxRetries) {
            break;
          }
          poisonAttempt++;
          logger.d(
              'sendReinvite() | ICE not ready in offer, retry $poisonAttempt/$icePoisonMaxRetries after short delay');
          await Future<void>.delayed(
              Duration(milliseconds: 60 + 40 * poisonAttempt));
          if (_status == C.STATUS_TERMINATED || _connection == null) {
            markInviteTransactionDone();
            return;
          }
          desc =
              await _createLocalDescription('offer', rtcOfferConstraints);
          sdp = _mangleOffer(desc.sdp);
        }

        final bool bypassViability =
            opts['bypassReinviteSdpViability'] == true;
        if (_isReinviteOfferSdpIcePoison(sdp)) {
          logger.w(
              'sendReinvite() | offer SDP ICE not ready after $icePoisonMaxRetries retries; skip re-INVITE');
          markInviteTransactionDone();
        } else if (!bypassViability && !_isReinviteOfferSdpViable(sdp)) {
          logger.w(
              'sendReinvite() | offer SDP not viable (no usable audio port/ICE); skip sending re-INVITE');
          markInviteTransactionDone();
        } else {
          logger.d('emit "sdp"');
          emit(EventSdp(originator: 'local', type: 'offer', sdp: sdp));

          EventManager handlers = EventManager();
          handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
            onSucceeded(event.response as IncomingResponse?);
            succeeded = true;
          });
          handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
            onFailed(event.response);
          });
          handlers.on(EventOnTransportError(), (EventOnTransportError event) {
            onTransportError(); // Do nothing because session ends.
            markInviteTransactionDone();
          });
          handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
            logger.w(
                're-INVITE timed out (Timer B); leaving dialog up (media may be stale)');
            markInviteTransactionDone();
          });
          handlers.on(EventOnDialogError(), (EventOnDialogError event) {
            onDialogError(event.response);
            markInviteTransactionDone();
          });

          sendRequest(SipMethod.INVITE, <String, dynamic>{
            'extraHeaders': extraHeaders,
            'body': sdp,
            'eventHandlers': handlers
          });
        }
      } catch (e, s) {
        logger.e(e.toString(), error: e, stackTrace: s);
        onFailed();
      }
      await inviteTransactionDone.future;
    });
  }

  /**
   * Send Re-INVITE
   */
  void _sendVideoUpgradeReinvite([Map<String, dynamic>? options]) async {
    logger.d('sendVideoUpgradeReinvite()');

    options = options ?? <String, dynamic>{};

    List<dynamic> extraHeaders = options['extraHeaders'] != null
        ? utils.cloneArray(options['extraHeaders'])
        : <dynamic>[];
    EventManager eventHandlers = options['eventHandlers'] ?? EventManager();
    Map<String, dynamic>? rtcOfferConstraints =
        options['rtcOfferConstraints'] ?? _rtcOfferConstraints;

    Map<String, dynamic> mediaConstraints =
        options['mediaConstraints'] ?? <String, dynamic>{};

    mediaConstraints['audio'] = false;

    dynamic sdpSemantics =
        options['pcConfig']?['sdpSemantics'] ?? 'unified-plan';

    try {
      MediaStream localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localMediaStreamLocallyGenerated = true;

      localStream.getTracks().forEach((MediaStreamTrack track) {
        if (track.kind == 'video') {
          _connection!.addTrack(track, localStream);
        }
        _localMediaStream?.addTrack(track);
      });

      emit(EventStream(
          session: this, originator: 'local', stream: _localMediaStream));
    } catch (error) {
      if (_status == C.STATUS_TERMINATED) {
        throw Exceptions.InvalidStateError('terminated');
      }
      request.reply(480);
      _failed(
          'local',
          null,
          null,
          null,
          480,
          DartSIP_C.CausesType.USER_DENIED_MEDIA_ACCESS,
          'User Denied Media Access');
      logger.e('emit "getusermediafailed" [error:${error.toString()}]');
      emit(EventGetUserMediaFailed(exception: error));
      throw Exceptions.InvalidStateError('getUserMedia() failed');
    }

    bool succeeded = false;

    extraHeaders.add('Contact: $_contact');
    extraHeaders.add('Content-Type: application/sdp');

    // Session Timers.
    if (_sessionTimers.running) {
      extraHeaders.add(
          'Session-Expires: ${_sessionTimers.currentExpires};refresher=${_sessionTimers.refresher ? 'uac' : 'uas'}');
    }

    void onFailed([dynamic response]) {
      eventHandlers.emit(EventCallFailed(session: this, response: response));
    }

    void onSucceeded(IncomingResponse? response) async {
      if (_status == C.STATUS_TERMINATED) {
        return;
      }

      sendRequest(SipMethod.ACK);

      // If it is a 2XX retransmission exit now.
      if (succeeded) {
        return;
      }

      // Handle Session Timers.
      _handleSessionTimersInIncomingResponse(response);

      // Must have SDP answer.
      if (response!.body == null || response.body!.isEmpty) {
        onFailed();
        return;
      } else if (response.getHeader('Content-Type') != 'application/sdp') {
        onFailed();
        return;
      }

      logger.d('emit "sdp"');
      emit(EventSdp(originator: 'remote', type: 'answer', sdp: response.body));

      RTCSessionDescription answer =
          RTCSessionDescription(response.body, 'answer');

      try {
        await _connection!.setRemoteDescription(answer);
        eventHandlers.emit(EventSucceeded(response: response));
      } catch (error) {
        onFailed();
        logger.e(
            'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
        emit(EventSetRemoteDescriptionFailed(exception: error));
      }
    }

    try {
      RTCSessionDescription desc =
          await _createLocalDescription('offer', rtcOfferConstraints);
      String? sdp = _mangleOffer(desc.sdp);
      logger.d('emit "sdp"');
      emit(EventSdp(originator: 'local', type: 'offer', sdp: sdp));

      EventManager handlers = EventManager();
      handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
        onSucceeded(event.response as IncomingResponse?);
        succeeded = true;
      });
      handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
        onFailed(event.response);
      });
      handlers.on(EventOnTransportError(), (EventOnTransportError event) {
        onTransportError(); // Do nothing because session ends.
      });
      handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
        logger.w(
            'video upgrade re-INVITE timed out (Timer B); leaving dialog up');
      });
      handlers.on(EventOnDialogError(), (EventOnDialogError event) {
        onDialogError(event.response);
      });

      sendRequest(SipMethod.INVITE, <String, dynamic>{
        'extraHeaders': extraHeaders,
        'body': sdp,
        'eventHandlers': handlers
      });
    } catch (e, s) {
      logger.e(e.toString(), error: e, stackTrace: s);
      onFailed();
    }
  }

  /**
   * Send UPDATE
   */
  void _sendUpdate([Map<String, dynamic>? options]) async {
    logger.d('sendUpdate()');

    options = options ?? <String, dynamic>{};

    List<dynamic> extraHeaders =
        utils.cloneArray(options['extraHeaders'] ?? <dynamic>[]);
    EventManager eventHandlers = options['eventHandlers'] ?? EventManager();
    Map<String, dynamic> rtcOfferConstraints = options['rtcOfferConstraints'] ??
        _rtcOfferConstraints ??
        <String, dynamic>{};
    bool sdpOffer = options['sdpOffer'] ?? false;

    bool succeeded = false;

    extraHeaders.add('Contact: $_contact');

    // Session Timers.
    if (_sessionTimers.running) {
      extraHeaders.add(
          'Session-Expires: ${_sessionTimers.currentExpires};refresher=${_sessionTimers.refresher ? 'uac' : 'uas'}');
    }

    void onFailed([dynamic response]) {
      eventHandlers.emit(EventCallFailed(session: this, response: response));
    }

    void onSucceeded(IncomingResponse? response) async {
      if (_status == C.STATUS_TERMINATED) {
        return;
      }

      // Handle Session Timers.
      _handleSessionTimersInIncomingResponse(response);

      // If it is a 2XX retransmission exit now.
      if (succeeded) {
        return;
      }

      // Must have SDP answer.
      if (sdpOffer) {
        if (response!.body != null && response.body!.trim().isNotEmpty) {
          onFailed();
          return;
        } else if (response.getHeader('Content-Type') != 'application/sdp') {
          onFailed();
          return;
        }

        logger.d('emit "sdp"');
        emit(
            EventSdp(originator: 'remote', type: 'answer', sdp: response.body));

        RTCSessionDescription answer =
            RTCSessionDescription(response.body, 'answer');

        try {
          await _connection!.setRemoteDescription(answer);
          eventHandlers.emit(EventSucceeded(response: response));
        } catch (error) {
          onFailed(error);
          logger.e(
              'emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
          emit(EventSetRemoteDescriptionFailed(exception: error));
        }
      }
      // No SDP answer.
      else {
        eventHandlers.emit(EventSucceeded(response: response));
      }
    }

    if (sdpOffer) {
      extraHeaders.add('Content-Type: application/sdp');
      try {
        RTCSessionDescription desc =
            await _createLocalDescription('offer', rtcOfferConstraints);
        String? sdp = _mangleOffer(desc.sdp);

        logger.d('emit "sdp"');
        emit(EventSdp(originator: 'local', type: 'offer', sdp: sdp));

        EventManager handlers = EventManager();
        handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
          onSucceeded(event.response as IncomingResponse?);
          succeeded = true;
        });
        handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
          onFailed(event.response);
        });
        handlers.on(EventOnTransportError(), (EventOnTransportError event) {
          onTransportError(); // Do nothing because session ends.
        });
        handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
          logger.w(
              'UPDATE (SDP) timed out (Timer B); leaving dialog up (media may be stale)');
        });
        handlers.on(EventOnDialogError(), (EventOnDialogError event) {
          onDialogError(event.response);
        });

        sendRequest(SipMethod.UPDATE, <String, dynamic>{
          'extraHeaders': extraHeaders,
          'body': sdp,
          'eventHandlers': handlers
        });
      } catch (error) {
        onFailed(error);
      }
    } else {
      // No SDP.

      EventManager handlers = EventManager();
      handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
        onSucceeded(event.response as IncomingResponse?);
      });
      handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
        onFailed(event.response);
      });
      handlers.on(EventOnTransportError(), (EventOnTransportError event) {
        onTransportError(); // Do nothing because session ends.
      });
      handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
        logger.w('UPDATE timed out (Timer B); leaving dialog up');
      });
      handlers.on(EventOnDialogError(), (EventOnDialogError event) {
        onDialogError(event.response);
      });

      sendRequest(SipMethod.UPDATE, <String, dynamic>{
        'extraHeaders': extraHeaders,
        'eventHandlers': handlers
      });
    }
  }

  void _acceptAndTerminate(IncomingResponse? response,
      [int? status_code, String? reason_phrase]) async {
    logger.d(
        'acceptAndTerminate() status_code: $status_code reason: $reason_phrase');

    List<dynamic> extraHeaders = <dynamic>[];

    if (status_code != null) {
      reason_phrase =
          reason_phrase ?? DartSIP_C.REASON_PHRASE[status_code] ?? '';
      extraHeaders
          .add('Reason: SIP ;cause=$status_code; text="$reason_phrase"');
    }

    // An error on dialog creation will fire 'failed' event.
    if (_dialog != null || _createDialog(response, 'UAC')) {
      sendRequest(SipMethod.ACK);
      sendRequest(
          SipMethod.BYE, <String, dynamic>{'extraHeaders': extraHeaders});
    }

    // Update session status.
    _status = C.STATUS_TERMINATED;
  }

  /**
   * Correctly set the SDP direction attributes if the call is on local hold
   */
  String? _mangleOffer(String? sdpInput) {
    if (!_localHold && !_remoteHold) {
      return sdpInput;
    }

    Map<String, dynamic> sdp = sdp_transform.parse(sdpInput!);

    // Local hold.
    if (_localHold && !_remoteHold) {
      logger.d('mangleOffer() | me on hold, mangling offer');
      for (Map<String, dynamic> m in sdp['media']) {
        if (holdMediaTypes.indexOf(m['type']) == -1) {
          continue;
        }
        if (m['direction'] == null) {
          m['direction'] = 'sendonly';
        } else if (m['direction'] == 'sendrecv') {
          m['direction'] = 'sendonly';
        } else if (m['direction'] == 'recvonly') {
          m['direction'] = 'inactive';
        }
      }
    }
    // Local and remote hold.
    else if (_localHold && _remoteHold) {
      logger.d('mangleOffer() | both on hold, mangling offer');
      for (Map<String, dynamic> m in sdp['media']) {
        if (holdMediaTypes.indexOf(m['type']) == -1) {
          continue;
        }
        m['direction'] = 'inactive';
      }
    }
    // Remote hold.
    else if (_remoteHold) {
      logger.d('mangleOffer() | remote on hold, mangling offer');
      for (Map<String, dynamic> m in sdp['media']) {
        if (holdMediaTypes.indexOf(m['type']) == -1) {
          continue;
        }
        if (m['direction'] == null) {
          m['direction'] = 'recvonly';
        } else if (m['direction'] == 'sendrecv') {
          m['direction'] = 'recvonly';
        } else if (m['direction'] == 'recvonly') {
          m['direction'] = 'inactive';
        }
      }
    }

    return sdp_transform.write(sdp, null);
  }

  /// True when SDP matches a WebRTC "ICE not gathered yet" template: no
  /// `a=candidate:` and audio is unusable (discard port 9, `0.0.0.0`).
  /// Never send even if [bypassReinviteSdpViability] is set.
  bool _isReinviteOfferSdpIcePoison(String? sdp) {
    if (sdp == null || sdp.trim().isEmpty || !sdp.contains('m=audio')) {
      return false;
    }
    if (sdp.contains('a=candidate:')) {
      return false;
    }
    try {
      final Map<String, dynamic> parsed = sdp_transform.parse(sdp);
      final dynamic sessConn = parsed['connection'];
      final String? sessionIp =
          sessConn is Map<String, dynamic> ? sessConn['ip'] as String? : null;
      for (final dynamic raw
          in (parsed['media'] as List<dynamic>? ?? <dynamic>[])) {
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final Map<String, dynamic> m = raw;
        if (m['type'] != 'audio') {
          continue;
        }
        final int port = m['port'] is int
            ? m['port'] as int
            : int.tryParse('${m['port']}') ?? 0;
        final dynamic mConn = m['connection'];
        final String? mediaIp =
            mConn is Map<String, dynamic> ? mConn['ip'] as String? : null;
        final String? ip = mediaIp ?? sessionIp;
        if (port <= 0 || port == 9) {
          return true;
        }
        if (ip == '0.0.0.0' || ip == '0:0:0:0:0:0:0:0') {
          return true;
        }
        return false;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// `m=audio 9`, `c=IN IP4 0.0.0.0` and no candidates. Sending those poisons the
  /// dialog (no usable media, PBX may stop answering on the same TCP association).
  bool _isReinviteOfferSdpViable(String? sdp) {
    if (sdp == null || sdp.trim().isEmpty) {
      return false;
    }
    if (!sdp.contains('m=audio')) {
      return false;
    }
    final bool hasCandidate = sdp.contains('a=candidate:');
    try {
      final Map<String, dynamic> parsed = sdp_transform.parse(sdp);
      final dynamic sessConn = parsed['connection'];
      final String? sessionIp =
          sessConn is Map<String, dynamic> ? sessConn['ip'] as String? : null;
      for (final dynamic raw
          in (parsed['media'] as List<dynamic>? ?? <dynamic>[])) {
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final Map<String, dynamic> m = raw;
        if (m['type'] != 'audio') {
          continue;
        }
        final int port = m['port'] is int
            ? m['port'] as int
            : int.tryParse('${m['port']}') ?? 0;
        final dynamic mConn = m['connection'];
        final String? mediaIp =
            mConn is Map<String, dynamic> ? mConn['ip'] as String? : null;
        final String? ip = mediaIp ?? sessionIp;
        if (port <= 0) {
          return false;
        }
        if (port == 9 && !hasCandidate) {
          return false;
        }
        if ((ip == '0.0.0.0' || ip == '0:0:0:0:0:0:0:0') && !hasCandidate) {
          return false;
        }
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// SDP offers may contain text media channels. e.g. Older clients using linphone.
  ///
  /// WebRTC does not support text media channels, so remove them.
  String? _sdpOfferToWebRTC(String? sdpInput) {
    if (sdpInput == null) {
      return sdpInput;
    }

    Map<String, dynamic> sdp = sdp_transform.parse(sdpInput);

    final List<Map<String, dynamic>> mediaList = <Map<String, dynamic>>[];

    for (dynamic element in sdp['media']) {
      if (element['type'] != 'text') {
        mediaList.add(element);
      }
    }
    sdp['media'] = mediaList;

    return sdp_transform.write(sdp, null);
  }

  /// FreeSWITCH (and other PBXs) often send legacy `RTP/AVP` without DTLS; WebRTC
  /// [setRemoteDescription] requires `UDP/TLS/RTP/SAVPF` and [a=fingerprint].
  /// Build a compatible offer using ICE/fingerprint lines from [createOffer] on
  /// the same [RTCPeerConnection] (after addTrack).
  Future<String?> _sdpOfferToWebRtcAsync(String? sdpInput) async {
    if (sdpInput == null) {
      return null;
    }
    final String trimmed = sdpInput.trim();
    final String lower = trimmed.toLowerCase();
    if (lower.contains('a=fingerprint:') &&
        lower.contains('udp/tls/rtp/savpf')) {
      return _sdpOfferToWebRTC(sdpInput);
    }
    if (_connection == null) {
      return _sdpOfferToWebRTC(sdpInput);
    }
    try {
      final RTCSessionDescription template =
          await _connection!.createOffer(<String, dynamic>{});
      final String? templateSdp = template.sdp;
      if (templateSdp == null || templateSdp.trim().isEmpty) {
        return _sdpOfferToWebRTC(sdpInput);
      }
      final String merged =
          _injectWebRtcSecurityIntoLegacyRtpOffer(sdpInput, templateSdp);
      logger.d(
          'SDP: interop — injected WebRTC DTLS/ICE into legacy RTP/AVP offer');
      // Only the initial incoming [answer] runs at STATUS_ANSWERED; in-dialog
      // re-INVITEs use STATUS_CONFIRMED and must not trigger this.
      if (_direction == 'incoming' && _status == C.STATUS_ANSWERED) {
        _needsPostAckMediaRenegotiation = true;
      }
      return _sdpOfferToWebRTC(merged);
    } catch (e, stackTrace) {
      logger.w('SDP: legacy→WebRTC merge failed ($e)\n$stackTrace');
      return _sdpOfferToWebRTC(sdpInput);
    }
  }

  /// ICE/DTLS lines from the first `m=audio` block of [localOfferSdp] only
  /// (avoids candidates / attributes from a second m= section, e.g. mid=1).
  List<String> _extractFirstAudioWebRtcShim(String localOfferSdp) {
    final List<String> lines =
        localOfferSdp.replaceAll('\r\n', '\n').split('\n');
    final List<String> out = <String>[];
    bool inFirstAudio = false;
    for (final String raw in lines) {
      final String t = raw.trim();
      if (t.startsWith('m=')) {
        if (inFirstAudio) {
          break;
        }
        if (t.startsWith('m=audio')) {
          inFirstAudio = true;
        }
        continue;
      }
      if (!inFirstAudio) {
        continue;
      }
      if (t.startsWith('a=ice-ufrag:') ||
          t.startsWith('a=ice-pwd:') ||
          t.startsWith('a=fingerprint:') ||
          t.startsWith('a=setup:') ||
          t.startsWith('a=candidate:') ||
          t.startsWith('a=ice-options:')) {
        out.add(t);
      }
    }
    return out;
  }

  /// FS often puts `c=` at **session** level; legacy RTP/AVP has no `c=` under
  /// `m=audio`. Inject `a=mid`, `a=rtcp-mux`, and shim immediately after the
  /// first `m=audio` line so WebRTC does not synthesize a broken mid=1 section.
  String _injectWebRtcSecurityIntoLegacyRtpOffer(
    String remoteSdp,
    String localOfferSdp,
  ) {
    final String rem = remoteSdp.replaceAll('\r\n', '\n');
    final List<String> shim = _extractFirstAudioWebRtcShim(localOfferSdp);

    final List<String> out = <String>[];
    bool injectedFirstAudio = false;

    for (String line in rem.split('\n')) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add('');
        continue;
      }
      if (trimmed.startsWith('m=audio') && !injectedFirstAudio) {
        out.add(trimmed.replaceFirst(' RTP/AVP ', ' UDP/TLS/RTP/SAVPF '));
        out.add('a=mid:0');
        out.add('a=rtcp-mux');
        out.addAll(shim);
        injectedFirstAudio = true;
        continue;
      }
      out.add(trimmed);
    }

    if (!injectedFirstAudio && shim.isNotEmpty) {
      logger.w('SDP inject: no m=audio in remote offer');
    }

    return out.join('\r\n');
  }

  void _setLocalMediaStatus() {
    bool enableAudio = true, enableVideo = true;

    if (_localHold || _remoteHold) {
      enableAudio = false;
      enableVideo = false;
    }

    if (_audioMuted) {
      enableAudio = false;
    }

    if (_videoMuted) {
      enableVideo = false;
    }

    _toggleMuteAudio(!enableAudio);
    _toggleMuteVideo(!enableVideo);
  }

  /**
   * Handle SessionTimers for an incoming INVITE or UPDATE.
   * @param  {IncomingRequest} request
   * @param  {Array} responseExtraHeaders  Extra headers for the 200 response.
   */
  void _handleSessionTimersInIncomingRequest(
      IncomingRequest request, List<dynamic> responseExtraHeaders) {
    if (!_sessionTimers.enabled) {
      return;
    }

    String session_expires_refresher;

    if (request.session_expires != null &&
        request.session_expires! > 0 &&
        request.session_expires! >= DartSIP_C.MIN_SESSION_EXPIRES) {
      _sessionTimers.currentExpires = request.session_expires;
      session_expires_refresher = request.session_expires_refresher ?? 'uas';
    } else {
      _sessionTimers.currentExpires = _sessionTimers.defaultExpires;
      session_expires_refresher = 'uas';
    }

    responseExtraHeaders.add(
        'Session-Expires: ${_sessionTimers.currentExpires};refresher=$session_expires_refresher');

    _sessionTimers.refresher = session_expires_refresher == 'uas';
    _runSessionTimer();
  }

  /**
   * Handle SessionTimers for an incoming response to INVITE or UPDATE.
   * @param  {IncomingResponse} response
   */
  void _handleSessionTimersInIncomingResponse(dynamic response) {
    if (!_sessionTimers.enabled) {
      return;
    }

    String session_expires_refresher;

    if (response.session_expires != null &&
        response.session_expires != 0 &&
        response.session_expires >= DartSIP_C.MIN_SESSION_EXPIRES) {
      _sessionTimers.currentExpires = response.session_expires;
      session_expires_refresher = response.session_expires_refresher ?? 'uac';
    } else {
      _sessionTimers.currentExpires = _sessionTimers.defaultExpires;
      session_expires_refresher = 'uac';
    }

    _sessionTimers.refresher = session_expires_refresher == 'uac';
    _runSessionTimer();
  }

  void _runSessionTimer() {
    int? expires = _sessionTimers.currentExpires;

    _sessionTimers.running = true;

    clearTimeout(_sessionTimers.timer);

    // I'm the refresher.
    if (_sessionTimers.refresher) {
      _sessionTimers.timer = setTimeout(() {
        if (_status == C.STATUS_TERMINATED) {
          return;
        }

        logger.d('runSessionTimer() | sending session refresh request');

        if (_sessionTimers.refreshMethod == SipMethod.UPDATE) {
          _sendUpdate();
        } else {
          _sendReinvite();
        }
      }, expires! * 500); // Half the given interval (as the RFC states).
    }
    // I'm not the refresher.
    else {
      _sessionTimers.timer = setTimeout(() {
        if (_status == C.STATUS_TERMINATED) {
          return;
        }

        logger.e('runSessionTimer() | timer expired, terminating the session');

        terminate(<String, dynamic>{
          'cause': DartSIP_C.CausesType.REQUEST_TIMEOUT,
          'status_code': 408,
          'reason_phrase': 'Session Timer Expired'
        });
      }, expires! * 1100);
    }
  }

  void _toggleMuteAudio(bool mute) {
    if (_localMediaStream != null) {
      for (MediaStreamTrack track in _localMediaStream!.getAudioTracks()) {
        track.enabled = !mute;
      }
    }
  }

  void _toggleMuteVideo(bool mute) {
    if (_localMediaStream != null) {
      for (MediaStreamTrack track in _localMediaStream!.getVideoTracks()) {
        track.enabled = !mute;
      }
    }
  }

  void _newRTCSession(String originator, dynamic request) {
    logger.d('newRTCSession()');
    _ua.newRTCSession(originator: originator, session: this, request: request);
  }

  void _connecting(dynamic request) {
    logger.d('session connecting');
    logger.d('emit "connecting"');
    emit(EventCallConnecting(session: this, request: request));
  }

  void _progress(String originator, dynamic response, [int? status_code]) {
    logger.d('session progress');
    logger.d('emit "progress"');

    ErrorCause errorCause = ErrorCause(status_code: status_code);

    emit(EventCallProgress(
        session: this,
        originator: originator,
        response: response,
        cause: errorCause));
  }

  void _accepted(String originator, [dynamic message]) {
    logger.d('session accepted');
    _start_time = DateTime.now();
    logger.d('emit "accepted"');
    emit(EventCallAccepted(
        session: this, originator: originator, response: message));
  }

  void _confirmed(String originator, dynamic ack) {
    logger.d('session confirmed');
    _is_confirmed = true;
    logger.d('emit "confirmed"');
    emit(EventCallConfirmed(session: this, originator: originator, ack: ack));

    if (_needsPostAckMediaRenegotiation) {
      _needsPostAckMediaRenegotiation = false;
      if (_ua.activeSessionCount > 1) {
        logger.d(
            'SDP: skip post-ACK re-INVITE while multiple sessions active (transfer / second line)');
      } else {
        logger.d(
            'SDP: post-ACK re-INVITE after legacy-offer WebRTC shim (sync media with peer)');
        scheduleMicrotask(() {
          if (_status == C.STATUS_TERMINATED || _connection == null) {
            return;
          }
          if (_ua.activeSessionCount > 1) {
            return;
          }
          try {
            _sendReinvite();
          } catch (e, s) {
            logger.w('post-ACK re-INVITE failed: $e\n$s');
          }
        });
      }
    }
  }

  void _ended(String originator, IncomingRequest? request, ErrorCause cause) {
    logger.d('session ended');
    if (_sessionTerminationNotified) {
      logger.d('session ended (duplicate ignored)');
      unawaited(_close());
      return;
    }
    _sessionTerminationNotified = true;
    _end_time = DateTime.now();
    // Emit ENDED only after native PC/stream teardown completes so app code
    // (track stop, renderers, ringback) does not race flutter_webrtc dispose.
    _close().whenComplete(() {
      logger.d('emit "ended"');
      emit(EventCallEnded(
          session: this,
          originator: originator,
          request: request,
          cause: cause));
    });
  }

  void _failed(String originator, dynamic message, dynamic request,
      dynamic response, int? status_code, String cause, String? reason_phrase) {
    logger.d('session failed');

    // Emit private '_failed' event first.
    logger.d('emit "_failed"');

    ErrorCause errorCause = ErrorCause(
        cause: cause, status_code: status_code, reason_phrase: reason_phrase);

    emit(EventFailedUnderScore(
      originator: originator,
      cause: errorCause,
    ));

    if (_sessionTerminationNotified) {
      logger.d(
          'session failed (cleanup only: public termination already notified)');
      unawaited(_close());
      return;
    }
    _sessionTerminationNotified = true;

    _close().whenComplete(() {
      logger.d('emit "failed"');
      emit(EventCallFailed(
          session: this,
          originator: originator,
          request: request,
          cause: errorCause,
          response: response));
    });
  }

  void _onhold(String originator) {
    logger.d('session onhold');
    _setLocalMediaStatus();
    logger.d('emit "hold"');
    emit(EventCallHold(session: this, originator: originator));
  }

  void _onunhold(String originator) {
    logger.d('session onunhold');
    _setLocalMediaStatus();
    logger.d('emit "unhold"');
    emit(EventCallUnhold(session: this, originator: originator));
  }

  void _onmute([bool? audio, bool? video]) {
    logger.d('session onmute');
    _setLocalMediaStatus();
    logger.d('emit "muted"');
    emit(EventCallMuted(session: this, audio: audio, video: video));
  }

  void _onunmute([bool? audio, bool? video]) {
    logger.d('session onunmute');
    _setLocalMediaStatus();
    logger.d('emit "unmuted"');
    emit(EventCallUnmuted(session: this, audio: audio, video: video));
  }
}
