import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/connection_banner.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../../messages/domain/models.dart';

/// Boards 2, 5 and 18: every conversation, and every person an administrator
/// linked you to (a chat appears for them on its own). There is no search and
/// no directory; the list is the whole of who you can reach.
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messenger = ref.watch(appControllerProvider).messenger!;
    return ListenableBuilder(
      listenable: messenger,
      builder: (context, _) => _ChatList(messenger: messenger),
    );
  }
}

class _Row {
  _Row({required this.peer, required this.name, this.chat});
  final String peer;
  final String name;
  final ChatSummary? chat;
}

class _ChatList extends StatelessWidget {
  const _ChatList({required this.messenger});
  final Messenger messenger;

  Future<List<_Row>> _rows() async {
    final chats = {for (final c in await messenger.store.chats()) c.peerUserId: c};
    final rows = <_Row>[];
    for (final c in chats.values) {
      rows.add(_Row(peer: c.peerUserId, name: c.displayName, chat: c));
    }
    for (final c in messenger.contacts) {
      if (!chats.containsKey(c.userId)) rows.add(_Row(peer: c.userId, name: c.displayName));
    }
    // Conversations with activity first, newest on top; then the rest by name.
    rows.sort((a, b) {
      final at = a.chat?.lastAt;
      final bt = b.chat?.lastAt;
      if (at != null && bt != null) return bt.compareTo(at);
      if (at != null) return -1;
      if (bt != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    // People no longer linked to us keep their history but cannot be written to.
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              Text('Skyline',
                  style: TextStyle(
                    fontFamily: SkyFonts.display,
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    letterSpacing: 0.4,
                    color: t.textPrimary,
                  )),
              const Spacer(),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => context.push('/settings'),
                icon: SkyIcon(SkyIcons.settings, size: 22, color: t.textSecondary),
              ),
            ]),
          ),
          ConnectionBanner(status: messenger.connection),
          Expanded(
            child: FutureBuilder<List<_Row>>(
              future: _rows(),
              builder: (context, snap) {
                final rows = snap.data;
                if (rows == null) return const SizedBox.shrink();
                if (rows.isEmpty) return const _NoContacts();
                return RefreshIndicator(
                  onRefresh: () async {
                    await messenger.refreshContacts();
                    await messenger.sync();
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _ChatRow(row: rows[i], messenger: messenger),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
            child: SafeArea(
              top: false,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SkyIcon(SkyIcons.lock, size: 13, color: t.textSecondary, stroke: 2),
                const SizedBox(width: 7),
                Text('Directory managed by your organization · ${messenger.contacts.length} contacts',
                    style: TextStyle(fontSize: 11.5, color: t.textSecondary)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.row, required this.messenger});
  final _Row row;
  final Messenger messenger;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final chat = row.chat;
    final unread = chat?.unread ?? 0;
    final typing = messenger.isTyping(row.peer);
    final preview = typing
        ? 'typing…'
        : (chat == null || chat.lastText.isEmpty ? 'Say hello — messages are end-to-end encrypted' : chat.lastText);
    // One clear sentence for screen readers, instead of every text in the row.
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: '${row.name}. $preview${unread > 0 ? '. $unread unread' : ''}',
      onTap: () => context.push('/chat/${row.peer}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/chat/${row.peer}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Avatar(name: row.name, seed: row.peer),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
                  ),
                  if (chat?.timerSeconds != null) ...[
                    const SizedBox(width: 6),
                    SkyIcon(SkyIcons.clock, size: 13, color: t.caution, stroke: 2.2),
                  ],
                ]),
                const SizedBox(height: 3),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: typing ? t.accentText : t.textSecondary,
                      fontStyle: chat == null ? FontStyle.italic : FontStyle.normal,
                    )),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (chat?.lastAt != null)
                Text(_when(chat!.lastAt!),
                    style: TextStyle(fontSize: 11.5, color: unread > 0 ? t.accentText : t.textSecondary)),
              if (unread > 0) ...[
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 21),
                  height: 21,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: t.accentFill, borderRadius: BorderRadius.circular(999)),
                  child: Text('$unread',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ],
            ]),
          ]),
        ),
      ),
    );
  }
}

String _when(DateTime at) {
  final now = DateTime.now();
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][local.weekday - 1];
  return '${local.day}/${local.month}/${local.year}';
}

/// Board 18.
class _NoContacts extends StatelessWidget {
  const _NoContacts();

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 84,
            height: 84,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
              borderRadius: BorderRadius.circular(26),
            ),
            child: SkyIcon(SkyIcons.graph, size: 38, color: t.accentText, stroke: 1.6),
          ),
          const SizedBox(height: 18),
          Text('No one to talk to yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: SkyFonts.display,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: t.textPrimary,
              )),
          const SizedBox(height: 18),
          Text(
            'Your administrator decides who you can reach. As soon as they link you to someone, the conversation appears here on its own.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14.5, height: 1.6, color: t.textSecondary),
          ),
          const SizedBox(height: 18),
          Text('There is no search and no directory in Skyline. That is on purpose.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.55, color: t.textSecondary)),
        ]),
      ),
    );
  }
}
