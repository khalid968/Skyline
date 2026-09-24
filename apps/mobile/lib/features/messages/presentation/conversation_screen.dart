import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/connection_banner.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../data/messenger.dart';
import '../domain/models.dart';
import 'timer_sheet.dart';

/// Boards 3, 16, 17 and 19: one conversation.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _input = TextEditingController();
  late final Messenger messenger = ref.read(appControllerProvider).messenger!;

  @override
  void initState() {
    super.initState();
    messenger.openChat = widget.peer;
    unawaited(messenger.markRead(widget.peer));
  }

  @override
  void dispose() {
    if (messenger.openChat == widget.peer) messenger.openChat = null;
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    setState(() {});
    await messenger.sendText(widget.peer, text);
  }

  Future<void> _timer(ChatSummary? chat, String name) async {
    final r = await showTimerSheet(context, current: chat?.timerSeconds, peerName: name);
    if (r.seconds == -1 || r.seconds == chat?.timerSeconds) return;
    await messenger.setTimer(widget.peer, r.seconds);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListenableBuilder(
      listenable: messenger,
      builder: (context, _) {
        final contact = messenger.contact(widget.peer);
        return FutureBuilder<(ChatSummary?, List<LocalMessage>, List<KnownDevice>)>(
          future: () async {
            final chat = await messenger.store.chat(widget.peer);
            final msgs = await messenger.store.messages(widget.peer, limit: 200);
            final devices = await messenger.store.devicesOf(widget.peer);
            return (chat, msgs, devices);
          }(),
          builder: (context, snap) {
            final chat = snap.data?.$1;
            final messages = snap.data?.$2 ?? const <LocalMessage>[];
            final devices = snap.data?.$3 ?? const <KnownDevice>[];
            final name = contact?.displayName ?? chat?.displayName ?? '';
            final canWrite = contact != null;
            final waiting = messages.where((m) => m.status == MessageStatus.waiting).length;
            return Scaffold(
              body: SafeArea(
                child: Column(children: [
                  _Header(
                    peer: widget.peer,
                    name: name,
                    devices: devices,
                    timer: chat?.timerSeconds,
                    onTimer: canWrite ? () => _timer(chat, name) : null,
                  ),
                  ConnectionBanner(status: messenger.connection, waiting: waiting),
                  Expanded(
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      itemCount: messages.length + 1 + (messenger.isTyping(widget.peer) ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (messenger.isTyping(widget.peer)) {
                          if (i == 0) return const _Typing();
                          i--;
                        }
                        if (i == messages.length) return const _EncryptionNote();
                        final m = messages[i];
                        return Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: m.isNotice
                              ? _Notice(m: m, name: name, onVerify: () => context.push('/chat/${widget.peer}/verify'))
                              : _Bubble(m: m, onTap: m.fromMe ? () => _details(m) : null),
                        );
                      },
                    ),
                  ),
                  if (canWrite)
                    _Composer(
                      controller: _input,
                      name: name,
                      onSend: _send,
                      onTyping: () => messenger.typing(widget.peer),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'You can no longer message $name. Your administrator decides who you can reach.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: t.textSecondary),
                      ),
                    ),
                ]),
              ),
            );
          },
        );
      },
    );
  }

  /// Board 16: what each mark means, with Try again for a failed message.
  Future<void> _details(LocalMessage m) async {
    final t = context.sky;
    String at(DateTime d) =>
        '${d.toLocal().hour.toString().padLeft(2, '0')}:${d.toLocal().minute.toString().padLeft(2, '0')}';
    final steps = switch (m.status) {
      MessageStatus.sending => [('Sending', 'Now')],
      MessageStatus.waiting => [('Waiting to send', 'No connection')],
      MessageStatus.failed => [('Not sent', 'Refused')],
      MessageStatus.sent => [('Sent', at(m.sentAt)), ('Delivered', 'Waiting'), ('Read', '—')],
      MessageStatus.delivered => [('Sent', at(m.sentAt)), ('Delivered', 'Yes'), ('Read', '—')],
      MessageStatus.read => [('Sent', at(m.sentAt)), ('Delivered', 'Yes'), ('Read', 'Yes')],
    };
    final note = switch (m.status) {
      MessageStatus.sending => 'Encrypted on this phone and on its way. The clock turns into a tick as soon as the server has it.',
      MessageStatus.waiting => 'Encrypted and waiting on this phone. It sends by itself when you are back online.',
      MessageStatus.failed => 'This message never left your phone. Nothing was sent, so nothing can be read.',
      MessageStatus.sent => 'Sent means Skyline’s server has it, encrypted. It arrives when their device reconnects.',
      MessageStatus.delivered =>
        'Delivered means it reached at least one of their devices. Skyline’s server then deleted its copy. If either of you turns off read receipts, ticks stop here.',
      MessageStatus.read => 'Read means they opened it.',
    };
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Message details',
                style: TextStyle(fontFamily: SkyFonts.display, fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
            const SizedBox(height: 4),
            Text('“${m.text}”', maxLines: 3, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, height: 1.45, color: t.textSecondary)),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: t.ground,
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(children: [
                for (final s in steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(children: [
                      Expanded(child: Text(s.$1, style: TextStyle(fontSize: 14, color: t.textPrimary))),
                      Text(s.$2, style: TextStyle(fontSize: 13.5, color: t.textSecondary)),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            Text(note, style: TextStyle(fontSize: 12.5, height: 1.5, color: t.textSecondary)),
            const SizedBox(height: 16),
            if (m.status == MessageStatus.failed) ...[
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  unawaited(messenger.retry(m.id));
                },
                child: const Text('Try again'),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ]),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.peer, required this.name, required this.devices, required this.timer, this.onTimer});
  final String peer;
  final String name;
  final List<KnownDevice> devices;
  final int? timer;
  final VoidCallback? onTimer;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final unverified = devices.where((d) => d.verifiedAt == null).length;
    final allVerified = devices.isNotEmpty && unverified == 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Row(children: [
        IconButton(
          tooltip: 'Back to chats',
          onPressed: () => context.pop(),
          icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
        ),
        Avatar(name: name, seed: peer, size: 38),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            onTap: () => context.push('/chat/$peer/verify'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
              const SizedBox(height: 2),
              Row(children: [
                if (allVerified) ...[
                  SkyIcon(SkyIcons.check, size: 12, color: t.verified, stroke: 2.6),
                  const SizedBox(width: 4),
                  Text('Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.verified)),
                ] else if (devices.any((d) => d.verifiedAt != null)) ...[
                  SkyIcon(SkyIcons.warn, size: 12, color: t.caution, stroke: 2.4),
                  const SizedBox(width: 4),
                  Text('$unverified device${unverified == 1 ? '' : 's'} not verified',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.caution)),
                ] else
                  Text('Tap to verify safety numbers', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                if (timer != null) ...[
                  Text(' · ', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                  SkyIcon(SkyIcons.clock, size: 12, color: t.caution, stroke: 2.3),
                  const SizedBox(width: 3),
                  Text(timerLabel(timer), style: TextStyle(fontSize: 12, color: t.caution)),
                ],
              ]),
            ]),
          ),
        ),
        if (onTimer != null)
          IconButton(
            tooltip: 'Disappearing messages',
            onPressed: onTimer,
            icon: SkyIcon(SkyIcons.clock, size: 21, color: timer != null ? t.caution : t.textSecondary),
          ),
      ]),
    );
  }
}

class _EncryptionNote extends StatelessWidget {
  const _EncryptionNote();

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkyIcon(SkyIcons.lock, size: 14, color: t.accentText, stroke: 2),
          const SizedBox(width: 8),
          Flexible(
            child: Text('Messages are end-to-end encrypted. Skyline servers store only ciphertext.',
                style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary)),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m, this.onTap});
  final LocalMessage m;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final failed = m.status == MessageStatus.failed;
    final bg = !m.fromMe
        ? t.bubbleIncoming
        : failed
            ? const Color(0xFF5A1E26)
            : m.status == MessageStatus.waiting
                ? const Color(0xFF26365E)
                : t.bubbleOutgoing;
    final fg = m.fromMe ? Colors.white : t.textPrimary;
    final meta = m.fromMe ? const Color(0xFFDDE5FC) : t.textSecondary;
    final time =
        '${m.sentAt.toLocal().hour.toString().padLeft(2, '0')}:${m.sentAt.toLocal().minute.toString().padLeft(2, '0')}';
    final statusWord = switch (m.status) {
      MessageStatus.sending => 'Sending',
      MessageStatus.waiting => 'Waiting to send',
      MessageStatus.sent => 'Sent',
      MessageStatus.delivered => 'Delivered',
      MessageStatus.read => 'Read',
      MessageStatus.failed => 'Not sent',
    };
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: bg,
        border: failed ? Border.all(color: const Color(0xFFB7414C)) : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.fromMe ? 18 : 5),
          bottomRight: Radius.circular(m.fromMe ? 5 : 18),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(m.text, style: TextStyle(fontSize: 14.5, height: 1.45, color: fg)),
        ),
        const SizedBox(height: 5),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (m.timerSeconds != null) ...[
            SkyIcon(SkyIcons.clock, size: 11, color: meta, stroke: 2.2),
            const SizedBox(width: 4),
          ],
          Text(m.status == MessageStatus.waiting ? 'Waiting to send' : time,
              style: TextStyle(fontSize: 11, color: meta)),
          if (m.fromMe) ...[const SizedBox(width: 5), _Tick(status: m.status)],
        ]),
        if (failed)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Not sent · tap to try again',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFFFD0D2))),
          ),
      ]),
    );
    return Align(
      alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Semantics(
        button: onTap != null,
        label: m.fromMe ? '$statusWord at $time' : null,
        child: GestureDetector(onTap: onTap, child: bubble),
      ),
    );
  }
}

/// Board 16's marks. Read is a white badge: it differs in lightness, not just
/// hue, so it is legible on the blue bubble.
class _Tick extends StatelessWidget {
  const _Tick({required this.status});
  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    const c = Color(0xFFC9D6FB);
    return switch (status) {
      MessageStatus.sending || MessageStatus.waiting => const SkyIcon(SkyIcons.clock, size: 13, color: c, stroke: 2.3),
      MessageStatus.sent => const SkyIcon(SkyIcons.tickOne, size: 14, color: c, stroke: 2.3),
      MessageStatus.delivered => const SkyIcon(SkyIcons.tickTwo, size: 15, color: c, stroke: 2.3),
      MessageStatus.read => Container(
          height: 16,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
          child: const SkyIcon(SkyIcons.tickTwo, size: 14, color: Color(0xFF2A4FB8), stroke: 2.8),
        ),
      MessageStatus.failed => const SkyIcon(SkyIcons.alertCircle, size: 14, color: Color(0xFFFFB4B7), stroke: 2.3),
    };
  }
}

/// Board 17 (and 15's timer notice).
class _Notice extends StatelessWidget {
  const _Notice({required this.m, required this.name, required this.onVerify});
  final LocalMessage m;
  final String name;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final first = name.split(' ').first;
    switch (m.notice) {
      case NoticeType.blocked:
      case NoticeType.undecryptable:
        final blocked = m.notice == NoticeType.blocked;
        return Semantics(
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1116),
              border: Border.all(color: const Color(0xFF8C2F3A)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SkyIcon(SkyIcons.shieldBlocked, size: 19, color: Color(0xFFFF9AA0), stroke: 2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(blocked ? 'A message was blocked' : 'A message could not be opened',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFFFD3D6))),
                  const SizedBox(height: 4),
                  Text(
                    blocked
                        ? 'It claimed to come from one of $first’s devices, but its security key does not match the one Skyline knows for that device. Skyline did not open it.'
                        : 'It was damaged or not meant for this device. Skyline did not show it.',
                    style: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFFF2C4C8)),
                  ),
                  if (blocked) ...[
                    const SizedBox(height: 8),
                    Text('Keys never change in Skyline. Tell $first and your administrator in person or by phone.',
                        style: const TextStyle(fontSize: 12.5, height: 1.5, color: Color(0xFFD9A9AE))),
                  ],
                ]),
              ),
            ]),
          ),
        );
      case NoticeType.newDevice:
        final platform = m.noticeData['platform'] as String?;
        final what = switch (platform) {
          'windows' => 'a Windows PC',
          'android' => 'an Android phone',
          'ios' => 'an iPhone',
          _ => 'a new device',
        };
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SkyIcon(platform == 'windows' ? SkyIcons.monitor : SkyIcons.phone, size: 18, color: t.accentText),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: '$first added a new device',
                      style: TextStyle(fontWeight: FontWeight.w600, color: t.textPrimary)),
                  TextSpan(
                      text: ' — $what, activated with a code from your administrator. It has its own safety number.'),
                ]), style: TextStyle(fontSize: 13, height: 1.5, color: t.textSecondary)),
              ),
            ]),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onVerify, child: const Text('Verify this device')),
            ),
          ]),
        );
      case NoticeType.renamed:
        return _pill(context, SkyIcons.pen,
            'Your administrator renamed ${m.noticeData['from'] ?? 'this person'} to ${m.noticeData['to'] ?? name}. Their safety numbers did not change.');
      case NoticeType.timerChanged:
        final seconds = m.noticeData['seconds'] as int?;
        final who = m.noticeData['byMe'] == true ? 'You' : first;
        return _pill(
          context,
          SkyIcons.clock,
          seconds == null
              ? '$who turned off disappearing messages'
              : '$who set disappearing messages to ${timerLabel(seconds).toLowerCase()}',
          color: t.caution,
        );
      case null:
        return const SizedBox.shrink();
    }
  }

  Widget _pill(BuildContext context, SkyIcons icon, String text, {Color? color}) {
    final t = context.sky;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkyIcon(icon, size: 14, color: color ?? t.textSecondary, stroke: 2),
          const SizedBox(width: 8),
          Flexible(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: t.textSecondary))),
        ]),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: 'typing',
        child: Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: t.bubbleIncoming,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(5),
              bottomRight: Radius.circular(18),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final c in const [Color(0xFF8E9BB4), Color(0xFF6E7E99), Color(0xFF55637D)])
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.name, required this.onSend, required this.onTyping});
  final TextEditingController controller;
  final String name;
  final VoidCallback onSend;
  final VoidCallback onTyping;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            onChanged: (_) => onTyping(),
            decoration: InputDecoration(
              hintText: 'Message',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide(color: t.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide(color: t.border),
              ),
            ),
            style: TextStyle(fontSize: 14.5, color: t.textPrimary),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          tooltip: 'Send to $name',
          onPressed: onSend,
          icon: const SkyIcon(SkyIcons.send, size: 19, color: Colors.white, stroke: 2),
        ),
      ]),
    );
  }
}
