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
import '../../updates/data/release_service.dart';
import '../../updates/presentation/update_widgets.dart';

/// Boards 2, 5, 18 and 26: every conversation and group, and every person an
/// administrator linked you to (a chat appears for them on its own). There is
/// no way to look people up and no directory; the list is the whole of who you
/// can reach. Search (board 30) looks through messages on this device only.
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final messenger = app.messenger!;
    return ListenableBuilder(
      listenable: messenger,
      builder: (context, _) => _ChatList(messenger: messenger, releases: app.releases),
    );
  }
}

class _Row {
  _Row({required this.peer, required this.name, this.chat, this.muted = false, this.archived = false, this.draft});
  final String peer;
  final String name;
  final ChatSummary? chat;
  final bool muted;
  final bool archived;
  final String? draft;
  bool get isGroup => chat?.isGroup ?? false;
}

enum _Filter { all, unread, groups }

class _ChatList extends StatefulWidget {
  const _ChatList({required this.messenger, this.releases});
  final Messenger messenger;
  final ReleaseService? releases;

  @override
  State<_ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<_ChatList> {
  _Filter _filter = _Filter.all;
  bool _archive = false;

  Messenger get messenger => widget.messenger;

  Future<List<_Row>> _rows() async {
    final chats = {for (final c in await messenger.store.chats()) c.peerUserId: c};
    final rows = <_Row>[];
    Future<_Row> row(String peer, String name, ChatSummary? chat) async => _Row(
          peer: peer,
          name: name,
          chat: chat,
          muted: await messenger.isMuted(peer),
          archived: await messenger.isArchived(peer),
          draft: await messenger.draft(peer),
        );
    for (final c in chats.values) {
      rows.add(await row(c.peerUserId, c.displayName, c));
    }
    for (final c in messenger.contacts) {
      if (!chats.containsKey(c.userId)) rows.add(await row(c.userId, c.displayName, null));
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
    return rows;
  }

  /// Board 26: long-press (right-click on a PC) a row for Mute and Archive.
  Future<void> _rowActions(_Row r) async {
    final t = context.sky;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: SkyIcon(SkyIcons.bellOff, size: 20, color: t.textPrimary),
              title: Text(r.muted ? 'Unmute' : 'Mute'),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
            ListTile(
              leading: SkyIcon(SkyIcons.archive, size: 20, color: t.textPrimary),
              title: Text(r.archived ? 'Unarchive' : 'Archive'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
          ]),
        ),
      ),
    );
    if (choice == 'mute') await messenger.setMuted(r.peer, !r.muted);
    if (choice == 'archive') await messenger.setArchived(r.peer, !r.archived);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
            child: Row(children: [
              if (_archive)
                IconButton(
                  tooltip: 'Back to chats',
                  onPressed: () => setState(() => _archive = false),
                  icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
                )
              else
                const SizedBox(width: 12),
              Text(_archive ? 'Archived' : 'Skyline',
                  style: TextStyle(
                    fontFamily: SkyFonts.display,
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    letterSpacing: 0.4,
                    color: t.textPrimary,
                  )),
              const Spacer(),
              IconButton(
                tooltip: 'Search messages',
                onPressed: () => context.push('/search'),
                icon: SkyIcon(SkyIcons.search, size: 22, color: t.textSecondary),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => context.push('/settings'),
                icon: SkyIcon(SkyIcons.settings, size: 22, color: t.textSecondary),
              ),
            ]),
          ),
          ConnectionBanner(status: messenger.connection),
          if (widget.releases != null && !_archive) UpdateBanner(releases: widget.releases!),
          Expanded(
            child: FutureBuilder<List<_Row>>(
              future: _rows(),
              builder: (context, snap) {
                final all = snap.data;
                if (all == null) return const SizedBox.shrink();
                if (all.isEmpty) return const _NoContacts();
                final archivedCount = all.where((r) => r.archived).length;
                final shown = all.where((r) {
                  if (_archive) return r.archived;
                  if (r.archived) return false;
                  return switch (_filter) {
                    _Filter.all => true,
                    _Filter.unread => (r.chat?.unread ?? 0) > 0 || (r.chat?.mentioned ?? false),
                    _Filter.groups => r.isGroup,
                  };
                }).toList();
                return RefreshIndicator(
                  onRefresh: () async {
                    await messenger.refreshContacts();
                    await messenger.refreshGroups();
                    await messenger.sync();
                  },
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    children: [
                      if (!_archive)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Row(children: [
                            for (final f in _Filter.values) ...[
                              _Chip(
                                label: switch (f) {
                                  _Filter.all => 'All',
                                  _Filter.unread => 'Unread',
                                  _Filter.groups => 'Groups',
                                },
                                selected: f == _filter,
                                onTap: () => setState(() => _filter = f),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ]),
                        ),
                      if (!_archive && archivedCount > 0 && _filter == _Filter.all)
                        ListTile(
                          leading: SizedBox(
                            width: 46,
                            child: Center(child: SkyIcon(SkyIcons.archive, size: 20, color: t.textSecondary)),
                          ),
                          title: Text('Archived',
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.textSecondary)),
                          trailing: Text('$archivedCount', style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                          onTap: () => setState(() => _archive = true),
                        ),
                      for (final r in shown)
                        Dismissible(
                          key: ValueKey('row-${r.peer}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            decoration: BoxDecoration(color: t.accentFill, borderRadius: BorderRadius.circular(14)),
                            child: Text(r.archived ? 'Unarchive' : 'Archive',
                                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                          ),
                          // Swipe to archive (a phone); the row comes back from
                          // the list itself, so nothing is really dismissed.
                          confirmDismiss: (_) async {
                            await messenger.setArchived(r.peer, !r.archived);
                            return false;
                          },
                          child: GestureDetector(
                            onLongPress: () => _rowActions(r),
                            onSecondaryTap: () => _rowActions(r),
                            child: _ChatRow(row: r, messenger: messenger),
                          ),
                        ),
                      if (shown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _archive
                                ? 'Nothing archived. Long-press a chat to archive it.'
                                : _filter == _Filter.unread
                                    ? 'Nothing unread.'
                                    : 'No groups yet. Your administrator adds you to groups.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13.5, color: t.textSecondary),
                          ),
                        ),
                    ],
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
                Flexible(
                  child: Text(
                    _archive
                        ? 'Archived chats come back when someone writes, unless muted'
                        : 'Directory managed by your organization · ${messenger.contacts.length} '
                            '${messenger.contacts.length == 1 ? 'contact' : 'contacts'}',
                    style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? t.accentFill : t.surface,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : t.textSecondary)),
        ),
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
    final mentioned = chat?.mentioned ?? false;
    final typing = messenger.isTyping(row.peer);
    final draft = row.draft;
    // Board 40: a suspended contact's row is greyed and says so.
    final unavailable = !row.isGroup && (messenger.contact(row.peer)?.suspended ?? false);
    final preview = unavailable
        ? 'Unavailable'
        : typing
            ? 'typing…'
            : draft ??
                (chat == null || chat.lastText.isEmpty
                    ? 'Say hello — messages are end-to-end encrypted'
                    : chat.lastText);
    // One clear sentence for screen readers, instead of every text in the row.
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: '${row.name}${row.muted ? ', muted' : ''}. ${draft != null ? 'Draft: ' : ''}$preview'
          '${mentioned ? '. You were mentioned' : ''}${unread > 0 ? '. $unread unread' : ''}',
      onTap: () => context.push('/chat/${row.peer}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/chat/${row.peer}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Opacity(
                opacity: unavailable ? 0.45 : 1, child: Avatar(name: row.name, seed: row.peer, square: row.isGroup)),
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
                  if (row.muted) ...[
                    const SizedBox(width: 6),
                    SkyIcon(SkyIcons.bellOff, size: 14, color: t.textSecondary, stroke: 2),
                  ],
                  if (chat?.timerSeconds != null) ...[
                    const SizedBox(width: 6),
                    SkyIcon(SkyIcons.clock, size: 13, color: t.caution, stroke: 2.2),
                  ],
                ]),
                const SizedBox(height: 3),
                Text.rich(
                  TextSpan(children: [
                    if (draft != null && !typing)
                      TextSpan(text: 'Draft: ', style: TextStyle(fontWeight: FontWeight.w600, color: t.caution)),
                    TextSpan(text: preview),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: typing ? t.accentText : t.textSecondary,
                    fontStyle: chat == null && draft == null ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (chat?.lastAt != null)
                Text(_when(chat!.lastAt!),
                    style: TextStyle(fontSize: 11.5, color: unread > 0 && !row.muted ? t.accentText : t.textSecondary)),
              if (unread > 0 || mentioned) ...[
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 21),
                  height: 21,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: row.muted ? const Color(0xFF45526E) : t.accentFill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(mentioned ? '@' : '$unread',
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
  if (diff < 7) {
    return const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][local.weekday - 1];
  }
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
          Text('There is no way to look people up in Skyline, and no directory. That is on purpose.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.55, color: t.textSecondary)),
        ]),
      ),
    );
  }
}
