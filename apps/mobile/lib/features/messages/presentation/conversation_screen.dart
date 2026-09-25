import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'message_actions_sheet.dart';
import 'timer_sheet.dart';

/// Boards 3, 16, 17, 19, 20-22 and 27-29: one conversation.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _input = TextEditingController();
  late final Messenger messenger = ref.read(appControllerProvider).messenger!;

  // Board 28: the composer is answering a message, or editing one of ours.
  LocalMessage? _replyTo;
  LocalMessage? _editing;
  // Board 29: people mentioned so far (userId -> "@First") and the "@..." being typed.
  final Map<String, String> _mentioned = {};
  String? _mentionQuery;
  int _pin = 0;
  Timer? _draftTimer;
  // Tapping a quote jumps to the message it quotes (and flashes it).
  final _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};
  String? _flash;

  @override
  void initState() {
    super.initState();
    messenger.openChat = widget.peer;
    unawaited(messenger.markRead(widget.peer));
    // Board 26: pick up where you left off.
    messenger.draft(widget.peer).then((d) {
      if (d != null && mounted && _input.text.isEmpty) _input.text = d;
    });
    _input.addListener(_draftSoon);
  }

  void _draftSoon() {
    if (_editing != null) return; // an edit is not a draft
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), () => messenger.saveDraft(widget.peer, _input.text));
  }

  @override
  void dispose() {
    if (messenger.openChat == widget.peer) messenger.openChat = null;
    _draftTimer?.cancel();
    if (_editing == null) unawaited(messenger.saveDraft(widget.peer, _input.text));
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    final reply = _replyTo == null ? null : messenger.quoteOf(_replyTo!);
    final mentions = [
      for (final e in _mentioned.entries)
        if (text.contains(e.value)) e.key
    ];
    _input.clear();
    setState(() {
      _editing = null;
      _replyTo = null;
      _mentioned.clear();
      _mentionQuery = null;
    });
    if (editing != null) {
      await messenger.editMessage(editing.id, text);
    } else {
      await messenger.sendText(widget.peer, text, replyTo: reply, mentions: mentions);
    }
  }

  /// Watches for "@name" being typed in a group (board 29).
  void _onInput() {
    messenger.typing(widget.peer);
    if (messenger.group(widget.peer) == null) return;
    final text = _input.text;
    var at = _input.selection.baseOffset;
    if (at < 0 || at > text.length) at = text.length;
    final before = text.substring(0, at);
    final i = before.lastIndexOf('@');
    String? q;
    if (i >= 0 && (i == 0 || before[i - 1].trim().isEmpty)) {
      final typed = before.substring(i + 1);
      if (!typed.contains(RegExp(r'\s')) && typed.length <= 30) q = typed;
    }
    if (q != _mentionQuery) setState(() => _mentionQuery = q);
  }

  void _mention(GroupMember m) {
    final text = _input.text;
    var at = _input.selection.baseOffset;
    if (at < 0 || at > text.length) at = text.length;
    final i = text.substring(0, at).lastIndexOf('@');
    if (i < 0) return;
    final tag = '@${m.displayName.split(' ').first}';
    final next = '${text.substring(0, i)}$tag ${text.substring(at)}';
    _input.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: i + tag.length + 1));
    setState(() {
      _mentioned[m.userId] = tag;
      _mentionQuery = null;
    });
  }

  /// Board 28: long-press (right-click on a PC) a message.
  Future<void> _actions(LocalMessage m,
      {required bool canWrite, required ChatSummary? chat, required String name}) async {
    final pinned = chat?.pins.contains(m.id) ?? false;
    final actions = [
      if (canWrite && !m.deleted) MessageAction.reply,
      if (canWrite && messenger.canEdit(m)) MessageAction.edit,
      if (m.text.isNotEmpty && !m.deleted) MessageAction.copy,
      if (canWrite && !m.deleted) pinned ? MessageAction.unpin : MessageAction.pin,
      if (m.fromMe && !m.deleted) MessageAction.info,
      MessageAction.delete,
    ];
    final choice = await showMessageActions(
      context,
      actions: actions,
      myReaction: m.reactions[messenger.me],
      canReact: canWrite && !m.deleted,
    );
    if (choice == null || !mounted) return;
    if (choice.emoji != null) return messenger.react(m.id, choice.emoji!);
    switch (choice.action!) {
      case MessageAction.reply:
        setState(() {
          _replyTo = m;
          _editing = null;
        });
      case MessageAction.edit:
        setState(() {
          _editing = m;
          _replyTo = null;
          _input.text = m.text;
        });
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.text));
      case MessageAction.pin:
        await messenger.pin(m.id, true);
      case MessageAction.unpin:
        await messenger.pin(m.id, false);
      case MessageAction.info:
        await _details(m);
      case MessageAction.delete:
        final everyone = await showDeleteChoice(
          context,
          forEveryone: canWrite && messenger.canDeleteForEveryone(m),
          who: name.split(' ').first,
        );
        if (everyone == true) await messenger.deleteForEveryone(m.id);
        if (everyone == false) await messenger.deleteForMe(m.id);
    }
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
    final r =
        await showMediaPreview(context, kept, peerName: name, allowViewOnce: messenger.group(widget.peer) == null);
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

  /// Scrolls to the quoted message: older ones are built only when near the
  /// screen, so it moves up a screenful at a time until the message exists.
  Future<void> _jumpTo(String id) async {
    for (var step = 0; step < 60 && mounted; step++) {
      final ctx = _keys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.4);
        setState(() => _flash = id);
        Timer(const Duration(milliseconds: 1400), () {
          if (mounted && _flash == id) setState(() => _flash = null);
        });
        return;
      }
      if (!_scroll.hasClients) break;
      final pos = _scroll.position;
      if (pos.pixels >= pos.maxScrollExtent) break; // the oldest message on this device
      _scroll.jumpTo((pos.pixels + pos.viewportDimension * 0.8).clamp(0, pos.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('That message is no longer on this device.')));
    }
  }

  List<String> _tagsFor(LocalMessage m) {
    if (m.mentions.isEmpty) return const [];
    final g = messenger.group(widget.peer);
    return [
      for (final id in m.mentions)
        if (g?.member(id) case final gm?) '@${gm.displayName.split(' ').first}',
    ];
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
        return FutureBuilder<(ChatSummary?, List<LocalMessage>, List<KnownDevice>, List<LocalMessage>)>(
          future: () async {
            final chat = await messenger.store.chat(widget.peer);
            final msgs = await messenger.store.messages(widget.peer, limit: 200);
            final devices = await messenger.store.devicesOf(widget.peer);
            final pins = <LocalMessage>[];
            for (final id in chat?.pins ?? const <String>[]) {
              final p = await messenger.store.message(id);
              if (p != null) pins.add(p);
            }
            return (chat, msgs, devices, pins);
          }(),
          builder: (context, snap) {
            final chat = snap.data?.$1;
            final messages = snap.data?.$2 ?? const <LocalMessage>[];
            final devices = snap.data?.$3 ?? const <KnownDevice>[];
            final pins = snap.data?.$4 ?? const <LocalMessage>[];
            final group = messenger.group(widget.peer);
            final isGroup = (chat?.isGroup ?? false) || group != null;
            final name = group?.name ?? contact?.displayName ?? chat?.displayName ?? '';
            // Board 40: a suspended contact is unavailable. History stays;
            // writing and calling do not, and nothing says why.
            final unavailable = !isGroup && (contact?.suspended ?? false);
            final canWrite =
                isGroup ? group != null && !group.archived && !(chat?.left ?? false) : contact != null && !unavailable;
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
                      unavailable: unavailable,
                      devices: devices,
                      timer: chat?.timerSeconds,
                      onTimer: canWrite ? () => _timer(chat, name) : null,
                      onCall: canWrite
                          ? (video) => ref.read(appControllerProvider).calls?.start(widget.peer, video: video)
                          : null,
                    ),
                  if (pins.isNotEmpty)
                    _PinnedBar(
                      pins: pins,
                      index: _pin % pins.length,
                      onTap: () => setState(() => _pin = (_pin + 1) % pins.length),
                    ),
                  ConnectionBanner(status: messenger.connection, waiting: waiting),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      itemCount: messages.length + 1 + (messenger.isTyping(widget.peer) ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (messenger.isTyping(widget.peer)) {
                          if (i == 0) return _Typing(name: messenger.typingName(widget.peer));
                          i--;
                        }
                        if (i == messages.length) return const _EncryptionNote();
                        final m = messages[i];
                        if (m.isNotice) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: _Notice(
                              m: m,
                              name: name,
                              onVerify: () => context.push('/chat/${widget.peer}/verify'),
                              onCallBack: canWrite
                                  ? (video) => ref.read(appControllerProvider).calls?.start(widget.peer, video: video)
                                  : null,
                            ),
                          );
                        }
                        void act() => _actions(m, canWrite: canWrite, chat: chat, name: name);
                        return AnimatedContainer(
                          key: _keys.putIfAbsent(m.id, GlobalKey.new),
                          duration: const Duration(milliseconds: 250),
                          padding: const EdgeInsets.only(top: 10),
                          decoration: BoxDecoration(
                            color: _flash == m.id ? t.accentFill.withValues(alpha: 0.18) : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: _Actionable(
                            m: m,
                            me: messenger.me,
                            onActions: act,
                            onReact: canWrite && !m.deleted ? (e) => messenger.react(m.id, e) : null,
                            child: m.isMedia
                                ? _FromMember(
                                    m: m,
                                    child: MediaBubble(
                                      m: m,
                                      messenger: messenger,
                                      meta: _Meta(m: m),
                                      onDetails: m.fromMe ? () => _details(m) : null,
                                    ),
                                  )
                                : _Bubble(
                                    m: m,
                                    me: messenger.me,
                                    unavailable: unavailable,
                                    mentionTags: _tagsFor(m),
                                    nameOf: messenger.nameOf,
                                    onQuote: m.replyTo == null ? null : () => _jumpTo(m.replyTo!['id']! as String),
                                    onTap: m.fromMe && !m.deleted ? () => _details(m) : null,
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (canWrite && (_replyTo != null || _editing != null))
                    _ComposerBanner(
                      replyTo: _replyTo,
                      editing: _editing,
                      myId: messenger.me,
                      onCancel: () => setState(() {
                        if (_editing != null) _input.clear();
                        _replyTo = null;
                        _editing = null;
                      }),
                    ),
                  if (canWrite && _mentionQuery != null && group != null)
                    _MentionPicker(
                      members: [
                        for (final gm in group.members)
                          if (!gm.you && gm.displayName.toLowerCase().contains(_mentionQuery!.toLowerCase())) gm,
                      ].take(5).toList(),
                      onPick: _mention,
                    ),
                  if (canWrite)
                    _Composer(
                      controller: _input,
                      name: name,
                      onSend: _send,
                      onTyping: _onInput,
                      hint: isGroup ? 'Message $name' : 'Message',
                      onAttach: () => _attach(name),
                      onVoice: _sendVoice,
                      recordingDir: messenger.media.viewDir,
                    )
                  else if (unavailable)
                    _Unavailable(name: name)
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
      MessageStatus.sending =>
        'Encrypted on this phone and on its way. The clock turns into a tick as soon as the server has it.',
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
      isScrollControlled: true, // as tall as it needs, up to the screen
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Message details',
                style: TextStyle(
                    fontFamily: SkyFonts.display, fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
            const SizedBox(height: 4),
            Text(m.isMedia ? (m.text.isEmpty ? m.mediaLabel : '${m.mediaLabel} · “${m.text}”') : '“${m.text}”',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
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
  const _Header({
    required this.peer,
    required this.name,
    required this.devices,
    required this.timer,
    this.onTimer,
    this.onCall,
    this.unavailable = false,
  });
  final void Function(bool video)? onCall; // board 35
  final bool unavailable; // board 40
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
        Opacity(opacity: unavailable ? 0.45 : 1, child: Avatar(name: name, seed: peer, size: 38)),
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
              if (unavailable)
                Text('Unavailable', style: TextStyle(fontSize: 12, color: t.textSecondary))
              else
                Row(children: [
                  if (allVerified) ...[
                    SkyIcon(SkyIcons.check, size: 12, color: t.verified, stroke: 2.6),
                    const SizedBox(width: 4),
                    Flexible(
                        child: Text('Verified',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.verified),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                  ] else if (devices.any((d) => d.verifiedAt != null)) ...[
                    SkyIcon(SkyIcons.warn, size: 12, color: t.caution, stroke: 2.4),
                    const SizedBox(width: 4),
                    Flexible(
                        child: Text('$unverified device${unverified == 1 ? '' : 's'} not verified',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.caution),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                  ] else
                    Flexible(
                        child: Text('Tap to verify safety numbers',
                            style: TextStyle(fontSize: 12, color: t.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                  if (timer != null) ...[
                    Text(' · ', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                    SkyIcon(SkyIcons.clock, size: 12, color: t.caution, stroke: 2.3),
                    const SizedBox(width: 3),
                    Flexible(
                        child: Text(timerLabel(timer),
                            style: TextStyle(fontSize: 12, color: t.caution),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                  ],
                ]),
            ]),
          ),
        ),
        if (onCall != null) ...[
          IconButton(
            tooltip: 'Voice call',
            onPressed: () => onCall!(false),
            icon: SkyIcon(SkyIcons.phoneCall, size: 21, color: t.textSecondary),
          ),
          IconButton(
            tooltip: 'Video call',
            onPressed: () => onCall!(true),
            icon: SkyIcon(SkyIcons.video, size: 22, color: t.textSecondary),
          ),
        ],
        // A phone has room for the call buttons and one more: media and the
        // timer fold into a menu there. A wide window shows them all.
        if (MediaQuery.sizeOf(context).width >= 520) ...[
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
        ] else
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: SkyIcon(SkyIcons.more, size: 21, color: timer != null ? t.caution : t.textSecondary),
            onSelected: (v) => v == 'media' ? context.push('/chat/$peer/media') : onTimer?.call(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'media',
                child: Row(children: [
                  SkyIcon(SkyIcons.photo, size: 19, color: t.textSecondary),
                  const SizedBox(width: 12),
                  const Text('Media'),
                ]),
              ),
              if (onTimer != null)
                PopupMenuItem(
                  value: 'timer',
                  child: Row(children: [
                    SkyIcon(SkyIcons.clock, size: 19, color: timer != null ? t.caution : t.textSecondary),
                    const SizedBox(width: 12),
                    const Text('Disappearing messages'),
                  ]),
                ),
            ],
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
  const _Bubble({
    required this.m,
    required this.me,
    this.mentionTags = const [],
    this.onTap,
    this.onQuote,
    this.nameOf,
    this.unavailable = false,
  });
  final LocalMessage m;
  final String me;
  final bool unavailable; // board 40: why a message was not sent
  final List<String> mentionTags;
  final VoidCallback? onTap;
  final VoidCallback? onQuote;
  final String? Function(String userId)? nameOf;

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
    if (m.deleted) {
      // Board 27/28: what a deletion for everyone leaves behind.
      final gone = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF33405C)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (m.senderName != null)
            Text(m.senderName!,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _nameColor(m.senderUserId!))),
          Text(m.fromMe ? 'You deleted this message' : 'This message was deleted',
              style: TextStyle(fontSize: 13.5, fontStyle: FontStyle.italic, color: t.textSecondary)),
        ]),
      );
      return Align(alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft, child: gone);
    }
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
      child: IntrinsicWidth(
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
        if (m.replyTo != null) _Quote(quote: m.replyTo!, onBlue: m.fromMe, me: me, nameOf: nameOf, onTap: onQuote),
        Align(
          alignment: Alignment.centerLeft,
          // Plain text: long-press opens the actions, which include Copy.
          child: Text.rich(_withMentions(m.text, mentionTags, fg, m.fromMe),
              style: TextStyle(fontSize: 14.5, height: 1.45, color: fg)),
        ),
        const SizedBox(height: 5),
        _Meta(m: m),
        if (failed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(unavailable ? 'Not sent · this account is unavailable' : 'Not sent · tap to try again',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFFFD0D2))),
          ),
      ])),
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
        m.status == MessageStatus.waiting
            ? 'Waiting to send'
            : '${m.editedAt != null ? 'edited · ' : ''}${remote ? '$time · tap to download' : time}',
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
  const _Notice({required this.m, required this.name, required this.onVerify, this.onCallBack});
  final LocalMessage m;
  final String name;
  final VoidCallback onVerify;
  final void Function(bool video)? onCallBack;

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
                child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: '$first added a new device',
                          style: TextStyle(fontWeight: FontWeight.w600, color: t.textPrimary)),
                      TextSpan(
                          text:
                              ' — $what, activated with a code from your administrator. It has its own safety number.'),
                    ]),
                    style: TextStyle(fontSize: 13, height: 1.5, color: t.textSecondary)),
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
      case NoticeType.call:
        return _CallNotice(m: m, onCallBack: onCallBack);
      case NoticeType.pinned:
        final who =
            m.noticeData['byMe'] == true ? 'You' : ((m.noticeData['name'] as String?)?.split(' ').first ?? first);
        return _pill(context, SkyIcons.pin, '$who ${m.noticeData['pinned'] == true ? 'pinned' : 'unpinned'} a message');
      case NoticeType.groupEvent:
        final who = m.noticeData['you'] == true ? 'You' : (m.noticeData['name'] as String? ?? 'Someone');
        final text = switch (m.noticeData['event']) {
          'group_created' => 'Your administrator created this group',
          'group_renamed' =>
            'Your administrator renamed the group from ${m.noticeData['from']} to ${m.noticeData['to']}',
          'group_member_added' => m.noticeData['you'] == true ? 'You were added to the group' : '$who was added',
          'group_member_removed' =>
            m.noticeData['you'] == true ? 'You were removed from the group' : '$who was removed',
          'group_member_left' => m.noticeData['you'] == true ? 'You left the group' : '$who left the group',
          'group_archived' => 'Your administrator closed this group',
          'group_reopened' => 'Your administrator reopened this group',
          _ => 'The group changed',
        };
        return _pill(context, SkyIcons.chat, text);
      case NoticeType.timerChanged:
        final seconds = m.noticeData['seconds'] as int?;
        final who =
            m.noticeData['byMe'] == true ? 'You' : ((m.noticeData['name'] as String?)?.split(' ').first ?? first);
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
  const _Typing({this.name});
  final String? name; // in a group, who is typing

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: name == null ? 'typing' : '$name is typing',
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
            if (name != null) ...[
              Text(name!, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
              const SizedBox(width: 8),
            ],
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
    this.hint = 'Message',
  });
  final String hint;
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hold the microphone to record.')));
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
                hintText: widget.hint,
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
  const _GroupHeader(
      {required this.peer, required this.name, required this.members, required this.timer, this.onTimer});
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

/// Highlights "@Name" for the people a message mentions (board 27).
TextSpan _withMentions(String text, List<String> tags, Color fg, bool onBlue) {
  if (tags.isEmpty) return TextSpan(text: text);
  final spans = <InlineSpan>[];
  var rest = text;
  while (rest.isNotEmpty) {
    var at = -1;
    String? tag;
    for (final t in tags) {
      final i = rest.indexOf(t);
      if (i >= 0 && (at < 0 || i < at)) {
        at = i;
        tag = t;
      }
    }
    if (at < 0) {
      spans.add(TextSpan(text: rest));
      break;
    }
    if (at > 0) spans.add(TextSpan(text: rest.substring(0, at)));
    spans.add(TextSpan(
      text: tag,
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: onBlue ? Colors.white : const Color(0xFF9DB8FF),
        backgroundColor: onBlue ? const Color(0x33FFFFFF) : const Color(0x2E6E96FF),
      ),
    ));
    rest = rest.substring(at + tag!.length);
  }
  return TextSpan(children: spans);
}

/// A reply's quote at the top of a bubble (board 27).
class _Quote extends StatelessWidget {
  const _Quote({required this.quote, required this.onBlue, required this.me, this.nameOf, this.onTap});
  final Map<String, Object?> quote;
  final bool onBlue;
  final String me;
  final String? Function(String userId)? nameOf;
  final VoidCallback? onTap; // jump to the quoted message

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final author = quote['author'] as String?;
    final who = author == me
        ? 'You'
        : ((author == null ? null : nameOf?.call(author)) ?? (quote['name'] as String?) ?? 'Message');
    return Semantics(
      button: onTap != null,
      label: onTap == null ? null : 'Go to the message from $who',
      child: GestureDetector(
        key: ValueKey('quote-${quote['id']}'),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minWidth: 160),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: onBlue ? const Color(0x47080C16) : t.ground.withValues(alpha: 0.6),
            border: Border(left: BorderSide(color: onBlue ? const Color(0xFFDDE5FC) : t.accentText, width: 3)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(who,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: onBlue ? const Color(0xFFDDE5FC) : t.accentText)),
            Text((quote['preview'] as String?) ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: onBlue ? const Color(0xFFDDE5FC) : t.textSecondary)),
          ]),
        ),
      ),
    );
  }
}

/// Long-press (or right-click) for actions, and the reactions under a bubble.
class _Actionable extends StatelessWidget {
  const _Actionable({required this.m, required this.me, required this.onActions, required this.child, this.onReact});
  final LocalMessage m;
  final String me;
  final VoidCallback onActions;
  final ValueChanged<String>? onReact;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final counts = <String, int>{};
    for (final e in m.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final mine = m.reactions[me];
    return Column(
      crossAxisAlignment: m.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(onLongPress: onActions, onSecondaryTap: onActions, child: child),
        if (counts.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: 4, left: m.fromMe ? 0 : 44, right: m.fromMe ? 8 : 0),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final e in counts.entries)
                Semantics(
                  button: onReact != null,
                  label: '${e.key} ${e.value}${e.key == mine ? ', yours' : ''}',
                  child: GestureDetector(
                    onTap: onReact == null ? null : () => onReact!(e.key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.bubbleIncoming,
                        border: Border.all(color: e.key == mine ? t.accentFill : t.border),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('${e.key} ${e.value}', style: TextStyle(fontSize: 12.5, color: t.textPrimary)),
                    ),
                  ),
                ),
            ]),
          ),
      ],
    );
  }
}

/// Board 27: the pinned messages, one at a time; tap to see the next.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.pins, required this.index, required this.onTap});
  final List<LocalMessage> pins;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final m = pins[index];
    final text = m.deleted ? 'Deleted message' : (m.isMedia ? (m.text.isEmpty ? m.mediaLabel : m.text) : m.text);
    return Semantics(
      button: true,
      label: 'Pinned message ${index + 1} of ${pins.length}: $text',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
          decoration:
              BoxDecoration(color: const Color(0xFF121A2A), border: Border(bottom: BorderSide(color: t.border))),
          child: Row(children: [
            SizedBox(
              width: 3,
              height: 30,
              child: Column(children: [
                for (var i = 0; i < pins.length; i++) ...[
                  if (i > 0) const SizedBox(height: 2),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: i == index ? t.accentText : const Color(0xFF33405C),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Pinned message ${index + 1} of ${pins.length}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.accentText)),
                Text(text,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.textPrimary)),
              ]),
            ),
            SkyIcon(SkyIcons.pin, size: 16, color: t.textSecondary, stroke: 2),
          ]),
        ),
      ),
    );
  }
}

/// Board 28: replying to, or editing, a message.
class _ComposerBanner extends StatelessWidget {
  const _ComposerBanner({required this.replyTo, required this.editing, required this.myId, required this.onCancel});
  final LocalMessage? replyTo;
  final LocalMessage? editing;
  final String myId;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final editingNow = editing != null;
    final m = editing ?? replyTo!;
    final left = MessageActions.editWindow - DateTime.now().difference(m.sentAt);
    final title = editingNow
        ? 'Editing · ${left.inMinutes < 1 ? 'under a minute' : '${left.inMinutes} minute${left.inMinutes == 1 ? '' : 's'}'} left'
        : 'Replying to ${m.fromMe ? 'yourself' : (m.senderName ?? 'them')}';
    final sub = editingNow
        ? 'Everyone in the chat will see that it was edited.'
        : (m.isMedia ? (m.text.isEmpty ? m.mediaLabel : m.text) : m.text);
    final color = editingNow ? t.caution : t.accentText;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: editingNow ? const Color(0xFF2A2210) : t.surface,
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
            Text(sub,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
          ]),
        ),
        IconButton(
          tooltip: editingNow ? 'Cancel edit' : 'Cancel reply',
          onPressed: onCancel,
          icon: SkyIcon(SkyIcons.close, size: 16, color: t.textSecondary, stroke: 2.4),
        ),
      ]),
    );
  }
}

/// Board 29: who can be mentioned (only people in this group).
class _MentionPicker extends StatelessWidget {
  const _MentionPicker({required this.members, required this.onPick});
  final List<GroupMember> members;
  final ValueChanged<GroupMember> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration:
          BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final m in members)
          InkWell(
            onTap: () => onPick(m),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(children: [
                Avatar(name: m.displayName, seed: m.userId, size: 30),
                const SizedBox(width: 12),
                Text(m.displayName, style: TextStyle(fontSize: 14, color: t.textPrimary)),
              ]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          child: Text(
              members.isEmpty ? 'Nobody in this group by that name.' : 'Only people in this group can be mentioned.',
              style: TextStyle(fontSize: 11.5, color: t.textSecondary)),
        ),
      ]),
    );
  }
}

/// Board 35: a call's line in the chat.
class _CallNotice extends StatelessWidget {
  const _CallNotice({required this.m, this.onCallBack});
  final LocalMessage m;
  final void Function(bool video)? onCallBack;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final d = m.noticeData;
    final video = d['video'] == true;
    final outgoing = d['outgoing'] == true;
    final outcome = d['outcome'] as String? ?? 'completed';
    final missed = outcome == 'missed';
    final secs = (d['seconds'] as int?) ?? 0;
    final kind = video ? 'Video call' : 'Voice call';
    final title = missed ? 'Missed ${kind.toLowerCase()}' : kind;
    final time =
        '${m.sentAt.toLocal().hour.toString().padLeft(2, '0')}:${m.sentAt.toLocal().minute.toString().padLeft(2, '0')}';
    final sub = switch (outcome) {
      'completed' => '${secs < 60 ? '$secs s' : '${secs ~/ 60} min ${secs % 60} s'} · $time',
      'noAnswer' => 'No answer · $time',
      'declined' => 'Declined · $time',
      'busy' => 'Busy · $time',
      _ => time,
    };
    final mine = outgoing;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: mine ? t.bubbleOutgoing : t.bubbleIncoming,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: missed ? const Color(0x2ED04545) : (mine ? const Color(0x33FFFFFF) : const Color(0xFF2A3550)),
              shape: BoxShape.circle,
            ),
            child: SkyIcon(video ? SkyIcons.video : SkyIcons.phoneCall,
                size: 16,
                color: missed ? const Color(0xFFFF9AA0) : (mine ? Colors.white : const Color(0xFF9DB8FF)),
                stroke: 2),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: missed ? const Color(0xFFFFB4B7) : (mine ? Colors.white : t.textPrimary))),
              const SizedBox(height: 2),
              Text(sub, style: TextStyle(fontSize: 12, color: mine ? const Color(0xFFDDE5FC) : t.textSecondary)),
            ]),
          ),
          if (missed && onCallBack != null) ...[
            const SizedBox(width: 10),
            TextButton(
              style: TextButton.styleFrom(
                backgroundColor: const Color(0x266E96FF),
                foregroundColor: const Color(0xFF9DB8FF),
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => onCallBack!(video),
              child: const Text('Call back', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Board 40: in place of the composer when a contact is unavailable. A plain
/// statement; nothing about why.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final first = name.split(' ').first;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 320),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text("$first's account is unavailable for now. Your conversation stays here.",
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary)),
        ),
        Text("You can't message or call $first right now",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
        const SizedBox(height: 4),
        Text('If the account becomes available again, you can pick up where you left off.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary)),
      ]),
    );
  }
}
