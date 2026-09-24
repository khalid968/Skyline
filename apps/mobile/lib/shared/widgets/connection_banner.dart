import 'package:flutter/material.dart';

import '../../core/realtime/realtime_client.dart';
import '../../core/theme/tokens.dart';
import 'sky_icon.dart';

/// Board 19: shown only when not connected. Messages written meanwhile wait on
/// the phone, encrypted, and send by themselves on reconnect.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.status, this.waiting = 0});

  final ConnectionStatus status;
  final int waiting;

  @override
  Widget build(BuildContext context) {
    if (status == ConnectionStatus.online) return const SizedBox.shrink();
    final t = context.sky;
    final offline = status == ConnectionStatus.offline;
    final title = offline ? 'You are offline' : 'Connecting…';
    final text = offline
        ? 'Messages you write wait here, encrypted, and send by themselves when you reconnect.'
        : 'Fetching anything that arrived while you were away.';
    final bg = offline ? const Color(0xFF2A2112) : t.surface;
    final line = offline ? const Color(0xFF5E4A22) : t.border;
    final fg = offline ? const Color(0xFFF7DDB0) : t.textPrimary;
    final sub = offline ? const Color(0xFFD8BE8E) : t.textSecondary;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border(top: BorderSide(color: line), bottom: BorderSide(color: line)),
        ),
        child: Row(children: [
          SkyIcon(offline ? SkyIcons.wifiOff : SkyIcons.refresh,
              size: 17, color: offline ? const Color(0xFFF0C27A) : t.accentText, stroke: 2),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: fg)),
              const SizedBox(height: 2),
              Text(
                waiting > 0 ? '$text $waiting waiting to send.' : text,
                style: TextStyle(fontSize: 12, height: 1.4, color: sub),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
