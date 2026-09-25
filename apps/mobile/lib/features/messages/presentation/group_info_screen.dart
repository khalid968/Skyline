import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../data/messenger.dart';
import '../domain/models.dart';
import 'timer_sheet.dart';

/// Board 29: a group's info. Timer, mute, media, members, and Leave (only an
/// administrator can add you back). Members you are not linked to are marked:
/// sharing a group does not let you message them one to one.
class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({super.key, required this.groupId});
  final String groupId;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  late final Messenger messenger = ref.read(appControllerProvider).messenger!;

  Future<void> _leave(String name) async {
    final t = context.sky;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('Leave $name?'),
        content: const Text(
          'You will stop getting its messages, and the group is told you left. Only an administrator can add you '
          'back. The messages already on this device stay until you delete the chat.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: t.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final snack = ScaffoldMessenger.of(context);
    try {
      await messenger.leaveGroup(widget.groupId);
      if (mounted) context.pop();
    } on Object {
      snack.showSnackBar(const SnackBar(content: Text('Could not leave right now. Try again when you are online.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListenableBuilder(
      listenable: messenger,
      builder: (context, _) {
        final g = messenger.group(widget.groupId);
        return FutureBuilder<(ChatSummary?, bool)>(
          future: (() async => (await messenger.store.chat(widget.groupId), await messenger.isMuted(widget.groupId)))(),
          builder: (context, snap) {
            final chat = snap.data?.$1;
            final muted = snap.data?.$2 ?? false;
            final name = g?.name ?? chat?.displayName ?? '';
            final canAct = g != null && !g.archived && !(chat?.left ?? false);
            final members = [...?g?.members]
              ..sort((a, b) => a.you ? -1 : (b.you ? 1 : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase())));
            return Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  tooltip: 'Back to the chat',
                  onPressed: () => context.pop(),
                  icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
                ),
              ),
              body: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
                Center(child: Avatar(name: name, seed: widget.groupId, size: 76, square: true)),
                const SizedBox(height: 10),
                Center(
                  child: Text(name,
                      style: TextStyle(
                          fontFamily: SkyFonts.display, fontSize: 21, fontWeight: FontWeight.w700, color: t.textPrimary)),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    [
                      if (g?.description?.isNotEmpty ?? false) g!.description!,
                      g == null
                          ? 'You are no longer in this group'
                          : 'Set up by your administrator · ${g.members.length} members',
                    ].join('\n'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: t.textSecondary),
                  ),
                ),
                const SizedBox(height: 16),
                _Card(children: [
                  _Row(
                    icon: SkyIcons.clock,
                    iconColor: t.caution,
                    label: 'Disappearing messages',
                    value: chat?.timerSeconds == null ? 'Off' : timerLabel(chat!.timerSeconds!),
                    onTap: !canAct
                        ? null
                        : () async {
                            final r = await showTimerSheet(context, current: chat?.timerSeconds, peerName: name);
                            if (r.seconds == -1 || r.seconds == chat?.timerSeconds) return;
                            await messenger.setTimer(widget.groupId, r.seconds);
                          },
                  ),
                  _Row(
                    icon: SkyIcons.bellOff,
                    label: 'Mute notifications',
                    trailing: Switch(
                      value: muted,
                      onChanged: (v) => messenger.setMuted(widget.groupId, v),
                    ),
                  ),
                  _Row(
                    icon: SkyIcons.photo,
                    label: 'Media, files and voice',
                    onTap: () => context.push('/chat/${widget.groupId}/media'),
                  ),
                ]),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 6),
                  child: Text('MEMBERS · ${members.length}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: t.textSecondary)),
                ),
                _Card(children: [
                  for (final m in members)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(children: [
                        Avatar(name: m.you ? 'You' : m.displayName, seed: m.userId, size: 34),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(m.you ? 'You' : m.displayName, style: TextStyle(fontSize: 14, color: t.textPrimary)),
                        ),
                        if (!m.you && m.suspended)
                          Text('unavailable', style: TextStyle(fontSize: 12, color: t.textSecondary))
                        else if (!m.you && !m.linked)
                          Text('not linked to you', style: TextStyle(fontSize: 12, color: t.textSecondary))
                        else if (!m.you)
                          IconButton(
                            tooltip: 'Message ${m.displayName}',
                            onPressed: () => context.push('/chat/${m.userId}'),
                            icon: SkyIcon(SkyIcons.chat, size: 18, color: t.textSecondary),
                          ),
                      ]),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                  child: Text(
                    'You can message a member directly only if your administrator has linked you.',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: t.textSecondary),
                  ),
                ),
                if (canAct) ...[
                  const SizedBox(height: 20),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF9AA0),
                      side: const BorderSide(color: Color(0xFF8C2F3A)),
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: () => unawaited(_leave(name)),
                    child: const Text('Leave group'),
                  ),
                ],
              ]),
            );
          },
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.border),
          children[i],
        ],
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, this.value, this.onTap, this.trailing, this.iconColor});
  final SkyIcons icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: trailing != null ? 4 : 13),
        child: Row(children: [
          SkyIcon(icon, size: 19, color: iconColor ?? t.textSecondary),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: TextStyle(fontSize: 14.5, color: t.textPrimary))),
          if (value != null) Text(value!, style: TextStyle(fontSize: 13, color: t.textSecondary)),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}
