import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../../messages/presentation/timer_sheet.dart';
import '../data/app_lock.dart';
import 'lock_screen.dart';

/// Board 13: Privacy & security. Read receipts and typing indicators are the
/// owner's Phase 8 decision (on by default, each person may switch them off;
/// switching yours off also hides other people's from you).
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messenger = ref.watch(appControllerProvider).messenger!;
    final t = context.sky;
    return ListenableBuilder(
      listenable: messenger,
      builder: (context, _) => FutureBuilder<(bool, bool, int?)>(
        future: _load(messenger),
        builder: (context, snap) {
          final (receipts, typing, timer) = snap.data ?? (true, true, null);
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Back',
                onPressed: () => context.pop(),
                icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
              ),
              title: const Text('Privacy & security'),
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              children: [
                const _Section('App lock'),
                _AppLockCard(lock: ref.watch(appControllerProvider).lock!),
                const _Note(
                    'Your face, fingerprint and PIN never leave this device. Your administrator can’t see or reset them. Forget your PIN and you’ll need a new activation code, and messages on this device will be lost.'),
                const _Section('Messages'),
                _Card(children: [
                  _Switch(
                    title: 'Read receipts',
                    subtitle: 'Let people see when you have read their messages',
                    value: receipts,
                    onChanged: messenger.setReadReceipts,
                  ),
                  _Switch(
                    title: 'Typing indicators',
                    subtitle: 'Let people see when you are typing',
                    value: typing,
                    onChanged: messenger.setTypingIndicators,
                  ),
                ]),
                const _Note('If you turn one off, you will not see other people’s either. It is fair both ways.'),
                const _Section('Disappearing messages'),
                _Card(children: [
                  ListTile(
                    leading: SkyIcon(SkyIcons.clock, size: 20, color: t.caution, stroke: 2),
                    title: Text('Default for new chats',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
                    subtitle: Text('You can change it in any chat, too',
                        style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                    trailing: Text('${timerLabel(timer)} ›', style: TextStyle(fontSize: 14, color: t.caution)),
                    onTap: () async {
                      final r = await showTimerSheet(context, current: timer, peerName: 'The other person');
                      if (r.seconds != -1) await messenger.setDefaultTimer(r.seconds);
                    },
                  ),
                ]),
                const _Note(
                    'Messages are deleted from both phones once the time runs out after they’re read. It can’t stop anyone taking a screenshot or a photo of the screen.'),
                const _Section('This device'),
                _Card(children: [
                  ListTile(
                    title: Text('Safety numbers', style: TextStyle(fontSize: 15, color: t.textPrimary)),
                    subtitle: Text('Open a chat and tap the name to compare',
                        style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
                  ),
                  _MyDevice(messenger: messenger),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }
}

Future<(bool, bool, int?)> _load(Messenger m) async => (
      await m.readReceiptsEnabled(),
      await m.typingIndicatorsEnabled(),
      await m.defaultTimer(),
    );

class _MyDevice extends StatelessWidget {
  const _MyDevice({required this.messenger});
  final Messenger messenger;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListTile(
      title: Text('This device', style: TextStyle(fontSize: 15, color: t.textPrimary)),
      subtitle: Text('Device ${messenger.session.deviceNumber} of your account',
          style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Semantics(
          header: true,
          child: Text(text.toUpperCase(),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7,
                color: context.sky.textSecondary,
              )),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(text, style: TextStyle(fontSize: 12, height: 1.55, color: context.sky.textSecondary)),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.border),
          children[i],
        ],
      ]),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({required this.title, required this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String subtitle;
  final bool value;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
    );
  }
}

class _AppLockCard extends StatelessWidget {
  const _AppLockCard({required this.lock});
  final AppLock lock;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) => _Card(children: [
        _Switch(
          title: 'Lock Skyline',
          subtitle: 'Ask for your PIN, face or fingerprint to open the app',
          value: lock.enabled,
          onChanged: (on) async {
            if (on) {
              final pin = await choosePin(context);
              if (pin != null) await lock.enable(pin);
            } else {
              await lock.disable();
            }
          },
        ),
        if (lock.enabled && lock.biometricsAvailable)
          _Switch(
            title: 'Face or fingerprint',
            subtitle: 'Your PIN still works as a fallback',
            value: lock.biometrics,
            onChanged: lock.setBiometrics,
          ),
        if (lock.enabled)
          ListTile(
            title: Text('Lock after', style: TextStyle(fontSize: 15, color: t.textPrimary)),
            trailing: DropdownButton<int>(
              value: lock.lockAfterSeconds,
              underline: const SizedBox.shrink(),
              items: [
                for (final c in AppLock.lockAfterChoices)
                  DropdownMenuItem(
                    value: c.$2,
                    child: Text(c.$2 == 0 ? c.$1 : '${c.$1} in the background'),
                  ),
              ],
              onChanged: (v) {
                if (v != null) lock.setLockAfter(v);
              },
            ),
          ),
      ]),
    );
  }
}
