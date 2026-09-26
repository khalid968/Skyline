import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/appearance.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/chat_backdrop.dart';
import '../../../shared/widgets/sky_icon.dart';
import 'settings_widgets.dart';

/// Board 44: theme, the colour of your messages and buttons, and the chat
/// background. Everything applies at once and stays on this device.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(appControllerProvider).appearance;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final t = context.sky;
        return Scaffold(
          appBar: SettingsAppBar(title: 'Appearance', actions: [
            TextButton(onPressed: a.reset, child: Text('Reset', style: TextStyle(color: t.textSecondary))),
            const SizedBox(width: 6),
          ]),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              const SettingsSection('Preview'),
              const _Preview(),
              const SettingsSection('Theme'),
              _Themes(a: a),
              SettingsNote(_themeNote(a.theme)),
              const SettingsSection('Your messages and buttons'),
              SettingsCard(padding: const EdgeInsets.all(14), children: [
                _SwatchGrid(children: [
                  for (final p in AppearancePresets.accents)
                    _Swatch(
                      label: p.name,
                      colour: p.fill,
                      selected: a.accent == p.id,
                      ring: a.accentColour,
                      onTap: () => a.update(accent: p.id),
                    ),
                  _AnySwatch(
                    label: 'Any colour for your messages',
                    selected: a.accent == 'custom',
                    ring: a.accentColour,
                    onTap: () async {
                      final c = await pickColour(context, a.customAccent, 'Your messages and buttons');
                      if (c != null) a.update(accent: 'custom', customAccent: c);
                    },
                  ),
                ]),
                const SizedBox(height: 12),
                Divider(height: 1, color: t.border),
                const SizedBox(height: 10),
                Row(children: [
                  Container(
                      width: 22, height: 22, decoration: BoxDecoration(color: a.accentColour, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(a.accentName, style: TextStyle(fontSize: 13, color: t.textPrimary))),
                  Text(ColourMath.hex(a.accentColour),
                      style: TextStyle(fontFamily: SkyFonts.mono, fontSize: 12, color: t.textSecondary)),
                ]),
                if (_accentNote(a.accentColour) case final note?) ...[
                  const SizedBox(height: 8),
                  Text(note, style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary)),
                ],
              ]),
              const SettingsSection('Chat background'),
              SettingsCard(padding: const EdgeInsets.all(14), children: [
                _SwatchGrid(children: [
                  for (final b in AppearancePresets.backgrounds)
                    _Swatch(
                      label: b.name,
                      colour: b.color ?? t.ground,
                      square: true,
                      text: b.color == null ? 'Auto' : null,
                      selected: a.background == b.id,
                      ring: a.accentColour,
                      onTap: () => a.update(background: b.id),
                    ),
                  _AnySwatch(
                    label: 'Any colour for the chat background',
                    square: true,
                    selected: a.background == 'custom',
                    ring: a.accentColour,
                    onTap: () async {
                      final c = await pickColour(context, a.customBackground, 'Chat background');
                      if (c != null) a.update(background: 'custom', customBackground: c);
                    },
                  ),
                ]),
                const SizedBox(height: 12),
                Divider(height: 1, color: t.border),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text('Pattern', style: TextStyle(fontSize: 13, color: t.textPrimary)),
                  ),
                  for (final p in ChatPattern.values)
                    ChoiceChip(
                      label: Text(switch (p) {
                        ChatPattern.none => 'None',
                        ChatPattern.dots => 'Dots',
                        ChatPattern.lines => 'Lines',
                        ChatPattern.grid => 'Grid',
                      }),
                      selected: a.pattern == p,
                      onSelected: (_) => a.update(pattern: p),
                    ),
                ]),
                const SizedBox(height: 10),
                Text(
                  'The other person’s bubbles adjust to your background so text stays readable. '
                  'Only you see your colours.',
                  style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
                ),
              ]),
              const SettingsNote(
                  'Verified, warning and problem notices always keep their own green, amber and red, with an icon '
                  'and words, whatever colours you choose.'),
            ],
          ),
        );
      },
    );
  }

  static String _themeNote(ThemeChoice c) => switch (c) {
        ThemeChoice.phone => 'Follows your device: light or dark, as it is set.',
        ThemeChoice.midnight => 'Deep blue dark. Easy on the eyes at night.',
        ThemeChoice.black => 'True black. Saves battery on phones with an OLED screen.',
        ThemeChoice.light => 'Bright and clean, for daylight.',
        ThemeChoice.sand => 'A warm light theme with softer contrast.',
      };

  static String? _accentNote(Color c) {
    if (ColourMath.nearSecurityHue(c)) {
      return 'This is close to the colours Skyline uses for verified, warnings or problems. Those notices still '
          'show with their icon and words, so they stay clear.';
    }
    if (ColourMath.on(c) != Colors.white) {
      return 'A light colour: text on your messages switches to dark so it stays readable.';
    }
    return null;
  }
}

/// A small conversation in the chosen colours.
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    Widget bubble(String text, {required bool mine}) => Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: mine ? t.bubbleOutgoing : t.bubbleIncoming,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 5),
                bottomRight: Radius.circular(mine ? 5 : 16),
              ),
            ),
            child: Text(text,
                style: TextStyle(fontSize: 13.5, height: 1.4, color: mine ? t.onAccent : t.bubbleIncomingText)),
          ),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: t.border), borderRadius: BorderRadius.circular(16)),
        child: ChatBackdrop(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Color(0xFFC1743A), shape: BoxShape.circle),
                    child: const Text('SW',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Sarah Whitfield',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: t.textPrimary)),
                      Row(children: [
                        SkyIcon(SkyIcons.shield, size: 11, color: t.verified, stroke: 2.4),
                        const SizedBox(width: 4),
                        Text('Verified', style: TextStyle(fontSize: 11, color: t.verified)),
                      ]),
                    ]),
                  ),
                ]),
              ),
              bubble('Are we still on for Thursday?', mine: false),
              bubble('Yes, 10:00 at the office', mine: true),
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(999)),
                child: Text('Messages disappear after 1 week', style: TextStyle(fontSize: 11, color: t.caution)),
              ),
              bubble('I’ll bring the documents', mine: true),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Themes extends StatelessWidget {
  const _Themes({required this.a});
  final Appearance a;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    const choices = [
      (ThemeChoice.phone, 'Device', Color(0xFF0C111C), Color(0xFF1C2438), true),
      (ThemeChoice.midnight, 'Midnight', Color(0xFF0C111C), Color(0xFF1C2438), false),
      (ThemeChoice.black, 'Black', Color(0xFF000000), Color(0xFF1B1B1F), false),
      (ThemeChoice.light, 'Light', Color(0xFFF5F7FB), Color(0xFFE1E6EF), false),
      (ThemeChoice.sand, 'Sand', Color(0xFFF6F1E9), Color(0xFFE4DACA), false),
    ];
    return Row(children: [
      for (final (i, c) in choices.indexed) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            button: true,
            selected: a.theme == c.$1,
            label: '${c.$2} theme',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => a.update(theme: c.$1),
              child: Column(children: [
                Container(
                  height: 70,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: c.$3,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: a.theme == c.$1 ? a.accentColour : t.border, width: 2),
                  ),
                  child: Stack(children: [
                    Padding(
                      padding: const EdgeInsets.all(7),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _bar(c.$4, 0.7),
                        const SizedBox(height: 5),
                        Align(alignment: Alignment.centerRight, child: _bar(a.accentColour, 0.6)),
                        const SizedBox(height: 5),
                        _bar(c.$4, 0.55),
                      ]),
                    ),
                    if (c.$5)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: 28,
                        child: Container(
                          color: const Color(0xFFF5F7FB),
                          padding: const EdgeInsets.only(top: 7, right: 5),
                          alignment: Alignment.topRight,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Container(width: 14, height: 9, decoration: _pill(const Color(0xFFE3E8F0))),
                            const SizedBox(height: 5),
                            Container(width: 20, height: 9, decoration: _pill(a.accentColour)),
                          ]),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 6),
                Text(c.$2,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: a.theme == c.$1 ? FontWeight.w700 : FontWeight.w500,
                      color: a.theme == c.$1 ? t.textPrimary : t.textSecondary,
                    )),
              ]),
            ),
          ),
        ),
      ],
    ]);
  }

  static BoxDecoration _pill(Color c) => BoxDecoration(color: c, borderRadius: BorderRadius.circular(5));

  static Widget _bar(Color c, double f) =>
      FractionallySizedBox(widthFactor: f, child: Container(height: 9, decoration: _pill(c)));
}

class _SwatchGrid extends StatelessWidget {
  const _SwatchGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final perRow = (box.maxWidth / 58).floor().clamp(4, 8);
          final gap = (box.maxWidth - perRow * 50) / (perRow - 1);
          return Wrap(spacing: gap, runSpacing: 10, children: children);
        },
      );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.colour,
    required this.selected,
    required this.ring,
    required this.onTap,
    this.square = false,
    this.text,
  });
  final String label;
  final Color colour;
  final bool selected;
  final Color ring;
  final VoidCallback onTap;
  final bool square;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final on = ColourMath.on(colour);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: onTap,
          customBorder: square ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)) : const CircleBorder(),
          child: Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: square ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: square ? BorderRadius.circular(14) : null,
              border: Border.all(color: selected ? ring : Colors.transparent, width: 3),
            ),
            child: Container(
              width: square ? 38 : 36,
              height: square ? 38 : 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colour,
                shape: square ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: square ? BorderRadius.circular(10) : null,
                border: Border.all(color: t.border),
              ),
              child: selected
                  ? SkyIcon(SkyIcons.check, size: 16, color: on, stroke: 3)
                  : text == null
                      ? null
                      : Text(text!, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: on)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rainbow circle: any colour at all.
class _AnySwatch extends StatelessWidget {
  const _AnySwatch(
      {required this.label, required this.selected, required this.ring, required this.onTap, this.square = false});
  final String label;
  final bool selected;
  final Color ring;
  final VoidCallback onTap;
  final bool square;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final shape = square ? BoxShape.rectangle : BoxShape.circle;
    return Tooltip(
      message: 'Any colour',
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: onTap,
          customBorder: square ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)) : const CircleBorder(),
          child: Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: shape,
              borderRadius: square ? BorderRadius.circular(14) : null,
              border: Border.all(color: selected ? ring : Colors.transparent, width: 3),
              gradient: const SweepGradient(colors: [
                Color(0xFFE0457B),
                Color(0xFFF2A93B),
                Color(0xFFF4E04D),
                Color(0xFF4CC38A),
                Color(0xFF3AA7E0),
                Color(0xFF6A4BD6),
                Color(0xFFE0457B),
              ]),
            ),
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.surface,
                shape: shape,
                borderRadius: square ? BorderRadius.circular(8) : null,
              ),
              child: SkyIcon(SkyIcons.plus, size: 14, color: t.textPrimary, stroke: 2.4),
            ),
          ),
        ),
      ),
    );
  }
}

/// A colour picker: hue, colourfulness and lightness sliders, or a hex code.
Future<Color?> pickColour(BuildContext context, Color start, String title) {
  return showModalBottomSheet<Color>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.sky.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (context) => _ColourPicker(start: start, title: title),
  );
}

class _ColourPicker extends StatefulWidget {
  const _ColourPicker({required this.start, required this.title});
  final Color start;
  final String title;

  @override
  State<_ColourPicker> createState() => _ColourPickerState();
}

class _ColourPickerState extends State<_ColourPicker> {
  late HSLColor _c = HSLColor.fromColor(widget.start);
  late final _hex = TextEditingController(text: ColourMath.hex(widget.start));

  void _set(HSLColor c) => setState(() {
        _c = c;
        _hex.text = ColourMath.hex(c.toColor());
      });

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final colour = _c.toColor();
    Widget slider(String label, double value, double max, List<Color> track, ValueChanged<double> onChanged) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
            const SizedBox(height: 6),
            Container(
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(colors: track),
              ),
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 0,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11, elevation: 2),
                ),
                child: Slider(value: value, max: max, onChanged: onChanged, semanticFormatterCallback: (v) => label),
              ),
            ),
          ],
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 20, 22, 18 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(widget.title,
                  style: TextStyle(
                      fontFamily: SkyFonts.display, fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
            ),
            Container(
              width: 64,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(10)),
              child: Text('Aa', style: TextStyle(fontWeight: FontWeight.w700, color: ColourMath.on(colour))),
            ),
          ]),
          const SizedBox(height: 18),
          slider(
              'Colour',
              _c.hue,
              360,
              [
                for (var h = 0; h <= 360; h += 60) HSLColor.fromAHSL(1, h.toDouble(), 0.75, 0.5).toColor(),
              ],
              (v) => _set(_c.withHue(v))),
          const SizedBox(height: 14),
          slider(
              'Strength',
              _c.saturation,
              1,
              [
                _c.withSaturation(0).toColor(),
                _c.withSaturation(1).toColor(),
              ],
              (v) => _set(_c.withSaturation(v))),
          const SizedBox(height: 14),
          slider(
              'Lightness',
              _c.lightness,
              1,
              [
                Colors.black,
                _c.withLightness(0.5).toColor(),
                Colors.white,
              ],
              (v) => _set(_c.withLightness(v))),
          const SizedBox(height: 16),
          TextField(
            controller: _hex,
            style: const TextStyle(fontFamily: SkyFonts.mono),
            decoration: const InputDecoration(labelText: 'Colour code', hintText: '#3A63D8'),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
              LengthLimitingTextInputFormatter(7)
            ],
            onChanged: (v) {
              final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(v.trim());
              if (m != null) setState(() => _c = HSLColor.fromColor(Color(0xFF000000 | int.parse(m[1]!, radix: 16))));
            },
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.pop(context, colour), child: const Text('Use this colour')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ]),
      ),
    );
  }
}
