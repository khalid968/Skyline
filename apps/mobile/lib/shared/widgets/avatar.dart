import 'package:flutter/material.dart';

import '../../features/profile/data/profile_photos.dart';

/// Makes profile photos (Phase 14d) available to every [Avatar] below it;
/// avatars rebuild when a photo arrives, changes or is removed.
class ProfilePhotoScope extends InheritedNotifier<ProfilePhotos> {
  const ProfilePhotoScope({super.key, required ProfilePhotos? photos, required super.child})
      : super(notifier: photos);

  static ProfilePhotos? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProfilePhotoScope>()?.notifier;
}

/// Person avatars are circles; group avatars are rounded squares (design.md,
/// board 26). The tint is stable per person or group.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, required this.seed, this.size = 46, this.square = false});

  final String name;
  final String seed;
  final double size;
  final bool square;

  /// The tint for [seed], also used for a person's name in a group.
  static Color tintFor(String seed) {
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _tints[h % _tints.length];
  }

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
    // A person's own photo, when we have it (never for groups).
    final photo = square ? null : ProfilePhotoScope.of(context)?.photoOf(seed);
    if (photo != null) {
      final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
      return ExcludeSemantics(
        child: ClipOval(
          child: Image.memory(photo,
              width: size, height: size, fit: BoxFit.cover, cacheWidth: px, gaplessPlayback: true),
        ),
      );
    }
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: square
            ? BoxDecoration(color: _tints[h % _tints.length], borderRadius: BorderRadius.circular(size * 0.3))
            : BoxDecoration(color: _tints[h % _tints.length], shape: BoxShape.circle),
        child: Text(
          initials.isEmpty ? '?' : initials,
          style: TextStyle(fontSize: size * 0.33, fontWeight: FontWeight.w600, color: Colors.white),
        ),
      ),
    );
  }
}
