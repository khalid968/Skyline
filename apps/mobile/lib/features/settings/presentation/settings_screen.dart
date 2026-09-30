import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/version.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/skyline_logo.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../profile/presentation/photo_editor.dart';
import '../../updates/data/release_service.dart';
import '../../updates/data/update_installer.dart';
import 'settings_widgets.dart';

/// Board 43: Settings. Appearance, Privacy & security and Notifications, then
/// About with the version and Check for updates.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _name;

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    try {
      final me = await ref.read(appControllerProvider).api!.get('/me') as Map<String, Object?>;
      if (mounted) setState(() => _name = me['displayName'] as String?);
    } on Object {
      // offline: the card shows without the name
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final t = context.sky;
    final me = app.messenger?.me ?? '';
    return Scaffold(
      appBar: const SettingsAppBar(title: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
        children: [
          // Board 46: your photo is yours to choose; your name is not.
          SettingsCard(padding: const EdgeInsets.fromLTRB(16, 22, 16, 18), children: [
            Center(
              child: Semantics(
                button: true,
                label: 'Change your photo',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: app.photos == null ? null : () => changeProfilePhoto(context, app.photos!),
                  child: Stack(children: [
                    Avatar(name: _name ?? '', seed: me, size: 104),
                    Positioned(
                      right: 0,
                      bottom: 2,
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: t.surfaceRaised,
                          shape: BoxShape.circle,
                          border: Border.all(color: t.surface, width: 3),
                        ),
                        child: SkyIcon(SkyIcons.camera, size: 16, color: t.textPrimary, stroke: 2),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(_name ?? ' ',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.textPrimary)),
            const SizedBox(height: 4),
            Text('Your name is set by your administrator. Your photo is yours to choose.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.verified.withValues(alpha: 0.10),
              border: Border.all(color: t.verified.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SkyIcon(SkyIcons.lock, size: 18, color: t.verified, stroke: 2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Only the people you’re linked to can see your photo. It’s end-to-end encrypted like your '
                  'messages: your organization’s server and administrators can’t see it.',
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: t.textPrimary),
                ),
              ),
            ]),
          ),
          const SettingsSection('Settings'),
          SettingsCard(children: [
            ListenableBuilder(
              listenable: app.appearance,
              builder: (context, _) => SettingsLink(
                icon: SkyIcons.palette,
                tint: t.accentText,
                title: 'Appearance',
                subtitle: app.appearance.summary,
                onTap: () => context.push('/settings/appearance'),
              ),
            ),
            SettingsLink(
              icon: SkyIcons.shield,
              tint: t.verified,
              title: 'Privacy & security',
              subtitle: 'App lock, disappearing messages, safety numbers',
              onTap: () => context.push('/settings/privacy'),
            ),
            SettingsLink(
              icon: SkyIcons.bell,
              tint: t.caution,
              title: 'Notifications',
              subtitle: 'Sounds and previews are set in your device’s settings',
            ),
          ]),
          const SettingsSection('About'),
          if (app.releases != null) _About(releases: app.releases!, installer: app.installer),
        ],
      ),
    );
  }
}

class _About extends StatefulWidget {
  const _About({required this.releases, required this.installer});
  final ReleaseService releases;
  final UpdateInstaller installer;

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _checking = false;
  bool? _answered; // null: not asked on this screen yet

  Future<void> _check() async {
    setState(() => _checking = true);
    final ok = await widget.releases.checkNow();
    if (mounted) {
      setState(() {
        _checking = false;
        _answered = ok;
      });
    }
  }

  String _when(DateTime d) {
    final now = DateTime.now();
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (now.difference(d).inMinutes < 1) return 'just now';
    return d.year == now.year && d.month == now.month && d.day == now.day
        ? 'today at $hm'
        : '${d.day}/${d.month} at $hm';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.releases, widget.installer]),
      builder: (context, _) {
        final r = widget.releases.available;
        final checked = widget.releases.checkedAt;
        final status = _checking
            ? 'Checking…'
            : r != null
                ? 'A new version is ready to download'
                : _answered == false
                    ? 'Couldn’t reach your server. Try again later.'
                    : checked == null
                        ? 'Not checked yet'
                        : _answered == true
                            ? 'You have the latest version · checked ${_when(checked)}'
                            : 'Last checked ${_when(checked)}';
        return SettingsCard(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            const SkylineLogo(size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Skyline $appVersion',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.textPrimary)),
                const SizedBox(height: 2),
                Text(status, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          if (r == null)
            OutlinedButton.icon(
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : SkyIcon(SkyIcons.refresh, size: 17, color: t.accentText, stroke: 2),
              label: Text(_checking ? 'Checking…' : 'Check for updates'),
            )
          else
            _Found(release: r, installer: widget.installer),
          const SizedBox(height: 12),
          Text(
            'Skyline also checks by itself when it opens and every few hours. Updates come only from your '
            'organization’s server (or Apple’s TestFlight on iPhone). Messages and keys stay on this device.',
            style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary),
          ),
        ]);
      },
    );
  }
}

class _Found extends StatelessWidget {
  const _Found({required this.release, required this.installer});
  final Release release;
  final UpdateInstaller installer;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final size = release.size == null ? '' : ' · ${(release.size! / 1048576).round()} MB';
    final label = switch (installer.phase) {
      InstallPhase.downloading => 'Downloading… ${(installer.fraction * 100).round()}%',
      InstallPhase.ready => 'Install',
      InstallPhase.failed => 'Try again',
      InstallPhase.idle => 'Download and install',
    };
    final note = installer.problem ??
        (installer.phase == InstallPhase.ready
            ? 'Your device asks you to confirm the install.'
            : UpdateInstaller.canInstallInApp(release)
                ? 'Downloaded from your server over an encrypted connection, then checked before installing.'
                : 'Opens in your browser.');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: t.accentFill.withValues(alpha: 0.12),
        border: Border.all(color: t.accentFill.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Skyline ${release.version} is available$size',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textPrimary)),
        for (final n in release.notes)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('•  $n', style: TextStyle(fontSize: 13, height: 1.45, color: t.textPrimary)),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: installer.phase == InstallPhase.downloading ? null : () => installer.run(release),
          child: Text(label),
        ),
        if (installer.phase == InstallPhase.downloading)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(value: installer.fraction, minHeight: 3),
          ),
        const SizedBox(height: 8),
        Text(note,
            style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: installer.phase == InstallPhase.failed ? t.danger : t.textSecondary)),
      ]),
    );
  }
}
