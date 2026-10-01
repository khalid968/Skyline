import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../calls/data/ringer.dart';
import '../data/device_prefs.dart';
import 'settings_widgets.dart';

/// Board 48: how an incoming call rings while Skyline is open. Android only
/// for now (the phone's own call screen needs Apple's push service on iPhone).
class CallsSettingsScreen extends ConsumerStatefulWidget {
  const CallsSettingsScreen({super.key});

  @override
  ConsumerState<CallsSettingsScreen> createState() => _CallsSettingsScreenState();
}

class _CallsSettingsScreenState extends ConsumerState<CallsSettingsScreen> with WidgetsBindingObserver {
  bool _fullScreen = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android's settings page: look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final ok = await fullScreenCallsAllowed();
    if (mounted && ok != _fullScreen) setState(() => _fullScreen = ok);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appControllerProvider).device;
    return Scaffold(
      appBar: const SettingsAppBar(title: 'Calls'),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) {
          final style = prefs.callStyle;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
            children: [
              if (!_fullScreen) ...[
                const SizedBox(height: 10),
                const _FullScreenWarning(onAllow: askForFullScreenCalls),
              ],
              const SettingsSection('How incoming calls ring'),
              SettingsCard(children: [
                _Option(
                  title: 'Skyline’s call screen (default)',
                  body: 'While Skyline is open, calls ring on Skyline’s own screen. When it’s closed, they ring on '
                      'your phone’s call screen.',
                  selected: style == CallStyle.skyline,
                  onTap: () => prefs.update(callStyle: CallStyle.skyline),
                ),
                _Option(
                  title: 'Like a phone call',
                  body: 'Every call rings on your phone’s own call screen, even while Skyline is open, like a normal '
                      'phone call.',
                  selected: style == CallStyle.phone,
                  onTap: () => prefs.update(callStyle: CallStyle.phone),
                ),
              ]),
              SettingsNote(style == CallStyle.phone
                  ? 'Skyline opens when you answer, for video, mute and speaker.'
                  : 'This is how Skyline works today.'),
              const SettingsNote('Ringtone and vibration follow your phone’s sound settings either way. When Skyline '
                  'is closed, calls always ring on your phone’s call screen.'),
            ],
          );
        },
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.title, required this.body, required this.selected, required this.onTap});
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              margin: const EdgeInsets.only(top: 2),
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? t.accentFill : t.border, width: 2),
              ),
              child: selected
                  ? Container(width: 10, height: 10, decoration: BoxDecoration(color: t.accentFill, shape: BoxShape.circle))
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(fontSize: 12.5, height: 1.5, color: t.textSecondary)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Android 14+: without this permission a call on a locked phone is only a
/// banner, never the full-screen call screen.
class _FullScreenWarning extends StatelessWidget {
  const _FullScreenWarning({required this.onAllow});
  final Future<void> Function() onAllow;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.caution.withValues(alpha: 0.10),
        border: Border.all(color: t.caution.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkyIcon(SkyIcons.warn, size: 18, color: t.caution, stroke: 2),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Calls can’t fill the screen while your phone is locked. Allow Skyline to show full-screen '
              'notifications so a call rings like a phone call.',
              style: TextStyle(fontSize: 13, height: 1.5, color: t.textPrimary),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: onAllow, child: const Text('Allow')),
        ),
      ]),
    );
  }
}
