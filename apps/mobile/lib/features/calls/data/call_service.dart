import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/api_client.dart';
import '../../messages/data/messenger.dart';
import 'ringer.dart';
import 'ringtone.dart';

enum CallPhase { outgoing, incoming, connecting, connected, ended }

/// One call (boards 32-35).
class Call {
  Call({required this.id, required this.peer, required this.video, required this.outgoing, required this.phase});
  final String id;
  final String peer;
  final bool video; // started as a video call
  final bool outgoing;
  CallPhase phase;
  DateTime? connectedAt;
  bool muted = false;
  bool speaker = false;
  bool cameraOn = false;
  bool sharing = false;
  bool remoteVideo = false; // they are sending camera or screen
  bool remoteSharing = false;
  bool weak = false; // the connection is struggling
  bool native = false; // ringing on the phone's own call screen (board 48)
  String? endReason;

  Duration get elapsed => connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);
}

/// Calls (Phase 10, decisions.md 2026-09-25).
///
/// Setup travels as ordinary Signal-encrypted messages through Messenger
/// ({"type":"call"}: offer, answer, taken, decline, busy, hangup), so the
/// server learns nothing about a call. Each side's SDP carries its DTLS
/// fingerprint; because the SDP arrives inside a message only that contact's
/// device could have encrypted, the media is bound to the verified identity:
/// the relay (or anyone else) cannot sit in the middle. The media itself is
/// DTLS-SRTP, end to end.
///
/// Relay only (owner decision): iceTransportPolicy "relay", so the peers
/// never learn each other's IP address. Candidates are gathered before an
/// offer or answer is sent (no trickle), so setup is exactly two messages.
///
/// In-call state (camera on, sharing, muted) goes over a WebRTC data channel,
/// also end to end, never through the server.
class CallService extends ChangeNotifier {
  CallService({
    required this.messenger,
    required this.api,
    this.captureMedia = true,
    this.ringFor = const Duration(seconds: 45),
    Ringtone? ringtone,
    bool Function()? ringsNatively,
  })  : ringtone = ringtone ?? Ringtone(),
        ringsNatively = ringsNatively ?? (() => false) {
    messenger.onCall = _onSignal;
  }

  /// Sound and vibration while a call rings on the app's own screen.
  final Ringtone ringtone;

  /// Board 48: whether a call that arrives while the app is open rings on
  /// the phone's own call screen ("Like a phone call") instead of ours.
  final bool Function() ringsNatively;

  final Messenger messenger;
  final ApiClient api;

  /// Tests run calls without camera or microphone (a data channel only).
  final bool captureMedia;

  /// How long a call rings before it counts as unanswered.
  final Duration ringFor;
  static const _staleOffer = Duration(seconds: 50);

  /// Whether an offer the server has held for [age] may still ring. Judged by
  /// the server's clock (inbox ageMs), never the caller's.
  static bool ringsAfter(Duration age) => age <= _staleOffer;

  /// How the end of a call is written in the chat (board 35), from how it
  /// ended here and which side we were on.
  static String recordedOutcome(String outcome, {required bool outgoing, required bool connected}) =>
      switch (outcome) {
        'completed' => 'completed',
        'noAnswer' || 'cancelled' => outgoing ? 'noAnswer' : 'missed',
        'declined' => 'declined',
        'busy' => 'busy',
        'missed' => 'missed',
        _ => connected ? 'completed' : (outgoing ? 'noAnswer' : 'missed'),
      };
  static const _gatherFor = Duration(seconds: 5);

  /// Once the first relay route is found, how long to wait for the others
  /// (TCP, IPv6) before sending. Waiting for all of them could take the full
  /// [_gatherFor] (Phase 14a: answering took seconds).
  static const _gatherGrace = Duration(milliseconds: 300);
  static const _uuid = Uuid();
  static const _shareService = MethodChannel('skyline/screen_share');

  Call? current;
  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  /// Relay credentials fetched while an incoming call rings, so Accept does
  /// not wait for the server (Phase 14a). Never the microphone: that only
  /// opens on Accept.
  Future<Object?>? _turnSoon;

  /// Set when the person tapped Accept on the phone's own ringing screen
  /// (Phase 14c): the offer, once fetched and decrypted, is answered at once.
  DateTime? _acceptUntil;

  /// Accept the next incoming call if it arrives soon. The offer is normally
  /// fetched within a second or two of the app opening; a short window means
  /// a different, later call is never answered by mistake.
  void acceptWhenRinging() {
    _acceptUntil = DateTime.now().add(const Duration(seconds: 20));
    final call = current;
    if (call != null && !call.outgoing && call.phase == CallPhase.incoming) {
      _acceptUntil = null;
      unawaited(accept());
    }
  }

  RTCPeerConnection? _pc;
  RTCDataChannel? _control;
  MediaStream? _local;
  MediaStreamTrack? _camera;
  MediaStreamTrack? _screen;
  // The video channel is looked up from the connection each time it is
  // needed (_videoChannel), never kept: on Android the plugin disposes the
  // objects it handed out once the call is negotiated, and a kept one
  // silently stops working.
  bool _hasVideo = false;
  String? _pendingOffer; // incoming, until accepted
  int? _offerDevice; // the caller's device that sent the offer
  int? _answerDevice; // the callee's device that answered
  Timer? _ringTimer;
  Timer? _tick;
  bool _ending = false;

  /// Test hook: how the connection was made (e.g. "relay").
  String? lastCandidateType;

  /// Test hook: the last probe that came over the data channel.
  String? lastProbe;

  // ------------------------------------------------------------ starting

  Future<void> start(String peer, {required bool video}) async {
    if (current != null) return;
    final call = Call(id: _uuid.v4(), peer: peer, video: video, outgoing: true, phase: CallPhase.outgoing);
    current = call;
    notifyListeners();
    try {
      await _open(call, offering: true);
      if (video) await _setCamera(true);
      _control = await _pc!.createDataChannel('skyline-call', RTCDataChannelInit()..ordered = true);
      _wireControl(_control!);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      final sdp = await _gathered();
      await messenger.sendCallSignal(peer, {
        'callId': call.id,
        'action': 'offer',
        'sdp': sdp,
        'video': video,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      });
      _ringTimer = Timer(ringFor, () => _end(call, 'noAnswer', notify: true));
    } on Object {
      await _end(call, 'failed', notify: false);
    }
  }

  Future<void> accept() async {
    final call = current;
    final offer = _pendingOffer;
    if (call == null || call.outgoing || call.phase != CallPhase.incoming || offer == null) return;
    call.phase = CallPhase.connecting;
    _ringTimer?.cancel();
    unawaited(ringtone.stop());
    if (call.native) {
      // Answered on the phone's screen: ours takes over from here.
      call.native = false;
      unawaited(NativeRinging.stopAll());
    }
    notifyListeners();
    try {
      await _open(call, offering: false);
      await _pc!.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      await _adoptVideo();
      if (call.video) await _setCamera(true);
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      final sdp = await _gathered();
      await messenger.sendCallSignal(call.peer, {
        'callId': call.id,
        'action': 'answer',
        'sdp': sdp,
        'to': _offerDevice,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on Object {
      await _end(call, 'failed', notify: true);
    }
  }

  Future<void> decline() async {
    final call = current;
    if (call == null || call.phase != CallPhase.incoming) return;
    unawaited(_signal(call, 'decline'));
    await _finish(call, 'declined');
  }

  Future<void> hangUp() async {
    final call = current;
    if (call == null) return;
    await _end(call, call.phase == CallPhase.connected ? 'completed' : (call.outgoing ? 'cancelled' : 'declined'),
        notify: true);
  }

  // ------------------------------------------------------------ controls

  void toggleMute() {
    final call = current;
    if (call == null) return;
    call.muted = !call.muted;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !call.muted;
    }
    _sendState();
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    final call = current;
    if (call == null) return;
    call.speaker = !call.speaker;
    if (Platform.isAndroid || Platform.isIOS) await Helper.setSpeakerphoneOn(call.speaker);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final call = current;
    if (call == null) return;
    await _setCamera(!call.cameraOn);
    notifyListeners();
  }

  Future<void> flipCamera() async {
    if (_camera != null) await Helper.switchCamera(_camera!);
  }

  /// Screen sharing (Windows and Android). Replaces the camera on the same
  /// video sender, so no renegotiation is needed; stopping brings the camera
  /// back if it was on.
  Future<void> toggleShare() async {
    final call = current;
    if (call == null || !_hasVideo) return;
    if (call.sharing) {
      await _stopShare();
    } else {
      try {
        MediaStream screen;
        if (Platform.isWindows) {
          final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
          if (sources.isEmpty) return;
          screen = await navigator.mediaDevices.getDisplayMedia({
            'video': {
              'deviceId': {'exact': sources.first.id},
              'mandatory': {'frameRate': 15.0},
            },
            'audio': false,
          });
        } else {
          // Android: the system prompt first, then the foreground service
          // (Android 14 allows it only after consent), then the capture.
          if (!await Helper.requestCapturePermission()) return;
          await _shareService.invokeMethod<bool>('start');
          try {
            screen = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
          } on Object {
            await _shareService.invokeMethod<bool>('stop');
            rethrow;
          }
        }
        _screen = screen.getVideoTracks().first;
        _screen!.onEnded = () => unawaited(_stopShare());
        await (await _videoChannel())?.sender.replaceTrack(_screen);
        call.sharing = true;
        _sendState();
      } on Object {
        // The person cancelled the system prompt, or sharing is unavailable.
      }
    }
    notifyListeners();
  }

  Future<void> _stopShare() async {
    final call = current;
    await _screen?.stop();
    _screen = null;
    if (Platform.isAndroid) await _shareService.invokeMethod<bool>('stop');
    await (await _videoChannel())?.sender.replaceTrack(call?.cameraOn == true ? _camera : null);
    if (call != null) {
      call.sharing = false;
      _sendState();
    }
    notifyListeners();
  }

  Future<void> _setCamera(bool on) async {
    final call = current;
    if (call == null || _pc == null) return;
    if (on && captureMedia) {
      if (_camera == null) {
        final cam = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {'facingMode': 'user', 'width': 640, 'height': 480, 'frameRate': 24},
        });
        _camera = cam.getVideoTracks().first;
        localRenderer.srcObject = cam;
      }
      _camera!.enabled = true;
      if (!call.sharing) await (await _videoChannel())?.sender.replaceTrack(_camera);
    } else if (_camera != null) {
      _camera!.enabled = false;
      if (!call.sharing) await (await _videoChannel())?.sender.replaceTrack(null);
    }
    call.cameraOn = on && captureMedia;
    _sendState();
  }

  // ---------------------------------------------------------- plumbing

  Future<void>? _renderersInit;

  /// Once, shared: ringing starts it and Accept waits for the same one.
  Future<void> _initRenderers() => _renderersInit ??= () async {
        await localRenderer.initialize();
        await remoteRenderer.initialize();
        _renderersReady = true;
      }();

  Future<void> _open(Call call, {required bool offering}) async {
    await _initRenderers();
    final early = _turnSoon == null ? null : await _turnSoon;
    _turnSoon = null;
    final turn = (early ?? await api.get('/calls/turn')) as Map<String, Object?>;
    final urls = [for (final u in turn['urls']! as List<Object?>) _forThisDevice(u! as String)];
    _pc = await createPeerConnection({
      // One entry per address: the Windows plugin keeps only the last of a
      // "urls" list.
      'iceServers': [
        for (final u in urls) {'urls': u, 'username': turn['username'], 'credential': turn['credential']},
      ],
      // Owner decision: always through our relay, never a direct connection.
      'iceTransportPolicy': 'relay',
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
    });
    _pc!.onConnectionState = (s) => _onConnection(call, s);
    _pc!.onTrack = (e) {
      // Both sides send audio and video in one stream (see _adoptVideo), so
      // the renderer gets it whole.
      if (e.streams.isNotEmpty) remoteRenderer.srcObject = e.streams.first;
    };
    _pc!.onDataChannel = (ch) {
      _control = ch;
      _wireControl(ch);
    };
    _local = captureMedia
        ? await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false})
        : await createLocalMediaStream('skyline-call');
    for (final t in _local!.getAudioTracks()) {
      await _pc!.addTrack(t, _local!);
    }
    // A video channel from the start, empty until the camera or a screen
    // share is switched on: turning video on later needs no renegotiation.
    // Only the caller creates it; the answerer takes over the one in the
    // offer (_adoptVideo). A transceiver made here by the answerer would
    // not be matched to the offer and would never send.
    if (offering) {
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [_local!]),
      );
      _hasVideo = true;
    }
  }

  /// Answerer: after reading the offer, send on its video channel too, in
  /// the same stream as our audio.
  Future<void> _adoptVideo() async {
    final t = await _videoChannel();
    if (t == null) return;
    await t.setDirection(TransceiverDirection.SendRecv);
    await t.sender.setStreams([_local!]);
    _hasVideo = true;
  }

  /// The call's one video channel, fetched fresh from the connection.
  Future<RTCRtpTransceiver?> _videoChannel() async {
    final pc = _pc;
    if (pc == null) return null;
    for (final t in await pc.getTransceivers()) {
      if (t.receiver.track?.kind == 'video') return t;
    }
    return null;
  }

  /// Test hook: video bytes this side sent, and video frames it decoded.
  Future<String> debugVideoStats() async {
    var sent = 0;
    var decoded = 0;
    final extra = <String>[];
    for (final r in await _pc!.getStats()) {
      final v = r.values;
      if (v['kind'] != 'video' && v['mediaType'] != 'video') continue;
      if (r.type == 'outbound-rtp') {
        sent += (v['bytesSent'] as num? ?? 0).toInt();
        extra.add('out(encoded=${v['framesEncoded']} fps=${v['framesPerSecond']} ${v['frameWidth']}x${v['frameHeight']} '
            'limit=${v['qualityLimitationReason']} encoder=${v['encoderImplementation']} codec=${v['codecId']})');
      }
      if (r.type == 'inbound-rtp') {
        decoded += (v['framesDecoded'] as num? ?? 0).toInt();
        extra.add('in(received=${v['framesReceived']} dropped=${v['framesDropped']} lost=${v['packetsLost']} '
            'nack=${v['nackCount']} pli=${v['pliCount']} decoder=${v['decoderImplementation']})');
      }
    }
    return 'sentBytes=$sent framesDecoded=$decoded ${extra.join(' ')}';
  }

  /// Test hook: the ICE candidate pairs and how this side reaches the relay.
  Future<String> debugIce() async {
    final out = <String>[];
    final reports = await _pc!.getStats();
    final byId = {for (final r in reports) r.id: r};
    for (final r in reports) {
      if (r.type != 'candidate-pair') continue;
      final v = r.values;
      final local = byId[v['localCandidateId']]?.values ?? const {};
      out.add('pair(${v['state']} nominated=${v['nominated']} sent=${v['bytesSent']} recv=${v['bytesReceived']} '
          'local=${local['candidateType']}/${local['protocol']}/relay=${local['relayProtocol']})');
    }
    for (final r in reports) {
      if (r.type == 'transport') out.add('transport(dtls=${r.values['dtlsState']} ice=${r.values['iceState']})');
    }
    return out.join(' ');
  }

  /// Test hook: the negotiated direction of the video channel ("sendrecv"
  /// when both sides can turn their camera or a screen share on).
  Future<TransceiverDirection?> videoDirection() async => (await _videoChannel())?.getCurrentDirection();

  /// The server lists the relay as "localhost" in development; a phone or an
  /// emulator reaches it at the same host it reaches the server on.
  String _forThisDevice(String url) {
    final host = api.base.host;
    if (host == 'localhost' || host == '127.0.0.1') return url;
    return url.replaceFirst(RegExp(r'(turns?:)(localhost|127\.0\.0\.1)'), '\$1$host');
  }

  /// Waits for relay candidates, then returns the SDP with them. It sends as
  /// soon as gathering completes, or [_gatherGrace] after the first relay
  /// route appears, whichever is first; at most [_gatherFor].
  Future<String> _gathered() async {
    final done = Completer<void>();
    Timer? grace;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _pc!.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) finish();
    };
    _pc!.onIceCandidate = (c) {
      if ((c.candidate ?? '').contains(' typ relay')) grace ??= Timer(_gatherGrace, finish);
    };
    if (_pc!.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) finish();
    await done.future.timeout(_gatherFor, onTimeout: () {});
    grace?.cancel();
    final desc = await _pc!.getLocalDescription();
    return desc!.sdp!;
  }

  void _onConnection(Call call, RTCPeerConnectionState s) {
    if (current != call) return;
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        call.weak = false;
        if (call.phase != CallPhase.connected) {
          call.phase = CallPhase.connected;
          call.connectedAt = DateTime.now();
          _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
          _sendState();
          unawaited(_readCandidateType());
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        call.weak = true; // WebRTC keeps trying; tell the person
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        unawaited(_end(call, call.connectedAt == null ? 'failed' : 'completed', notify: true));
      default:
        break;
    }
    notifyListeners();
  }

  Future<void> _readCandidateType() async {
    try {
      for (final r in await _pc!.getStats()) {
        if (r.type == 'local-candidate' && r.values['candidateType'] != null) {
          lastCandidateType = r.values['candidateType'] as String?;
        }
      }
    } on Object {
      // stats are best effort
    }
  }

  void _wireControl(RTCDataChannel ch) {
    ch.onMessage = (m) {
      final call = current;
      if (call == null) return;
      try {
        final j = jsonDecode(m.text) as Map<String, Object?>;
        if (j['probe'] is String) {
          lastProbe = j['probe'] as String;
          return;
        }
        call.remoteVideo = j['video'] == true || j['sharing'] == true;
        call.remoteSharing = j['sharing'] == true;
        notifyListeners();
      } on Object {
        // ignore
      }
    };
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) _sendState();
    };
  }

  void _sendState() {
    final call = current;
    final ch = _control;
    if (call == null || ch == null || ch.state != RTCDataChannelState.RTCDataChannelOpen) return;
    unawaited(ch.send(RTCDataChannelMessage(jsonEncode({
      'video': call.cameraOn,
      'sharing': call.sharing,
      'muted': call.muted,
    }))));
  }

  /// Test hook: a message over the call's own encrypted data channel.
  Future<void> sendProbe(String text) async => _control?.send(RTCDataChannelMessage(jsonEncode({'probe': text})));

  Future<void> _signal(Call call, String action, [Map<String, Object?> extra = const {}]) async {
    try {
      await messenger.sendCallSignal(call.peer, {
        'callId': call.id,
        'action': action,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
        ...extra,
      });
    } on Object {
      // Offline: the other side times out by itself.
    }
  }

  /// Ends the call here and (when [notify]) tells the other side.
  Future<void> _end(Call call, String outcome, {required bool notify}) async {
    if (_ending || current != call) return;
    if (notify) unawaited(_signal(call, 'hangup'));
    await _finish(call, outcome);
  }

  Future<void> _finish(Call call, String outcome) async {
    if (_ending || current != call) return;
    _ending = true;
    try {
      _ringTimer?.cancel();
      _tick?.cancel();
      unawaited(ringtone.stop());
      final seconds = call.elapsed.inSeconds;
      call
        ..phase = CallPhase.ended
        ..endReason = outcome;
      notifyListeners();
      if (_screen != null) {
        await _screen!.stop();
        if (Platform.isAndroid) await _shareService.invokeMethod<bool>('stop').catchError((Object _) => null);
      }
      for (final t in [...?_local?.getTracks(), if (_camera != null) _camera!]) {
        await t.stop();
      }
      await _local?.dispose();
      await _control?.close();
      await _pc?.close();
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      _pc = null;
      _control = null;
      _local = null;
      _camera = null;
      _screen = null;
      _hasVideo = false;
      _pendingOffer = null;
      _turnSoon = null;
      unawaited(NativeRinging.stopAll());
      _offerDevice = null;
      _answerDevice = null;
      final record = recordedOutcome(outcome, outgoing: call.outgoing, connected: call.connectedAt != null);
      if (outcome != 'elsewhere') {
        await messenger.recordCall(call.peer,
            video: call.video, outgoing: call.outgoing, outcome: record, durationSeconds: seconds);
      }
      // The ended screen shows for a moment, then the call is gone.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    } finally {
      if (current == call) current = null;
      _ending = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ signals

  /// A call-setup message, already decrypted and checked by Messenger (one
  /// to one, from a linked contact or from one of our own devices).
  Future<void> _onSignal(String sender, int device, String peer, Map<String, Object?> content) async {
    final callId = content['callId'];
    final action = content['action'];
    if (callId is! String || action is! String) return;
    final fromMe = sender == messenger.me;
    final call = current;

    switch (action) {
      case 'offer':
        if (fromMe) return; // our own call, placed from another of our devices
        final video = content['video'] == true;
        // Its age by the server's clock (never the caller's: phone clocks
        // drift, and a behind clock made every call look missed).
        final age = content['ageMs'] is int ? Duration(milliseconds: content['ageMs']! as int) : Duration.zero;
        final at = DateTime.now().subtract(age); // when it was sent, by our clock
        if (!ringsAfter(age)) {
          // It rang while this device was away: a missed call.
          await messenger.recordCall(peer, video: video, outgoing: false, outcome: 'missed', at: at);
          return;
        }
        if (call != null) {
          // Already on a call: busy, and a missed call here.
          await messenger.sendCallSignal(peer, {'callId': callId, 'action': 'busy', 'sentAt': DateTime.now().millisecondsSinceEpoch})
              .catchError((Object _) {});
          await messenger.recordCall(peer, video: video, outgoing: false, outcome: 'missed', at: at);
          return;
        }
        final sdp = content['sdp'];
        if (sdp is! String) return;
        final incoming = Call(id: callId, peer: peer, video: video, outgoing: false, phase: CallPhase.incoming);
        current = incoming;
        _pendingOffer = sdp;
        _offerDevice = device;
        _ringTimer = Timer(ringFor, () => _finish(incoming, 'missed'));
        // While it rings: what Accept would otherwise wait for.
        _turnSoon = api.get('/calls/turn').then<Object?>((v) => v, onError: (Object _) => null);
        unawaited(_initRenderers());
        notifyListeners();
        final until = _acceptUntil;
        _acceptUntil = null;
        if (until != null && DateTime.now().isBefore(until)) {
          // Already answered on the phone's ringing screen.
          unawaited(accept());
          unawaited(NativeRinging.stopAll());
        } else if (nativeRingingSupported && ringsNatively()) {
          // "Like a phone call": the phone rings it, our screen stays out of
          // the way until it is answered.
          incoming.native = true;
          notifyListeners();
          unawaited(ringInApp(
              callId: callId, name: messenger.contact(peer)?.displayName ?? 'Skyline call', video: video));
        } else {
          unawaited(ringtone.start());
          // The app's own screen has it now: stop the phone's ringing.
          unawaited(NativeRinging.stopAll());
        }

      case 'answer':
        if (call == null || call.id != callId) return;
        if (fromMe) {
          // We answered on another of our devices: stop ringing here.
          if (!call.outgoing && call.phase == CallPhase.incoming) await _finish(call, 'elsewhere');
          return;
        }
        if (!call.outgoing || call.phase != CallPhase.outgoing || _pc == null) return;
        final sdp = content['sdp'];
        if (sdp is! String) return;
        _answerDevice = device;
        _ringTimer?.cancel();
        call.phase = CallPhase.connecting;
        notifyListeners();
        await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        // The contact's other devices stop ringing.
        unawaited(_signal(call, 'taken', {'device': device}));

      case 'taken':
        // Answered by another of the callee's devices (or ours): if this
        // device was still ringing for it, stop.
        if (call != null && call.id == callId && !call.outgoing && call.phase == CallPhase.incoming) {
          await _finish(call, 'elsewhere');
        }

      case 'decline':
        if (call != null && call.id == callId && call.outgoing && !fromMe) await _finish(call, 'declined');
        if (call != null && call.id == callId && !call.outgoing && fromMe) await _finish(call, 'elsewhere');

      case 'busy':
        if (call != null && call.id == callId && call.outgoing) await _finish(call, 'busy');

      case 'hangup':
        if (call == null || call.id != callId) {
          return;
        }
        // Only the device on the other end of THIS call can hang it up.
        if (call.outgoing && _answerDevice != null && device != _answerDevice && !fromMe) return;
        if (!call.outgoing && _offerDevice != null && device != _offerDevice) return;
        await _finish(call, call.phase == CallPhase.connected ? 'completed' : (call.outgoing ? 'noAnswer' : 'missed'));
    }
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ringTimer?.cancel();
    unawaited(ringtone.dispose());
    _tick?.cancel();
    unawaited(_pc?.close());
    if (_renderersReady) {
      unawaited(localRenderer.dispose());
      unawaited(remoteRenderer.dispose());
    }
    super.dispose();
  }
}
