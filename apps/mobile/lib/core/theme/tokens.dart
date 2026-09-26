import 'package:flutter/material.dart';

/// Skyline's colour tokens, exactly as specified in docs/architecture/design.md.
/// Never derive these from a seed: the security colours carry meaning.
///
/// - [verified] means verified or encrypted, never "success" in general.
/// - [caution] means disappearing messages are on, or something needs attention.
/// - [danger] means revoked, suspended or blocked.
@immutable
class SkylineTokens extends ThemeExtension<SkylineTokens> {
  const SkylineTokens({
    required this.ground,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.accentFill,
    required this.accentText,
    required this.verified,
    required this.caution,
    required this.danger,
    required this.bubbleIncoming,
    required this.bubbleOutgoing,
    this.onAccent = const Color(0xFFFFFFFF),
    this.onAccentSoft = const Color(0xFFDDE5FC),
    Color? bubbleIncomingText,
    Color? bubbleIncomingSoft,
    Color? chatBackground,
    this.chatPattern = ChatPattern.none,
  })  : bubbleIncomingText = bubbleIncomingText ?? textPrimary,
        bubbleIncomingSoft = bubbleIncomingSoft ?? textSecondary,
        chatBackground = chatBackground ?? ground;

  final Color ground;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color accentFill;
  final Color accentText;
  final Color verified;
  final Color caution;
  final Color danger;
  final Color bubbleIncoming;
  final Color bubbleOutgoing;

  // Board 44: the person's own colours. [onAccent] is text and icons on
  // [accentFill] and on outgoing bubbles (white, or dark on a light colour);
  // [onAccentSoft] is the time and marks there. The incoming pair follows the
  // chat background so it stays readable on any colour.
  final Color onAccent;
  final Color onAccentSoft;
  final Color bubbleIncomingText;
  final Color bubbleIncomingSoft;
  final Color chatBackground;
  final ChatPattern chatPattern;

  /// The accent as it reads on an incoming bubble (links, mentions, icons).
  Color get incomingAccent {
    final towards = bubbleIncoming.computeLuminance() < 0.4 ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + 0.05) / ((x > y ? y : x) + 0.05);
    }

    for (var t = 0.0; t <= 1.0; t += 0.05) {
      final c = Color.lerp(accentText, towards, t)!;
      if (contrast(c, bubbleIncoming) >= 4.5) return c;
    }
    return towards;
  }

  static const dark = SkylineTokens(
    ground: Color(0xFF0C111C),
    surface: Color(0xFF141B2A),
    surfaceRaised: Color(0xFF1C2438),
    border: Color(0xFF263049),
    textPrimary: Color(0xFFF2F5FA),
    textSecondary: Color(0xFF9AA6BF),
    accentFill: Color(0xFF3A63D8),
    accentText: Color(0xFF6E96FF),
    verified: Color(0xFF34C08A),
    caution: Color(0xFFE8A33D),
    danger: Color(0xFFD04545),
    bubbleIncoming: Color(0xFF1C2438),
    bubbleOutgoing: Color(0xFF3A63D8),
  );

  static const light = SkylineTokens(
    ground: Color(0xFFF5F7FB),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFAFBFD),
    border: Color(0xFFE7EBF2),
    textPrimary: Color(0xFF101828),
    textSecondary: Color(0xFF5A6782),
    accentFill: Color(0xFF3A63D8),
    accentText: Color(0xFF3A63D8),
    verified: Color(0xFF14774F),
    caution: Color(0xFF8A5A0B),
    danger: Color(0xFFA32020),
    bubbleIncoming: Color(0xFFFFFFFF),
    bubbleOutgoing: Color(0xFF3A63D8),
  );

  @override
  SkylineTokens copyWith() => this;

  @override
  SkylineTokens lerp(ThemeExtension<SkylineTokens>? other, double t) =>
      t < 0.5 ? this : (other as SkylineTokens? ?? this);
}

/// The optional texture behind a conversation (board 44).
enum ChatPattern { none, dots, lines, grid }

extension SkylineTokensX on BuildContext {
  SkylineTokens get sky => Theme.of(this).extension<SkylineTokens>()!;
}

/// Type faces (bundled, see pubspec.yaml).
abstract final class SkyFonts {
  static const display = 'SpaceGrotesk';
  static const body = 'PlusJakartaSans';
  // Anything a person compares character by character: safety numbers,
  // activation codes, usernames.
  static const mono = 'JetBrainsMono';
}
