import 'package:flutter/material.dart';

/// Person avatars are circles (design.md: group avatars, a 14px rounded
/// square, arrive in 8b). The tint is stable per person.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, required this.seed, this.size = 46});

  final String name;
  final String seed;
  final double size;

  static const _tints = [
    Color(0xFF3A63D8),
    Color(0xFF7A5AF0),
    Color(0xFFC1743A),
    Color(0xFF3F7AB8),
    Color(0xFF2C7F6B),
    Color(0xFF9A5AC4),
    Color(0xFFB45A9E),
    Color(0xFF5A6782),
  ];

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2);
    final initials = parts.map((w) => w.characters.first.toUpperCase()).join();
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: _tints[h % _tints.length], shape: BoxShape.circle),
        child: Text(
          initials.isEmpty ? '?' : initials,
          style: TextStyle(fontSize: size * 0.33, fontWeight: FontWeight.w600, color: Colors.white),
        ),
      ),
    );
  }
}
