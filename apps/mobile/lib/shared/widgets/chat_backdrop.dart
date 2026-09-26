import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// Board 44: the conversation's background, in the person's chosen colour
/// with an optional faint pattern.
class ChatBackdrop extends StatelessWidget {
  const ChatBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ColoredBox(
      color: t.chatBackground,
      child: t.chatPattern == ChatPattern.none
          ? child
          : CustomPaint(painter: _Pattern(t.chatPattern, t.chatBackground), child: child),
    );
  }
}

class _Pattern extends CustomPainter {
  _Pattern(this.kind, this.background);
  final ChatPattern kind;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = (background.computeLuminance() < 0.18 ? Colors.white : const Color(0xFF101828)).withValues(alpha: 0.07);
    final p = Paint()
      ..color = ink
      ..strokeWidth = 1;
    switch (kind) {
      case ChatPattern.dots:
        for (var y = 7.0; y < size.height; y += 14) {
          for (var x = 7.0; x < size.width; x += 14) {
            canvas.drawCircle(Offset(x, y), 1.4, p);
          }
        }
      case ChatPattern.lines:
        for (var d = -size.height; d < size.width; d += 12) {
          canvas.drawLine(Offset(d, size.height), Offset(d + size.height, 0), p);
        }
      case ChatPattern.grid:
        for (var x = 0.0; x < size.width; x += 18) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
        }
        for (var y = 0.0; y < size.height; y += 18) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
        }
      case ChatPattern.none:
        break;
    }
  }

  @override
  bool shouldRepaint(_Pattern old) => old.kind != kind || old.background != background;
}
