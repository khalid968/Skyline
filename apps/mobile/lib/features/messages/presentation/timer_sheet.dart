import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';

/// Board 15: presets Off to 1 year, plus a custom duration from 5 minutes to
/// 1 year (owner decision 2026-09-23). Returns the chosen seconds (null = off),
/// or [TimerChoice.cancelled] if dismissed.
class TimerChoice {
  const TimerChoice(this.seconds);
  final int? seconds;
  static const cancelled = TimerChoice(-1);
}

const _minute = 60;
const _hour = 3600;
const _day = 86400;
const maxTimer = 365 * _day;
const minTimer = 5 * _minute;

const timerPresets = <(String, int?)>[
  ('Off', null),
  ('1 hour', _hour),
  ('1 day', _day),
  ('1 week', 7 * _day),
  ('1 month', 30 * _day),
  ('3 months', 90 * _day),
  ('6 months', 180 * _day),
  ('1 year', maxTimer),
];

String timerLabel(int? seconds) {
  if (seconds == null) return 'Off';
  for (final p in timerPresets) {
    if (p.$2 == seconds) return p.$1;
  }
  String unit(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  if (seconds % (30 * _day) == 0) return unit(seconds ~/ (30 * _day), 'month', 'months');
  if (seconds % (7 * _day) == 0) return unit(seconds ~/ (7 * _day), 'week', 'weeks');
  if (seconds % _day == 0) return unit(seconds ~/ _day, 'day', 'days');
  if (seconds % _hour == 0) return unit(seconds ~/ _hour, 'hour', 'hours');
  return unit(seconds ~/ _minute, 'minute', 'minutes');
}

Future<TimerChoice> showTimerSheet(BuildContext context, {required int? current, required String peerName}) async {
  final r = await showModalBottomSheet<TimerChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.sky.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _TimerSheet(current: current, peerName: peerName),
  );
  return r ?? TimerChoice.cancelled;
}

class _Unit {
  const _Unit(this.label, this.one, this.many, this.seconds, this.min, this.max);
  final String label, one, many;
  final int seconds, min, max;
}

const _units = [
  _Unit('min', 'minute', 'minutes', _minute, 5, 525600),
  _Unit('hours', 'hour', 'hours', _hour, 1, 8760),
  _Unit('days', 'day', 'days', _day, 1, 365),
  _Unit('weeks', 'week', 'weeks', 7 * _day, 1, 52),
  _Unit('months', 'month', 'months', 30 * _day, 1, 12),
];

class _TimerSheet extends StatefulWidget {
  const _TimerSheet({required this.current, required this.peerName});
  final int? current;
  final String peerName;

  @override
  State<_TimerSheet> createState() => _TimerSheetState();
}

class _TimerSheetState extends State<_TimerSheet> {
  late int? _chosen = widget.current;
  late bool _custom = widget.current != null && !timerPresets.any((p) => p.$2 == widget.current);
  int _unit = 4;
  int _amount = 2;

  int get _customSeconds {
    final u = _units[_unit];
    return (_amount * u.seconds).clamp(minTimer, maxTimer);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    Widget choice(String label, bool on, VoidCallback pick, {Widget? trailing}) => Semantics(
          inMutuallyExclusiveGroup: true,
          checked: on,
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: pick,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: on ? t.surfaceRaised : Colors.transparent,
                border: Border.all(color: on ? t.accentFill : t.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Expanded(child: Text(label, style: TextStyle(fontSize: 14.5, color: t.textPrimary))),
                trailing ??
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: on ? Colors.white : Colors.transparent,
                        border: Border.all(color: on ? t.accentFill : t.border, width: on ? 5 : 2),
                      ),
                    ),
              ]),
            ),
          ),
        );

    final u = _units[_unit];
    final capped = _amount * u.seconds >= maxTimer && _amount >= u.max;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 12, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(999)),
              ),
            ),
            const SizedBox(height: 14),
            Text('Disappearing messages',
                style: TextStyle(fontFamily: SkyFonts.display, fontSize: 20, fontWeight: FontWeight.w500, color: t.textPrimary)),
            const SizedBox(height: 6),
            Text("New messages in this chat are deleted from both phones this long after they're read.",
                style: TextStyle(fontSize: 13, height: 1.5, color: t.textSecondary)),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 3.6,
              children: [
                for (final p in timerPresets)
                  choice(p.$1, !_custom && _chosen == p.$2, () => setState(() {
                        _custom = false;
                        _chosen = p.$2;
                      })),
              ],
            ),
            const SizedBox(height: 8),
            choice('Custom…', _custom, () => setState(() => _custom = true),
                trailing: Text('5 minutes to 1 year', style: TextStyle(fontSize: 13, color: t.textSecondary))),
            if (_custom) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.ground,
                  border: Border.all(color: t.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    IconButton.filledTonal(
                      tooltip: 'Less',
                      onPressed: () => setState(() => _amount = (_amount - 1).clamp(u.min, u.max)),
                      icon: const Text('−', style: TextStyle(fontSize: 20)),
                    ),
                    SizedBox(
                      width: 64,
                      child: Semantics(
                        liveRegion: true,
                        child: Text('$_amount',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: SkyFonts.display, fontSize: 24, color: t.textPrimary)),
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'More',
                      onPressed: () => setState(() => _amount = (_amount + 1).clamp(u.min, u.max)),
                      icon: const Text('+', style: TextStyle(fontSize: 20)),
                    ),
                    const SizedBox(width: 10),
                    Text(_amount == 1 ? u.one : u.many, style: TextStyle(fontSize: 14, color: t.textSecondary)),
                  ]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (var i = 0; i < _units.length; i++)
                      ChoiceChip(
                        label: Text(_units[i].label),
                        selected: i == _unit,
                        onSelected: (_) => setState(() {
                          _unit = i;
                          _amount = _amount.clamp(_units[i].min, _units[i].max);
                        }),
                      ),
                  ]),
                  if (capped)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('The longest a message can last is 1 year.',
                          style: TextStyle(fontSize: 12, color: t.caution)),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              '${widget.peerName} will see a notice that you changed it. Messages already sent keep their old timer. Nobody can stop a screenshot.',
              style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context, TimerChoice(_custom ? _customSeconds : _chosen)),
              child: const Text('Save'),
            ),
          ]),
        ),
      ),
    );
  }
}
