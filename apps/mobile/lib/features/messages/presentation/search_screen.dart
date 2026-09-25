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

/// Board 30: search. Only the messages on this device, in chats you already
/// have. It never finds people (the contact graph rule), and nothing typed
/// here leaves the device: the server holds only ciphertext it cannot search.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _Hit {
  _Hit(this.chat, this.m, this.at);
  final ChatSummary chat;
  final LocalMessage m;
  final int at; // where the match starts in the text
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final Messenger messenger = ref.read(appControllerProvider).messenger!;
  final _query = TextEditingController();
  Timer? _debounce;
  String _q = '';
  List<ChatSummary> _chats = const [];
  List<_Hit> _hits = const [];
  bool _searching = false;

  static const _maxHits = 200;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(text.trim()));
  }

  Future<void> _run(String q) async {
    if (q.length < 2) {
      setState(() {
        _q = q;
        _chats = const [];
        _hits = const [];
      });
      return;
    }
    setState(() => _searching = true);
    final needle = q.toLowerCase();
    final chats = await messenger.store.chats();
    final names = [for (final c in chats) if (c.displayName.toLowerCase().contains(needle)) c];
    final hits = <_Hit>[];
    for (final c in chats) {
      for (final m in await messenger.store.messages(c.peerUserId, limit: 5000)) {
        if (m.isNotice || m.deleted || m.viewOnce) continue;
        final text = m.isMedia && m.text.isEmpty ? m.mediaLabel : m.text;
        final at = text.toLowerCase().indexOf(needle);
        if (at >= 0) hits.add(_Hit(c, m, at));
      }
    }
    hits.sort((a, b) => b.m.sentAt.compareTo(a.m.sentAt));
    if (!mounted || _query.text.trim() != q) return;
    setState(() {
      _q = q;
      _chats = names;
      _hits = hits.take(_maxHits).toList();
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(children: [
              IconButton(
                tooltip: 'Back to chats',
                onPressed: () => context.pop(),
                icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
              ),
              Expanded(
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: _changed,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search messages',
                    isDense: true,
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(11),
                      child: SkyIcon(SkyIcons.search, size: 17, color: t.textSecondary, stroke: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  style: TextStyle(fontSize: 15, color: t.textPrimary),
                ),
              ),
            ]),
          ),
          Expanded(
            child: _q.length < 2
                ? Center(
                    child: Text('Type at least two letters.', style: TextStyle(fontSize: 13.5, color: t.textSecondary)),
                  )
                : ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                    if (_chats.isNotEmpty) ...[
                      const _Header('CHATS'),
                      for (final c in _chats)
                        ListTile(
                          leading: Avatar(name: c.displayName, seed: c.peerUserId, size: 40, square: c.isGroup),
                          title: Text(c.displayName,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
                          onTap: () => context.push('/chat/${c.peerUserId}'),
                        ),
                    ],
                    _Header('MESSAGES · ${_hits.length}${_hits.length == _maxHits ? '+' : ''}'),
                    if (_hits.isEmpty && !_searching)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('No messages match.',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: t.textSecondary)),
                      ),
                    for (final h in _hits) _HitRow(hit: h, q: _q, me: messenger.me),
                  ]),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SkyIcon(SkyIcons.lock, size: 14, color: t.accentText, stroke: 2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Searches only the messages on this device, in the chats you already have. It never finds people, '
                  'and nothing you type here leaves the device.',
                  style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: t.textSecondary)),
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.q, required this.me});
  final _Hit hit;
  final String q;
  final String me;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final m = hit.m;
    final text = m.isMedia && m.text.isEmpty ? m.mediaLabel : m.text;
    // A window of text around the match.
    final start = hit.at > 30 ? hit.at - 30 : 0;
    final before = '${start > 0 ? '…' : ''}${text.substring(start, hit.at)}';
    final match = text.substring(hit.at, hit.at + q.length);
    final after = text.substring(hit.at + q.length);
    final who = m.fromMe ? 'You: ' : (m.senderName != null ? '${m.senderName!.split(' ').first}: ' : '');
    final d = m.sentAt.toLocal();
    final now = DateTime.now();
    final when = d.year == now.year && d.month == now.month && d.day == now.day
        ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : '${d.day}/${d.month}/${d.year}';
    return InkWell(
      onTap: () => context.push('/chat/${hit.chat.peerUserId}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Avatar(name: hit.chat.displayName, seed: hit.chat.peerUserId, size: 40, square: hit.chat.isGroup),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(hit.chat.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
                ),
                Text(when, style: TextStyle(fontSize: 11.5, color: t.textSecondary)),
              ]),
              const SizedBox(height: 3),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$who$before'),
                  TextSpan(
                    text: match,
                    style: const TextStyle(color: Color(0xFFF2D29B), backgroundColor: Color(0x38E8A33D)),
                  ),
                  TextSpan(text: after),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, height: 1.45, color: t.textSecondary),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
