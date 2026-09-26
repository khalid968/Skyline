import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/version.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../data/release_service.dart';
import '../data/update_installer.dart';

/// Board 42: a quiet banner at the top of Chats when a newer version exists.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.releases, this.installer});
  final ReleaseService releases;
  final UpdateInstaller? installer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: releases,
      builder: (context, _) {
        final r = releases.available;
        if (r == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Material(
            color: const Color(0xFF16223F),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFF2B3C66)),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showUpdateSheet(context, r, installer: installer),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: const Color(0xFF1F3160), borderRadius: BorderRadius.circular(10)),
                    child: const SkyIcon(SkyIcons.download, size: 17, color: Color(0xFF9DB8FF), stroke: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Skyline ${r.version} is available',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFE3E8F2))),
                      const SizedBox(height: 2),
                      const Text("Tap to see what's new and update",
                          style: TextStyle(fontSize: 12, color: Color(0xFF9AA6BF))),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What's new, with Download and install or Later. The download opens in the
/// browser: the APK or installer from the organization's server, or TestFlight.
Future<void> showUpdateSheet(BuildContext context, Release r, {UpdateInstaller? installer}) {
  final t = context.sky;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('Skyline ${r.version}',
              style: TextStyle(
                  fontFamily: SkyFonts.display, fontSize: 19, fontWeight: FontWeight.w700, color: t.textPrimary)),
          const SizedBox(height: 4),
          Text(
            'You have $appVersion${r.size != null ? ' · ${(r.size! / 1048576).round()} MB' : ''} · from your organization',
            style: TextStyle(fontSize: 12.5, color: t.textSecondary),
          ),
          if (r.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: t.ground, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final n in r.notes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text('•  $n', style: TextStyle(fontSize: 13, height: 1.5, color: t.textPrimary)),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          Text('Your messages, keys and settings stay on this device; updating replaces only the app.',
              style: TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary)),
          const SizedBox(height: 14),
          _InstallButton(release: r, installer: installer, label: 'Download and install'),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
        ]),
      ),
    ),
  );
}

/// Board 42, required: this version may no longer be used (the server's
/// minimum, or a 426). Covers the app; nothing is lost.
class UpdateRequiredGate extends StatelessWidget {
  const UpdateRequiredGate({super.key, required this.releases, required this.child, this.installer});
  final ReleaseService? releases;
  final UpdateInstaller? installer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = releases;
    if (r == null) return child;
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        if (!r.required) return child;
        final release = r.available;
        return Material(
          color: const Color(0xFF0C111C),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(28, box.maxHeight < 640 ? 32 : 70, 28, 30),
                      child: Column(children: [
                        Container(
                          width: 72,
                          height: 72,
                          alignment: Alignment.center,
                          decoration:
                              BoxDecoration(color: const Color(0xFF1F3160), borderRadius: BorderRadius.circular(22)),
                          child: const SkyIcon(SkyIcons.shield, size: 32, color: Color(0xFF9DB8FF)),
                        ),
                        const SizedBox(height: 24),
                        const Text('Please update Skyline',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontFamily: SkyFonts.display,
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFF2F5FA))),
                        const SizedBox(height: 12),
                        const Text(
                          'This version ($appVersion) is no longer supported, usually because of a security fix. '
                          "It can't send or receive until you update.",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, height: 1.55, color: Color(0xFF9AA6BF)),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                            'Nothing is lost: your messages and keys stay on this device and are here after the update.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, height: 1.55, color: Color(0xFF7C8AA5))),
                        const Spacer(),
                        const SizedBox(height: 20),
                        if (release == null)
                          const SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: FilledButton(
                                onPressed: null, child: Text('Ask your administrator for the new version')),
                          )
                        else
                          _InstallButton(release: release, installer: installer, label: 'Download ${release.version}'),
                        const SizedBox(height: 10),
                        const Text("From your organization's server",
                            style: TextStyle(fontSize: 12, color: Color(0xFF6E7E99))),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Board 43's download inside boards 42's sheet and gate: progress, then the
/// system installer (or the browser where the app can't install itself).
class _InstallButton extends StatelessWidget {
  const _InstallButton({required this.release, required this.installer, required this.label});
  final Release release;
  final UpdateInstaller? installer;
  final String label;

  @override
  Widget build(BuildContext context) {
    final i = installer;
    if (i == null) {
      return FilledButton(
        onPressed: () => launchUrl(release.url, mode: LaunchMode.externalApplication),
        child: Text(label),
      );
    }
    return ListenableBuilder(
      listenable: i,
      builder: (context, _) =>
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        FilledButton(
          onPressed: i.phase == InstallPhase.downloading ? null : () => i.run(release),
          child: Text(switch (i.phase) {
            InstallPhase.downloading => 'Downloading… ${(i.fraction * 100).round()}%',
            InstallPhase.ready => 'Install',
            InstallPhase.failed => 'Try again',
            InstallPhase.idle => label,
          }),
        ),
        if (i.problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(i.problem!,
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: context.sky.danger)),
          ),
      ]),
    );
  }
}
