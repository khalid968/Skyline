import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/messages/data/local_store.dart';
import 'app_theme.dart';
import 'tokens.dart';

/// Board 44: the person's theme, colour and chat background. Kept on this
/// device only (in the vault's settings), never sent anywhere.
enum ThemeChoice { phone, midnight, black, light, sand }

class AccentPreset {
  const AccentPreset(this.id, this.name, this.fill, {this.textDark, this.textLight});
  final String id;
  final String name;
  final Color fill;

  /// Link and label colour on dark and light themes; derived when absent.
  final Color? textDark;
  final Color? textLight;
}

class BackgroundPreset {
  const BackgroundPreset(this.id, this.name, this.color);
  final String id;
  final String name;
  final Color? color; // null: the theme's own
}

abstract final class AppearancePresets {
  static const accents = [
    AccentPreset('sky', 'Sky blue', Color(0xFF3A63D8), textDark: Color(0xFF6E96FF), textLight: Color(0xFF3A63D8)),
    AccentPreset('ocean', 'Ocean', Color(0xFF0B6FA4)),
    AccentPreset('lagoon', 'Lagoon', Color(0xFF0E7490)),
    AccentPreset('navy', 'Navy', Color(0xFF1E3A8A)),
    AccentPreset('indigo', 'Indigo', Color(0xFF4F46E5)),
    AccentPreset('violet', 'Violet', Color(0xFF6A4BD6)),
    AccentPreset('lavender', 'Lavender', Color(0xFFA898F0)),
    AccentPreset('plum', 'Plum', Color(0xFF8E3FA8)),
    AccentPreset('magenta', 'Magenta', Color(0xFFB83280)),
    AccentPreset('rose', 'Rose', Color(0xFFC0406A)),
    AccentPreset('blush', 'Blush', Color(0xFFE89AB4)),
    AccentPreset('cocoa', 'Cocoa', Color(0xFF7A5236)),
    AccentPreset('slate', 'Slate', Color(0xFF475569)),
    AccentPreset('graphite', 'Graphite', Color(0xFF3F3F46)),
  ];

  static const backgrounds = [
    BackgroundPreset('theme', 'Theme', null),
    BackgroundPreset('night', 'Night', Color(0xFF101A33)),
    BackgroundPreset('deep', 'Deep sea', Color(0xFF0D2A2E)),
    BackgroundPreset('plum', 'Plum', Color(0xFF24142E)),
    BackgroundPreset('espresso', 'Espresso', Color(0xFF22170F)),
    BackgroundPreset('mist', 'Mist', Color(0xFFE6EEF7)),
    BackgroundPreset('stone', 'Stone', Color(0xFFE9E6E1)),
    BackgroundPreset('blush', 'Blush', Color(0xFFF6E7EA)),
    BackgroundPreset('mint', 'Mint', Color(0xFFE4F1EC)),
  ];

  static const black = SkylineTokens(
    ground: Color(0xFF000000),
    surface: Color(0xFF111114),
    surfaceRaised: Color(0xFF1B1B1F),
    border: Color(0xFF232327),
    textPrimary: Color(0xFFF2F5FA),
    textSecondary: Color(0xFF9097A3),
    accentFill: Color(0xFF3A63D8),
    accentText: Color(0xFF6E96FF),
    verified: Color(0xFF34C08A),
    caution: Color(0xFFE8A33D),
    danger: Color(0xFFD04545),
    bubbleIncoming: Color(0xFF1B1B1F),
    bubbleOutgoing: Color(0xFF3A63D8),
  );

  static const sand = SkylineTokens(
    ground: Color(0xFFF6F1E9),
    surface: Color(0xFFFFFCF7),
    surfaceRaised: Color(0xFFFBF7F0),
    border: Color(0xFFE4DACA),
    textPrimary: Color(0xFF2A2118),
    textSecondary: Color(0xFF6B5E4E),
    accentFill: Color(0xFF3A63D8),
    accentText: Color(0xFF3A63D8),
    verified: Color(0xFF14774F),
    caution: Color(0xFF8A5A0B),
    danger: Color(0xFFA32020),
    bubbleIncoming: Color(0xFFFFFCF7),
    bubbleOutgoing: Color(0xFF3A63D8),
  );
}

/// Colour arithmetic for readable text on any colour (WCAG contrast).
abstract final class ColourMath {
  static double luminance(Color c) => c.computeLuminance();

  static double contrast(Color a, Color b) {
    final x = luminance(a), y = luminance(b);
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
  }

  static const dark = Color(0xFF101828);

  /// White, or near-black when white would not reach 4.5:1 (black for the
  /// few mid tones where even near-black falls just short).
  static Color on(Color fill) => contrast(fill, Colors.white) >= 4.5
      ? Colors.white
      : contrast(fill, dark) >= 4.5
          ? dark
          : Colors.black;

  /// [c] moved towards white or black until it reads on [ground] (4.5:1).
  static Color readableOn(Color c, Color ground) {
    final towards = luminance(ground) < 0.4 ? Colors.white : Colors.black;
    for (var t = 0.0; t <= 1.0; t += 0.05) {
      final x = Color.lerp(c, towards, t)!;
      if (contrast(x, ground) >= 4.5) return x;
    }
    return towards;
  }

  /// Close to the security colours' hues (green, amber, red)? Board 44 tells
  /// the person those notices keep their icon and words.
  static bool nearSecurityHue(Color c) {
    final h = HSLColor.fromColor(c);
    if (h.saturation < 0.35) return false;
    final hue = h.hue;
    return (hue >= 90 && hue <= 165) || (hue >= 28 && hue <= 52) || hue < 12 || hue > 350;
  }

  static String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static Color? parse(Object? v) => v is int ? Color(0xFF000000 | (v & 0xFFFFFF)) : null;
}

/// The saved choices, and the themes they make.
class Appearance extends ChangeNotifier {
  ThemeChoice theme = ThemeChoice.phone;
  String accent = 'sky'; // a preset id, or 'custom'
  Color customAccent = const Color(0xFFE07A2F);
  String background = 'theme'; // a preset id, or 'custom'
  Color customBackground = const Color(0xFF1B2A3A);
  ChatPattern pattern = ChatPattern.none;

  LocalStore? _store;

  Future<void> load(LocalStore store) async {
    _store = store;
    theme = ThemeChoice.phone;
    accent = 'sky';
    background = 'theme';
    pattern = ChatPattern.none;
    try {
      final m = await store.setting('appearance');
      if (m is Map) {
        theme = ThemeChoice.values.asNameMap()[m['theme']] ?? theme;
        accent = m['accent'] as String? ?? accent;
        customAccent = ColourMath.parse(m['customAccent']) ?? customAccent;
        background = m['background'] as String? ?? background;
        customBackground = ColourMath.parse(m['customBackground']) ?? customBackground;
        pattern = ChatPattern.values.asNameMap()[m['pattern']] ?? pattern;
        if (accent != 'custom' && !AppearancePresets.accents.any((a) => a.id == accent)) accent = 'sky';
        if (background != 'custom' && !AppearancePresets.backgrounds.any((b) => b.id == background)) {
          background = 'theme';
        }
      }
    } on Object {
      // unreadable: keep the defaults
    }
    notifyListeners();
  }

  void update({
    ThemeChoice? theme,
    String? accent,
    Color? customAccent,
    String? background,
    Color? customBackground,
    ChatPattern? pattern,
  }) {
    this.theme = theme ?? this.theme;
    this.accent = accent ?? this.accent;
    this.customAccent = customAccent ?? this.customAccent;
    this.background = background ?? this.background;
    this.customBackground = customBackground ?? this.customBackground;
    this.pattern = pattern ?? this.pattern;
    notifyListeners();
    _store?.putSetting('appearance', {
      'theme': this.theme.name,
      'accent': this.accent,
      'customAccent': this.customAccent.toARGB32() & 0xFFFFFF,
      'background': this.background,
      'customBackground': this.customBackground.toARGB32() & 0xFFFFFF,
      'pattern': this.pattern.name,
    });
  }

  void reset() => update(theme: ThemeChoice.phone, accent: 'sky', background: 'theme', pattern: ChatPattern.none);

  AccentPreset? get accentPreset => AppearancePresets.accents.where((a) => a.id == accent).firstOrNull;

  Color get accentColour => accentPreset?.fill ?? customAccent;

  String get accentName => accentPreset?.name ?? 'Your own colour';

  Color? get backgroundColour => background == 'custom'
      ? customBackground
      : AppearancePresets.backgrounds.where((b) => b.id == background).firstOrNull?.color;

  String get summary {
    final t = switch (theme) {
      ThemeChoice.phone => 'Follows your phone',
      ThemeChoice.midnight => 'Midnight',
      ThemeChoice.black => 'Black',
      ThemeChoice.light => 'Light',
      ThemeChoice.sand => 'Sand',
    };
    return '$t · $accentName';
  }

  ThemeMode get mode => switch (theme) {
        ThemeChoice.phone => ThemeMode.system,
        ThemeChoice.midnight || ThemeChoice.black => ThemeMode.dark,
        ThemeChoice.light || ThemeChoice.sand => ThemeMode.light,
      };

  ThemeData get lightTheme =>
      AppTheme.from(tokens(theme == ThemeChoice.sand ? AppearancePresets.sand : SkylineTokens.light), Brightness.light);

  ThemeData get darkTheme =>
      AppTheme.from(tokens(theme == ThemeChoice.black ? AppearancePresets.black : SkylineTokens.dark), Brightness.dark);

  /// [base] with this person's colour and chat background applied.
  SkylineTokens tokens(SkylineTokens base) {
    final dark = ColourMath.luminance(base.ground) < 0.4;
    final fill = accentColour;
    final preset = accentPreset;
    final text = (dark ? preset?.textDark : preset?.textLight) ?? ColourMath.readableOn(fill, base.ground);
    final on = ColourMath.on(fill);
    final chat = backgroundColour;
    Color? incoming, incomingText, incomingSoft;
    if (chat != null) {
      final chatDark = ColourMath.luminance(chat) < 0.18;
      incoming = Color.lerp(chat, Colors.white, chatDark ? 0.12 : 0.75);
      incomingText = chatDark ? const Color(0xFFF2F5FA) : const Color(0xFF101828);
      incomingSoft = chatDark ? const Color(0xFFB4BED0) : const Color(0xFF4F5B73);
    }
    return SkylineTokens(
      ground: base.ground,
      surface: base.surface,
      surfaceRaised: base.surfaceRaised,
      border: base.border,
      textPrimary: base.textPrimary,
      textSecondary: base.textSecondary,
      accentFill: fill,
      accentText: text,
      verified: base.verified,
      caution: base.caution,
      danger: base.danger,
      bubbleIncoming: incoming ?? base.bubbleIncoming,
      bubbleOutgoing: fill,
      onAccent: on,
      onAccentSoft: on == Colors.white ? const Color(0xFFE6ECFA) : const Color(0xFF2B3446),
      bubbleIncomingText: incomingText ?? base.textPrimary,
      bubbleIncomingSoft: incomingSoft ?? base.textSecondary,
      chatBackground: chat ?? base.ground,
      chatPattern: pattern,
    );
  }
}
