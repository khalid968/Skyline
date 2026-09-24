import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../../messages/data/messenger.dart';
import '../../messages/domain/models.dart';

/// Board 4: the safety number for each of a contact's devices (every device
/// has its own identity, decisions.md 2026-09-23). Compare in person or over a
/// call you already trust, then mark the device verified.
class SafetyNumberScreen extends ConsumerStatefulWidget {
  const SafetyNumberScreen({super.key, required this.peer});
  final String peer;

  @override
  ConsumerState<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends ConsumerState<SafetyNumberScreen> {
  late final Messenger messenger = ref.read(appControllerProvider).messenger!;
  int _index = 0;

  Future<(List<KnownDevice>, String?, String?)> _load() async {
    final devices = await messenger.store.devicesOf(widget.peer);
    if (devices.isEmpty) return (devices, null, null);
    final d = devices[_index.clamp(0, devices.length - 1)];
    final n = await messenger.crypto.safetyNumber(
      theirUserId: widget.peer,
      theirDeviceNumber: d.deviceNumber,
      theirIdentityKey: base64.decode(d.identityKey),
    );
    return (devices, n.displayable, base64.encode(n.scannable));
  }

  Future<void> _setVerified(KnownDevice d, bool verified) async {
    d.verifiedAt = verified ? DateTime.now() : null;
    await messenger.store.putDevice(d);
    setState(() {});
    messenger.changed(); // the chat header follows the store
  }

  Future<void> _scan(KnownDevice d) async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScanPage()),
    );
    if (scanned == null || !mounted) return;
    List<int> bytes;
    try {
      bytes = base64.decode(scanned);
    } on FormatException {
      bytes = const [];
    }
    final match = await messenger.crypto.verifyScannedSafetyNumber(
      theirUserId: widget.peer,
      theirDeviceNumber: d.deviceNumber,
      theirIdentityKey: base64.decode(d.identityKey),
      scanned: bytes,
    );
    if (!mounted) return;
    if (match) await _setVerified(d, true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(match
          ? 'The codes match. This device is now verified.'
          : 'The codes do NOT match. Do not mark this device verified; tell your administrator.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final name = messenger.contact(widget.peer)?.displayName ?? '';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to conversation',
          onPressed: () => context.pop(),
          icon: SkyIcon(SkyIcons.back, size: 21, color: t.textSecondary, stroke: 2.1),
        ),
        title: const Text('Safety number'),
      ),
      body: FutureBuilder<(List<KnownDevice>, String?, String?)>(
        future: _load(),
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) return const SizedBox.shrink();
          final (devices, digits, qr) = data;
          if (devices.isEmpty || digits == null || qr == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text('$name has no device to verify yet.',
                    textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary)),
              ),
            );
          }
          final d = devices[_index.clamp(0, devices.length - 1)];
          final groups = [for (var i = 0; i < 60; i += 5) digits.substring(i, i + 5)];
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(children: [
                  Text('Compare this code with $name in person or over a call you already trust.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13.5, height: 1.55, color: t.textSecondary)),
                  if (devices.length > 1) ...[
                    const SizedBox(height: 14),
                    Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                      for (var i = 0; i < devices.length; i++)
                        ChoiceChip(
                          label: Text('${_platform(devices[i].platform)} ${devices[i].deviceNumber}'),
                          avatar: devices[i].verifiedAt != null
                              ? SkyIcon(SkyIcons.check, size: 14, color: t.verified, stroke: 2.6)
                              : null,
                          selected: i == _index,
                          onSelected: (_) => setState(() => _index = i),
                        ),
                    ]),
                  ],
                  const SizedBox(height: 20),
                  Semantics(
                    label: 'QR code of the safety number',
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                      child: QrImageView(data: qr, size: 196, backgroundColor: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Semantics(
                    label: 'Safety number: ${groups.join(' ')}',
                    child: ExcludeSemantics(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                        decoration: BoxDecoration(
                          color: t.surface,
                          border: Border.all(color: t.border),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          childAspectRatio: 3.2,
                          children: [
                            for (final g in groups)
                              Center(
                                child: Text(g,
                                    style: TextStyle(
                                      fontFamily: SkyFonts.mono,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.6,
                                      color: t.textPrimary,
                                    )),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (d.verifiedAt != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10281F),
                        border: Border.all(color: const Color(0xFF1E5541)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        SkyIcon(SkyIcons.check, size: 17, color: t.verified, stroke: 2.5),
                        const SizedBox(width: 9),
                        Text('Verified on ${_date(d.verifiedAt!)}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF5FD6A8))),
                      ]),
                    ),
                  const SizedBox(height: 20),
                  // Scanning is on phones (the camera, decoded on the device
                  // by zxing-cpp; nothing leaves it). On a PC, compare digits.
                  if (Platform.isAndroid || Platform.isIOS) ...[
                    FilledButton(
                      onPressed: () => _scan(d),
                      child: const Text('Scan their code'),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (d.verifiedAt == null)
                    FilledButton(
                      onPressed: () => _setVerified(d, true),
                      child: const Text('The numbers match: mark as verified'),
                    )
                  else
                    OutlinedButton(onPressed: () => _setVerified(d, false), child: const Text('Mark as unverified')),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1410),
                      border: Border.all(color: const Color(0xFF4A3418)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SkyIcon(SkyIcons.warn, size: 17, color: t.caution, stroke: 2),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          'Each of $name’s devices has its own number. In Skyline a device’s key never changes, so a different number for a device you verified means something is wrong: Skyline blocks it and tells you.',
                          style: const TextStyle(fontSize: 12.5, height: 1.55, color: Color(0xFFD5B68A)),
                        ),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _platform(String? p) => switch (p) {
      'windows' => 'PC',
      'ios' => 'iPhone',
      'android' => 'Phone',
      _ => 'Device',
    };

String _date(DateTime d) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final l = d.toLocal();
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}

class _ScanPage extends StatelessWidget {
  const _ScanPage();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan their code')),
        body: ReaderWidget(
          codeFormat: Format.qrCode,
          showGallery: false,
          onScan: (code) {
            if (code.isValid && code.text != null) Navigator.of(context).pop(code.text);
          },
        ),
      );
}
