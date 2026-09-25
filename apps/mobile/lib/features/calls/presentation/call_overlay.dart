import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../data/call_service.dart';

/// Boards 32-35: a call sits above the whole app. Full screen while it rings
/// or runs; minimised, a green bar at the top takes you back.
class CallOverlay extends StatefulWidget {
  const CallOverlay({super.key, required this.calls, required this.child});
  final CallService? calls;
  final Widget child;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  bool _minimised = false;
  String? _callId;

  @override
  Widget build(BuildContext context) {
    final calls = widget.calls;
    if (calls == null) return widget.child;
    return ListenableBuilder(
      listenable: calls,
      builder: (context, _) {
        final call = calls.current;
        if (call?.id != _callId) {
          _callId = call?.id;
          _minimised = false; // every new call opens full screen
        }
        if (call == null) return widget.child;
        final name = calls.messenger.contact(call.peer)?.displayName ?? 'Contact';
        final full = !_minimised || call.phase == CallPhase.incoming || call.phase == CallPhase.ended;
        return Stack(children: [
          Positioned.fill(child: widget.child),
          if (full)
            Positioned.fill(
              child: _CallView(
                calls: calls,
                call: call,
                name: name,
                onMinimise: () => setState(() => _minimised = true),
              ),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _ReturnBar(call: call, name: name, onTap: () => setState(() => _minimised = false)),
            ),
        ]);
      },
    );
  }
}

/// The call screens are always dark, whatever the app's theme: text on them
/// uses fixed light colours (the light theme's text colour vanished here).
const _onDark = Color(0xFFF2F5FA);

String _clock(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Board 35: "On a call with Sarah · 02:14 · Tap to return".
class _ReturnBar extends StatelessWidget {
  const _ReturnBar({required this.call, required this.name, required this.onTap});
  final Call call;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1F6B4A),
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              const SkyIcon(SkyIcons.phoneCall, size: 16, color: Colors.white, stroke: 2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'On a call with ${name.split(' ').first} · ${_clock(call.elapsed)}',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
              const Text('Tap to return', style: TextStyle(fontSize: 12.5, color: Color(0xFFCFEFDF))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _CallView extends StatelessWidget {
  const _CallView({required this.calls, required this.call, required this.name, required this.onMinimise});
  final CallService calls;
  final Call call;
  final String name;
  final VoidCallback onMinimise;

  bool get _videoLayout =>
      call.phase != CallPhase.incoming && call.phase != CallPhase.ended && (call.cameraOn || call.remoteVideo);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF070A12),
      child: _videoLayout ? _video(context) : _voice(context),
    );
  }

  // ---------------------------------------------------- incoming and voice

  Widget _voice(BuildContext context) {
    final t = context.sky;
    final incoming = call.phase == CallPhase.incoming;
    final status = switch (call.phase) {
      CallPhase.incoming => call.video ? 'Incoming video call' : 'Incoming voice call',
      CallPhase.outgoing => 'Calling…',
      CallPhase.connecting => 'Connecting…',
      CallPhase.connected => _clock(call.elapsed),
      CallPhase.ended => _endText(),
    };
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF16213A), Color(0xFF070A12)],
          stops: [0, 0.7],
        ),
      ),
      child: SafeArea(
        // A short window (a laptop, a phone on its side) gets a smaller
        // avatar and gaps; anything shorter still scrolls rather than
        // overflowing.
        child: LayoutBuilder(builder: (context, box) {
          final compact = box.maxHeight < 720;
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: Column(children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: incoming || call.phase == CallPhase.ended
                        ? const SizedBox(height: 48)
                        : _MinimiseButton(onTap: onMinimise, color: const Color(0xFFC4CDDF)),
                  ),
                  if (call.weak) const _WeakBanner(),
                  const Spacer(),
                  if (incoming)
                    Text(call.video ? 'SKYLINE VIDEO CALL' : 'SKYLINE VOICE CALL',
                        style: const TextStyle(fontSize: 13, letterSpacing: 0.8, color: Color(0xFF9AA6BF))),
                  SizedBox(height: compact ? 12 : 18),
                  Avatar(name: name, seed: call.peer, size: compact ? 92 : (incoming ? 132 : 120)),
                  SizedBox(height: compact ? 14 : 22),
                  Text(name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontFamily: SkyFonts.display,
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          color: _onDark)),
                  const SizedBox(height: 10),
                  Text(status,
                      style: TextStyle(
                          fontFamily: call.phase == CallPhase.connected ? SkyFonts.mono : null,
                          fontSize: call.phase == CallPhase.connected ? 16 : 14,
                          color: const Color(0xFFC4CDDF))),
                  const SizedBox(height: 10),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    SkyIcon(SkyIcons.lock,
                        size: 13, color: call.phase == CallPhase.connected ? t.verified : t.accentText, stroke: 2),
                    const SizedBox(width: 6),
                    Text(incoming ? 'End-to-end encrypted' : "End-to-end encrypted · through Skyline's relay",
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA6BF))),
                  ]),
                  SizedBox(height: compact ? 20 : 32),
                  const Spacer(),
                  // A wide window keeps the buttons together, as on a phone.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: incoming
                        ? _incomingButtons(context)
                        : (call.phase != CallPhase.ended ? _voiceButtons(compact) : const SizedBox.shrink()),
                  ),
                  SizedBox(height: compact ? 20 : 40),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }

  String _endText() => switch (call.endReason) {
        'completed' => 'Call ended',
        'noAnswer' => 'No answer',
        'declined' => call.outgoing ? 'Declined' : 'Call declined',
        'busy' => 'Busy on another call',
        'missed' => 'Missed call',
        'elsewhere' => 'Answered on another device',
        'failed' => 'The call could not connect',
        _ => 'Call ended',
      };

  Widget _incomingButtons(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RoundButton(
                label: 'Decline',
                icon: SkyIcons.phoneDown,
                background: const Color(0xFFD04545),
                size: 72,
                onTap: calls.decline,
              ),
              _RoundButton(
                label: 'Message',
                icon: SkyIcons.chat,
                background: const Color(0x14FFFFFF),
                size: 56,
                onTap: calls.decline,
              ),
              _RoundButton(
                label: 'Accept',
                icon: call.video ? SkyIcons.video : SkyIcons.phoneCall,
                background: const Color(0xFF2FA36B),
                size: 72,
                onTap: calls.accept,
              ),
            ]),
      );

  Widget _voiceButtons(bool compact) => Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _ToggleButton(
                label: call.muted ? 'Unmute' : 'Mute',
                icon: call.muted ? SkyIcons.micOff : SkyIcons.mic,
                on: call.muted,
                onTap: calls.toggleMute),
            if (Platform.isAndroid || Platform.isIOS)
              _ToggleButton(label: 'Speaker', icon: SkyIcons.speaker, on: call.speaker, onTap: calls.toggleSpeaker),
            _ToggleButton(label: 'Video', icon: SkyIcons.video, on: false, onTap: calls.toggleCamera),
          ]),
        ),
        SizedBox(height: compact ? 16 : 28),
        _RoundButton(
            label: 'End', icon: SkyIcons.phoneDown, background: const Color(0xFFD04545), size: 72, onTap: calls.hangUp),
      ]);

  // --------------------------------------------------------------- video

  Widget _video(BuildContext context) {
    final t = context.sky;
    final canShare = Platform.isWindows || Platform.isAndroid;
    return Stack(children: [
      Positioned.fill(
        child: call.remoteVideo
            ? RTCVideoView(calls.remoteRenderer,
                objectFit: call.remoteSharing
                    ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                    : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            : Container(
                color: const Color(0xFF141B2A),
                alignment: Alignment.center,
                child: Avatar(name: name, seed: call.peer, size: 110),
              ),
      ),
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xBF05070C), Color(0x0005070C)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 18, 24),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _MinimiseButton(onTap: onMinimise, color: const Color(0xFFE3E8F2)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _onDark)),
                    const SizedBox(height: 2),
                    Row(children: [
                      Text(call.phase == CallPhase.connected ? _clock(call.elapsed) : 'Connecting…',
                          style: const TextStyle(fontFamily: SkyFonts.mono, fontSize: 12.5, color: Color(0xFFC4CDDF))),
                      const Text(' · ', style: TextStyle(fontSize: 12.5, color: Color(0xFFC4CDDF))),
                      SkyIcon(SkyIcons.lock, size: 12, color: t.verified, stroke: 2.2),
                      const SizedBox(width: 4),
                      const Text('end-to-end encrypted', style: TextStyle(fontSize: 12.5, color: Color(0xFFC4CDDF))),
                    ]),
                    if (call.sharing) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 5, 5, 5),
                        decoration:
                            BoxDecoration(color: const Color(0xE6D04545), borderRadius: BorderRadius.circular(999)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Text('You are sharing your screen',
                              style: TextStyle(fontSize: 12.5, color: Colors.white)),
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              backgroundColor: const Color(0x33FFFFFF),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(0, 26),
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            onPressed: calls.toggleShare,
                            child: const Text('Stop', style: TextStyle(fontSize: 12)),
                          ),
                        ]),
                      ),
                    ],
                    if (call.weak) ...[const SizedBox(height: 8), const _WeakBanner()],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
      Positioned(
        right: 16,
        top: 130,
        child: Container(
          width: 104,
          height: 150,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF141B2A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x40FFFFFF), width: 2),
          ),
          child: call.cameraOn
              ? RTCVideoView(calls.localRenderer,
                  mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
              : const Center(child: SkyIcon(SkyIcons.videoOff, size: 26, color: Color(0xFF9AA6BF))),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 30, 14, 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xD905070C), Color(0x0005070C)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _ToggleButton(
                  label: call.muted ? 'Unmute' : 'Mute',
                  icon: call.muted ? SkyIcons.micOff : SkyIcons.mic,
                  on: call.muted,
                  onTap: calls.toggleMute,
                  size: 54),
              _ToggleButton(
                  label: call.cameraOn ? 'Camera' : 'Camera off',
                  icon: call.cameraOn ? SkyIcons.video : SkyIcons.videoOff,
                  on: !call.cameraOn,
                  onTap: calls.toggleCamera,
                  size: 54),
              if (Platform.isAndroid || Platform.isIOS)
                _ToggleButton(label: 'Flip', icon: SkyIcons.camera, on: false, onTap: calls.flipCamera, size: 54),
              if (canShare)
                _ToggleButton(
                    label: call.sharing ? 'Sharing' : 'Share screen',
                    icon: SkyIcons.monitor,
                    on: call.sharing,
                    onTap: calls.toggleShare,
                    size: 54),
              _RoundButton(
                  label: 'End',
                  icon: SkyIcons.phoneDown,
                  background: const Color(0xFFD04545),
                  size: 54,
                  onTap: calls.hangUp),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// The call sits above the app's navigator, where there is no Overlay, so
/// nothing here may use a Tooltip (IconButton's tooltip needs one): buttons
/// carry a Semantics label instead.
class _MinimiseButton extends StatelessWidget {
  const _MinimiseButton({required this.onTap, required this.color});
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Minimise the call',
        child: InkWell(
          key: const ValueKey('call-minimise'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ExcludeSemantics(child: SkyIcon(SkyIcons.chevronDown, size: 24, color: color, stroke: 2.2)),
          ),
        ),
      );
}

class _WeakBanner extends StatelessWidget {
  const _WeakBanner();

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x26E8A33D),
        border: Border.all(color: const Color(0x66E8A33D)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SkyIcon(SkyIcons.warn, size: 14, color: t.caution, stroke: 2.2),
        const SizedBox(width: 8),
        const Text('Weak connection · trying to keep the call',
            style: TextStyle(fontSize: 12.5, color: Color(0xFFF2D29B))),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton(
      {required this.label, required this.icon, required this.background, required this.size, required this.onTap});
  final String label;
  final SkyIcons icon;
  final Color background;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        button: true,
        label: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: background, shape: BoxShape.circle),
            child: SkyIcon(icon, size: size * 0.4, color: Colors.white, stroke: 2),
          ),
        ),
      ),
      const SizedBox(height: 8),
      ExcludeSemantics(child: Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFFC4CDDF)))),
    ]);
  }
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({required this.label, required this.icon, required this.on, required this.onTap, this.size = 62});
  final String label;
  final SkyIcons icon;
  final bool on;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        button: true,
        toggled: on,
        label: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: on ? const Color(0xFFF2F5FA) : const Color(0x1FFFFFFF), shape: BoxShape.circle),
            child: SkyIcon(icon, size: size * 0.38, color: on ? const Color(0xFF0C111C) : const Color(0xFFF2F5FA)),
          ),
        ),
      ),
      const SizedBox(height: 7),
      ExcludeSemantics(child: Text(label, style: const TextStyle(fontSize: 11.5, color: Color(0xFFC4CDDF)))),
    ]);
  }
}

/// A person's name for the call screens, when they are a contact.
String callName(Messenger m, String peer) => m.contact(peer)?.displayName ?? 'Contact';
