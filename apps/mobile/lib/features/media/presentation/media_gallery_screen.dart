import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../../messages/domain/models.dart';
import 'media_bubble.dart';
import 'media_format.dart';

enum _Tab { media, files, voice }

/// One file in the gallery: which message, which item in it.
typedef _Entry = ({LocalMessage m, int index, MediaInfo info});

const _months = [
  'JANUARY',
  'FEBRUARY',
  'MARCH',
  'APRIL',
  'MAY',
  'JUNE',
  'JULY',
  'AUGUST',
  'SEPTEMBER',
  'OCTOBER',
  'NOVEMBER',
  'DECEMBER',
];
const _short = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Board 25: every photo, video, document and voice message in a chat that
/// is on this device. Disappearing and view-once messages never appear.
class MediaGalleryScreen extends ConsumerStatefulWidget {
  const MediaGalleryScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends ConsumerState<MediaGalleryScreen> {
  late final Messenger messenger = ref.read(appControllerProvider).messenger!;
  _Tab _tab = _Tab.media;

  Future<List<_Entry>> _load() async {
    final entries = <_Entry>[];
    for (final m in await messenger.store.messages(widget.peer, limit: 5000)) {
      if (!m.isMedia || m.viewOnce || m.timerSeconds != null || m.status == MessageStatus.failed) continue;
      for (var i = 0; i < m.items.length; i++) {
        final info = m.items[i];
        if (info.state == MediaState.expired || info.state == MediaState.failed || info.burned) continue;
        entries.add((m: m, index: i, info: info));
      }
    }
    return entries; // newest first
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final name = messenger.contact(widget.peer)?.displayName ?? '';
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([messenger, messenger.media]),
          builder: (context, _) => FutureBuilder<List<_Entry>>(
            future: _load(),
            builder: (context, snap) {
              final all = snap.data ?? const <_Entry>[];
              bool inTab(_Entry e) => switch (_tab) {
                    _Tab.media => e.info.kind == MediaKind.photo || e.info.kind == MediaKind.video,
                    _Tab.files => e.info.kind == MediaKind.file,
                    _Tab.voice => e.info.kind == MediaKind.voice,
                  };
              final shown = all.where(inTab).toList();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 14, 6),
                  child: Row(children: [
                    IconButton(
                      tooltip: 'Back to the chat',
                      onPressed: () => context.pop(),
                      icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
                    ),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Media',
                          style: TextStyle(
                              fontFamily: SkyFonts.display,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: t.textPrimary)),
                      Text('Shared with $name', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                    ]),
                  ]),
                ),
                _Tabs(current: _tab, onPick: (x) => setState(() => _tab = x)),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text(snap.hasData ? 'Nothing here yet.' : '',
                              style: TextStyle(fontSize: 13.5, color: t.textSecondary)))
                      : switch (_tab) {
                          _Tab.media => _grid(context, shown),
                          _Tab.files => _files(context, shown),
                          _Tab.voice => _voices(context, shown),
                        },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                  child: Text(
                    'Only what is on this device, and still in the chat. Disappearing and view-once messages never '
                    'appear here.',
                    style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
                  ),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  String _monthOf(DateTime d) {
    final now = DateTime.now();
    final l = d.toLocal();
    return l.year == now.year ? _months[l.month - 1] : '${_months[l.month - 1]} ${l.year}';
  }

  String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.day} ${_short[l.month - 1]}';
  }

  Widget _grid(BuildContext context, List<_Entry> entries) {
    final t = context.sky;
    final byMonth = <String, List<_Entry>>{};
    for (final e in entries) {
      byMonth.putIfAbsent(_monthOf(e.m.sentAt), () => []).add(e);
    }
    return CustomScrollView(slivers: [
      for (final month in byMonth.entries) ...[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          sliver: SliverToBoxAdapter(
            child: Text(month.key,
                style:
                    TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: t.textSecondary)),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          sliver: SliverGrid.count(
            crossAxisCount: 3,
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
            childAspectRatio: 0.9,
            children: [for (final e in month.value) _tile(context, e)],
          ),
        ),
      ],
    ]);
  }

  Widget _tile(BuildContext context, _Entry e) {
    final transfer = messenger.media.transfer(Messenger.transferKey(e.m.id, e.index));
    final remote = e.info.state == MediaState.remote;
    return Semantics(
      button: true,
      label: '${e.info.label}, ${_date(e.m.sentAt)}${remote ? ', tap to download' : ''}',
      child: GestureDetector(
        onTap: () => openMediaItem(context, messenger, e.m, e.index),
        child: Stack(fit: StackFit.expand, children: [
          MediaThumbnail(info: e.info, media: messenger.media),
          if (e.info.kind == MediaKind.video && e.info.durationMs != null)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xA6080C16), borderRadius: BorderRadius.circular(999)),
                child: Text(formatDuration(e.info.durationMs),
                    style: const TextStyle(fontSize: 10.5, color: Color(0xFFE3E8F2))),
              ),
            ),
          if (transfer != null)
            ColoredBox(
              color: const Color(0x73080C16),
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.6, value: transfer.fraction, color: Colors.white),
                ),
              ),
            )
          else if (remote)
            const ColoredBox(
              color: Color(0x59080C16),
              child: Center(child: SkyIcon(SkyIcons.download, size: 20, color: Colors.white, stroke: 2.2)),
            ),
        ]),
      ),
    );
  }

  Widget _files(BuildContext context, List<_Entry> entries) {
    final t = context.sky;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      itemCount: entries.length,
      separatorBuilder: (context, index) => Divider(height: 1, color: t.border),
      itemBuilder: (context, i) {
        final e = entries[i];
        final transfer = messenger.media.transfer(Messenger.transferKey(e.m.id, e.index));
        final ext = e.info.name.contains('.') ? e.info.name.split('.').last.toUpperCase() : 'FILE';
        final meta = transfer != null
            ? 'Downloading ${formatProgress(transfer.done, transfer.total)}'
            : e.info.state == MediaState.remote
                ? '${formatBytes(e.info.size)} · $ext · tap to download · ${_date(e.m.sentAt)}'
                : '${formatBytes(e.info.size)} · $ext · ${_date(e.m.sentAt)}';
        return InkWell(
          onTap: () => openMediaItem(context, messenger, e.m, e.index),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFF2A3550), borderRadius: BorderRadius.circular(10)),
                child: const SkyIcon(SkyIcons.file, size: 18, color: Color(0xFF9DB8FF)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.info.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
                  const SizedBox(height: 3),
                  Text(meta, style: TextStyle(fontSize: 12, color: t.textSecondary)),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _voices(BuildContext context, List<_Entry> entries) {
    final t = context.sky;
    final name = messenger.contact(widget.peer)?.displayName ?? '';
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      itemCount: entries.length,
      separatorBuilder: (context, index) => Divider(height: 1, color: t.border),
      itemBuilder: (context, i) {
        final e = entries[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('${e.m.fromMe ? 'You' : name} · ${_date(e.m.sentAt)}',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
            ),
            VoiceRow(key: ValueKey(e.m.id), m: e.m, messenger: messenger, onSurface: true),
          ]),
        );
      },
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.current, required this.onPick});
  final _Tab current;
  final ValueChanged<_Tab> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    const labels = {_Tab.media: 'Photos & videos', _Tab.files: 'Files', _Tab.voice: 'Voice'};
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (final tab in _Tab.values)
          Expanded(
            child: Semantics(
              selected: tab == current,
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => onPick(tab),
                child: Container(
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tab == current ? const Color(0xFF2A3550) : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(labels[tab]!,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: tab == current ? t.textPrimary : t.textSecondary)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
