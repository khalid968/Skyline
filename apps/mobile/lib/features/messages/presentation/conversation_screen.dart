import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/connection_banner.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../media/data/media_service.dart';
import '../../media/presentation/attach.dart';
import '../../media/presentation/media_bubble.dart';
import '../../media/presentation/voice_recorder.dart';
import '../data/messenger.dart';
import '../domain/models.dart';
import 'timer_sheet.dart';

/// Boards 3, 16, 17, 19 and 20-22: one conversation.
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

  /// Boards 20, 23 and 24: attach one or several files, preview with a
  /// caption (and view once), send.
  Future<void> _attach(String name) async {
    final picked = await showAttachSheet(context);
    if (picked == null || !mounted) return;
    final kept = <PickedMedia>[];
    var tooBig = false;
    for (final p in picked) {
      if (await p.file.length() > MediaService.maxBytes) {
        tooBig = true;
        await p.discard();
      } else {
        kept.add(p);
      }
    }
    if (tooBig && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Files can be up to 2 GB; larger ones were left out.')));
    }
    if (kept.isEmpty || !mounted) return;
    final r = await showMediaPreview(context, kept, peerName: name, allowViewOnce: messenger.group(widget.peer) == null);
    if (r == null) {
      for (final p in kept) {
        await p.discard();
      }
      return;
    }
    unawaited(messenger.sendFiles(
      widget.peer,
      [for (final p in r.items) OutgoingFile(p.file, p.kind, name: p.name, temporary: p.temporary)],
      caption: r.caption,
      viewOnce: r.viewOnce,
    ));
  }

  Future<void> _sendVoice(VoiceClip clip) => messenger.sendMedia(
        widget.peer,
        clip.file,
        MediaKind.voice,
        name: 'Voice message.${clip.file.path.split('.').last}',
        durationMs: clip.durationMs,
        wave: clip.wave,
        deleteSource: true,
      );

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
            final group = messenger.group(widget.peer);
            final isGroup = (chat?.isGroup ?? false) || group != null;
            final name = group?.name ?? contact?.displayName ?? chat?.displayName ?? '';
            final canWrite =
                isGroup ? group != null && !group.archived && !(chat?.left ?? false) : contact != null;
            final waiting = messages.where((m) => m.status == MessageStatus.waiting).length;
            return Scaffold(
              body: SafeArea(
                child: Column(children: [
                  if (isGroup)
                    _GroupHeader(
                      peer: widget.peer,
                      name: name,
                      members: group?.members.length,
                      timer: chat?.timerSeconds,
                      onTimer: canWrite ? () => _timer(chat, name) : null,
                    )
                  else
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
                              : m.isMedia
                                  ? _FromMember(
                                      m: m,
                                      child: MediaBubble(
                                        m: m,
                                        messenger: messenger,
                                        meta: _Meta(m: m),
                                        onDetails: m.fromMe ? () => _details(m) : null,
                                      ),
                                    )
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
                      onAttach: () => _attach(name),
                      onVoice: _sendVoice,
                      recordingDir: messenger.media.viewDir,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        !isGroup
                            ? 'You can no longer message $name. Your administrator decides who you can reach.'
                            : group?.archived ?? false
                                ? 'Your administrator closed this group. What is here stays on this device.'
                                : 'You are no longer in this group. Only an administrator can add you back.',
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
            Text(m.isMedia ? (m.text.isEmpty ? m.mediaLabel : '${m.mediaLabel} · “${m.text}”') : '“${m.text}”',
                maxLines: 3, overflow: TextOverflow.ellipsis,
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
        IconButton(
          tooltip: 'Media',
          onPressed: () => context.push('/chat/$peer/media'),
          icon: SkyIcon(SkyIcons.photo, size: 21, color: t.textSecondary),
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
        if (m.senderName != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(m.senderName!,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _nameColor(m.senderUserId!))),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(m.text, style: TextStyle(fontSize: 14.5, height: 1.45, color: fg)),
        ),
        const SizedBox(height: 5),
        _Meta(m: m),
        if (failed)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Not sent · tap to try again',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFFFD0D2))),
          ),
      ]),
    );
    final shown = Semantics(
      button: onTap != null,
      label: m.fromMe ? '$statusWord at $time' : null,
      child: GestureDetector(onTap: onTap, child: bubble),
    );
    return Align(
      alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: m.senderUserId == null || m.fromMe
          ? shown
          : Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Avatar(name: m.senderName ?? '', seed: m.senderUserId!, size: 28),
              const SizedBox(width: 8),
              Flexible(child: shown),
            ]),
    );
  }
}

/// Time, disappearing-timer clock and status mark under a message.
class _Meta extends StatelessWidget {
  const _Meta({required this.m});
  final LocalMessage m;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final meta = m.fromMe ? const Color(0xFFDDE5FC) : t.textSecondary;
    final time =
        '${m.sentAt.toLocal().hour.toString().padLeft(2, '0')}:${m.sentAt.toLocal().minute.toString().padLeft(2, '0')}';
    final remote = m.isMedia &&
        !m.fromMe &&
        m.media!.state == MediaState.remote &&
        m.media!.kind == MediaKind.video; // documents say it on their own line
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (m.timerSeconds != null) ...[
        SkyIcon(SkyIcons.clock, size: 11, color: meta, stroke: 2.2),
        const SizedBox(width: 4),
      ],
      Text(
        m.status == MessageStatus.waiting ? 'Waiting to send' : (remote ? '$time · tap to download' : time),
        style: TextStyle(fontSize: 11, color: meta),
      ),
      if (m.fromMe) ...[const SizedBox(width: 5), _Tick(status: m.status)],
    ]);
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
      case NoticeType.groupEvent:
        final who = m.noticeData['you'] == true ? 'You' : (m.noticeData['name'] as String? ?? 'Someone');
        final text = switch (m.noticeData['event']) {
          'group_created' => 'Your administrator created this group',
          'group_renamed' => 'Your administrator renamed the group from ${m.noticeData['from']} to ${m.noticeData['to']}',
          'group_member_added' => m.noticeData['you'] == true ? 'You were added to the group' : '$who was added',
          'group_member_removed' => m.noticeData['you'] == true ? 'You were removed from the group' : '$who was removed',
          'group_member_left' => m.noticeData['you'] == true ? 'You left the group' : '$who left the group',
          'group_archived' => 'Your administrator closed this group',
          'group_reopened' => 'Your administrator reopened this group',
          _ => 'The group changed',
        };
        return _pill(context, SkyIcons.chat, text);
      case NoticeType.timerChanged:
        final seconds = m.noticeData['seconds'] as int?;
        final who = m.noticeData['byMe'] == true
            ? 'You'
            : ((m.noticeData['name'] as String?)?.split(' ').first ?? first);
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

/// The message bar: attach, text, and send (or hold the microphone to
/// record, board 22; slide left to cancel).
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.name,
    required this.onSend,
    required this.onTyping,
    required this.onAttach,
    required this.onVoice,
    required this.recordingDir,
  });
  final TextEditingController controller;
  final String name;
  final VoidCallback onSend;
  final VoidCallback onTyping;
  final VoidCallback onAttach;
  final Future<void> Function(VoiceClip clip) onVoice;
  final Directory recordingDir;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late final _recorder = VoiceRecorder(widget.recordingDir);
  Timer? _tick;
  bool _recording = false;
  bool _cancelArmed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _tick?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _startRecording() async {
    if (_recording) return;
    final ok = await _recorder.start();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Skyline needs the microphone to record. Allow it in your device settings.')));
      return;
    }
    setState(() {
      _recording = true;
      _cancelArmed = false;
    });
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    _tick?.cancel();
    setState(() => _recording = false);
    if (!send || _cancelArmed) {
      await _recorder.cancel();
      return;
    }
    final clip = await _recorder.stop();
    if (clip == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Hold the microphone to record.')));
      }
      return;
    }
    await widget.onVoice(clip);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final e = _recorder.elapsed;
    final clock = '${e.inMinutes}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
      child: Row(children: [
        if (_recording) ...[
          const SizedBox(width: 8),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _cancelArmed ? const Color(0xFF33405C) : const Color(0xFFE5484D),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(clock, style: TextStyle(fontFamily: SkyFonts.mono, fontSize: 15, color: t.textPrimary)),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                _cancelArmed ? 'Release to cancel' : 'Recording · slide left to cancel',
                style: TextStyle(fontSize: 13, color: _cancelArmed ? t.caution : t.textSecondary),
              ),
            ),
          ),
        ] else ...[
          IconButton(
            tooltip: 'Attach',
            onPressed: widget.onAttach,
            style: IconButton.styleFrom(backgroundColor: t.surfaceRaised),
            icon: SkyIcon(SkyIcons.plus, size: 20, color: t.textSecondary, stroke: 2),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: widget.controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              onChanged: (_) => widget.onTyping(),
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
        ],
        const SizedBox(width: 6),
        if (hasText && !_recording)
          IconButton.filled(
            tooltip: 'Send to ${widget.name}',
            onPressed: widget.onSend,
            icon: const SkyIcon(SkyIcons.send, size: 19, color: Colors.white, stroke: 2),
          )
        else
          // The same widget throughout a recording, so the press is not lost.
          Semantics(
            key: const ValueKey('mic'),
            button: true,
            label: _recording ? 'Release to send' : 'Hold to record a voice message',
            child: GestureDetector(
              onLongPressStart: (_) => _startRecording(),
              onLongPressMoveUpdate: (d) {
                final armed = d.offsetFromOrigin.dx < -80;
                if (armed != _cancelArmed) setState(() => _cancelArmed = armed);
              },
              onLongPressEnd: (_) => _stopRecording(send: true),
              onLongPressCancel: () => _stopRecording(send: false),
              onTap: () => ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Hold the microphone to record.'))),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: _recording ? 56 : 40,
                height: _recording ? 56 : 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _recording ? const Color(0xFFD04545) : t.surfaceRaised,
                  shape: BoxShape.circle,
                ),
                child: SkyIcon(SkyIcons.mic,
                    size: _recording ? 22 : 19, color: _recording ? Colors.white : t.textSecondary, stroke: 2),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A person's colour in a group (the same tint as their avatar).
Color _nameColor(String userId) => Color.lerp(Avatar.tintFor(userId), Colors.white, 0.35)!;

/// Board 27: in a group, a member's media message carries their name and
/// picture, like a text bubble.
class _FromMember extends StatelessWidget {
  const _FromMember({required this.m, required this.child});
  final LocalMessage m;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (m.senderUserId == null || m.fromMe) return child;
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Avatar(name: m.senderName ?? '', seed: m.senderUserId!, size: 28),
        const SizedBox(width: 8),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 3),
              child: Text(m.senderName ?? '',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _nameColor(m.senderUserId!))),
            ),
            child,
          ]),
        ),
      ]),
    );
  }
}

/// Board 27: a group's header. Tapping the name opens group info (board 29).
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.peer, required this.name, required this.members, required this.timer, this.onTimer});
  final String peer;
  final String name;
  final int? members;
  final int? timer;
  final VoidCallback? onTimer;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Row(children: [
        IconButton(
          tooltip: 'Back to chats',
          onPressed: () => context.pop(),
          icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
        ),
        Avatar(name: name, seed: peer, size: 38, square: true),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            onTap: () => context.push('/chat/$peer/info'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
              const SizedBox(height: 2),
              Row(children: [
                Text(members == null ? 'Tap for group info' : '$members members · tap for group info',
                    style: TextStyle(fontSize: 12, color: t.textSecondary)),
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
        IconButton(
          tooltip: 'Media',
          onPressed: () => context.push('/chat/$peer/media'),
          icon: SkyIcon(SkyIcons.photo, size: 21, color: t.textSecondary),
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
