import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app/app_controller.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../data/activation_service.dart';

/// Board 1: activate this device with the administrator's one-time code.
class ActivationScreen extends ConsumerStatefulWidget {
  const ActivationScreen({super.key});

  @override
  ConsumerState<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends ConsumerState<ActivationScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _ready =>
      ActivationService.normalizeCode(_code.text) != null && _name.text.trim().isNotEmpty;

  Future<void> _activate() async {
    final app = ref.read(appControllerProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await app.activation!.activate(code: _code.text, deviceName: _name.text);
      await app.activated(session);
    } on ActivationFailure catch (f) {
      setState(() => _error = switch (f.error) {
            ActivationError.rejected =>
              "That code didn't work. It may be mistyped, already used or expired. Ask your administrator for a new one.",
            ActivationError.offline => "Can't reach the Skyline server. Check your connection and try again.",
            ActivationError.rateLimited => 'Too many attempts. Wait a few minutes and try again.',
            ActivationError.unknown => 'Something went wrong. Try again in a moment.',
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    final label = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: t.textSecondary,
    );
    final hint = TextStyle(fontSize: 12, height: 1.5, color: t.textSecondary);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - 52),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        SkyIcon(SkyIcons.shield, size: 26, color: t.accentText, stroke: 1.8),
                        const SizedBox(width: 10),
                        Text('SKYLINE',
                            style: TextStyle(
                              fontFamily: SkyFonts.display,
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                              letterSpacing: 2.7,
                              color: t.textPrimary,
                            )),
                      ]),
                      const SizedBox(height: 44),
                      Semantics(
                        header: true,
                        child: Text('Activate your device',
                            style: TextStyle(
                              fontFamily: SkyFonts.display,
                              fontWeight: FontWeight.w500,
                              fontSize: 30,
                              height: 1.2,
                              color: t.textPrimary,
                            )),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Your administrator has issued you an account. Enter the activation code you were given to set up this device.',
                        style: TextStyle(fontSize: 14, height: 1.55, color: t.textSecondary),
                      ),
                      const SizedBox(height: 32),
                      Text('ACTIVATION CODE', style: label),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _code,
                        enabled: !_busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.characters,
                        style: TextStyle(
                          fontFamily: SkyFonts.mono,
                          fontSize: 16,
                          letterSpacing: 1,
                          color: t.textPrimary,
                        ),
                        decoration: const InputDecoration(hintText: 'SKY-XXXXX-XXXXX-XXXXX-XXXXX'),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Text('Works once, on one device. The code is spent the moment this device is activated.',
                          style: hint),
                      const SizedBox(height: 18),
                      Text('NAME THIS DEVICE', style: label),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _name,
                        enabled: !_busy,
                        maxLength: 60,
                        decoration: const InputDecoration(hintText: 'e.g. My phone', counterText: ''),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Text('Your administrator sees this name in the device list.', style: hint),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Semantics(
                          liveRegion: true,
                          child: Text(_error!, style: TextStyle(fontSize: 13.5, height: 1.5, color: t.danger)),
                        ),
                      ],
                      const SizedBox(height: 28),
                      FilledButton(
                        onPressed: _busy || !_ready ? null : _activate,
                        child: _busy
                            ? const SizedBox(
                                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2))
                            : const Text('Activate this device'),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: t.surface,
                          border: Border.all(color: t.border),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SkyIcon(SkyIcons.lock, size: 18, color: t.accentText),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Skyline has no public sign-up. An account exists only when an administrator creates it — there is nothing here to register for.',
                              style: TextStyle(fontSize: 13, height: 1.55, color: t.textSecondary),
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        'Your encryption keys are generated on this device and never leave it.',
                        textAlign: TextAlign.center,
                        style: hint,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
