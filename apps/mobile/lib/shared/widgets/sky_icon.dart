import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Skyline's icons: stroke SVG at 1.8-2.1 width, drawn from the same paths as
/// the approved design boards (design.md: no icon fonts, no emoji).
enum SkyIcons {
  back('<path d="M14.5 5 8 12l6.5 7"/>'),
  lock('<rect x="4" y="10.5" width="16" height="10.5" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>'),
  shield('<path d="M12 2.5 4.5 5.8v5.4c0 4.6 3.1 8.4 7.5 9.8 4.4-1.4 7.5-5.2 7.5-9.8V5.8Z"/><path d="M7.6 12.6h8.8"/><path d="M9.9 12.6 12 9.4l2.1 3.2"/>'),
  shieldBlocked('<path d="M12 2.5 4.5 5.8v5.4c0 4.6 3.1 8.4 7.5 9.8 4.4-1.4 7.5-5.2 7.5-9.8V5.8Z"/><path d="m9.5 9.5 5 5"/><path d="m14.5 9.5-5 5"/>'),
  check('<path d="m4.5 12.5 5 5 10-11"/>'),
  tickOne('<path d="m5 12.5 4.5 4.5 9.5-10"/>'),
  tickTwo('<path d="m2.5 12.5 4 4 8-9"/><path d="m11.5 15.5 1 1 8-9"/>'),
  clock('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.8V12l2.8 1.8"/>'),
  alertCircle('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v5.5"/><path d="M12 16.5h.01"/>'),
  warn('<path d="M12 3.5 21 19.5H3Z"/><path d="M12 9.5v4"/><path d="M12 16.6h.01"/>'),
  send('<path d="M4 12 20 4l-6 16-2.5-6.5Z"/><path d="m11.5 13.5 3-3"/>'),
  monitor('<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M8.5 20h7"/><path d="M12 16.5V20"/>'),
  phone('<rect x="6.5" y="2.5" width="11" height="19" rx="2.6"/><path d="M10.5 18.3h3"/>'),
  pen('<path d="M16.2 4.3a2.1 2.1 0 0 1 3 3L9.8 16.7l-4 1 1-4Z"/>'),
  chat('<path d="M20 11.5c0 4-3.6 7.2-8 7.2a9 9 0 0 1-2.6-.4L5 19.5l1.2-3.2A6.9 6.9 0 0 1 4 11.5c0-4 3.6-7.2 8-7.2s8 3.2 8 7.2Z"/>'),
  settings('<circle cx="12" cy="12" r="3"/><path d="M19.1 14.2a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1v.3a2 2 0 1 1-4 0v-.2a1.6 1.6 0 0 0-2.8-1.1l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0-1.1-2.7H3a2 2 0 1 1 0-4h.2a1.6 1.6 0 0 0 1.1-2.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 2.7-1.1V3a2 2 0 1 1 4 0v.2a1.6 1.6 0 0 0 2.8 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0 1.1 2.7h.3a2 2 0 1 1 0 4h-.2a1.6 1.6 0 0 0-1.5 1.1Z"/>'),
  wifiOff('<path d="M2.5 8.8a15 15 0 0 1 19 0"/><path d="M5.8 12.4a10 10 0 0 1 12.4 0"/><path d="M9.2 15.9a5 5 0 0 1 5.6 0"/><path d="M12 19.5h.01"/><path d="m3 3 18 18"/>'),
  refresh('<path d="M20 12a8 8 0 1 1-2.3-5.7"/><path d="M20 4.5v4.2h-4.2"/>'),
  graph('<circle cx="5.5" cy="6" r="2.5"/><circle cx="18.5" cy="6" r="2.5"/><circle cx="12" cy="18" r="2.5"/><path d="M8 6h8" stroke-dasharray="1.5 2.2"/><path d="M6.6 8.2 11 15.8" stroke-dasharray="1.5 2.2"/><path d="M17.4 8.2 13 15.8" stroke-dasharray="1.5 2.2"/>'),
  chevron('<path d="m9.5 5 6.5 7-6.5 7"/>'),
  // Media (boards 20-22).
  plus('<path d="M12 5.5v13M5.5 12h13"/>'),
  mic('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0"/><path d="M12 18v3"/>'),
  photo('<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.8"/><path d="m21 16-5-5-8 8.5"/>'),
  camera('<path d="M4 8.5h3l1.8-2.5h6.4L17 8.5h3v10H4Z"/><circle cx="12" cy="13.5" r="3.4"/>'),
  video('<rect x="2.8" y="6.5" width="12.5" height="11" rx="2.6"/><path d="m15.3 11.3 5.9-3.3v8l-5.9-3.3Z"/>'),
  file('<path d="M13.5 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8.5Z"/><path d="M13.5 3v5.5H19"/>'),
  download('<path d="M12 4v11"/><path d="m7 10.5 5 5 5-5"/><path d="M5 19.5h14"/>'),
  play('<path d="M7 4.5v15l12-7.5Z"/>'),
  pause('<path d="M8 5v14"/><path d="M16 5v14"/>'),
  close('<path d="M6 6l12 12M18 6 6 18"/>'),
  // Message actions (board 28).
  reply('<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>'),
  copy('<path d="M9 9h10.5v10.5H9Z"/><path d="M15 9V4.5H4.5V15H9"/>'),
  pin('<path d="M9 4h6l-1 6 3 3H7l3-3Z"/><path d="M12 16v4.5"/>'),
  info('<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5"/><path d="M12 7.8h.01"/>'),
  trash('<path d="M4.5 6.5h15"/><path d="M9.5 6.5V4.5h5v2"/><path d="m6.5 6.5 1 13h9l1-13"/>'),
  search('<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4.5 4.5"/>'),
  archive('<rect x="3.5" y="4.5" width="17" height="4.5" rx="1.2"/><path d="M5 9v9.5a1.5 1.5 0 0 0 1.5 1.5h11a1.5 1.5 0 0 0 1.5-1.5V9"/><path d="M10 13h4"/>'),
  bellOff('<path d="M18 8.5a6 6 0 0 0-11.2-3"/><path d="M6 8.5c0 7-3 9-3 9h13"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/><path d="m3 3 18 18"/>');

  const SkyIcons(this.paths);
  final String paths;
}

class SkyIcon extends StatelessWidget {
  const SkyIcon(this.icon, {super.key, this.size = 20, required this.color, this.stroke = 1.9, this.filled = false});

  final SkyIcons icon;
  final double size;
  final Color color;
  final double stroke;
  final bool filled; // solid shapes (the play triangle)

  @override
  Widget build(BuildContext context) {
    final hex = '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="${filled ? hex : 'none'}" '
        'stroke="$hex" stroke-opacity="${color.a}" stroke-width="$stroke" '
        'stroke-linecap="round" stroke-linejoin="round">${icon.paths}</svg>';
    return ExcludeSemantics(child: SvgPicture.string(svg, width: size, height: size));
  }
}
