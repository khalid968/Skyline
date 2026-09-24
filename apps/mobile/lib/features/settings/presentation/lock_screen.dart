import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/sky_icon.dart';
import '../data/app_lock.dart';

/// Board 14: Skyline is locked. Also used, in `setup` mode, to choose a PIN.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.title,
    required this.prompt,
    required this.onComplete,
    this.onBiometrics,
    this.footer,
  });

  final String title;
  final String prompt;

  /// Called with 6 digits. Returns an error line to show, or null to clear.
  final Future<String?> Function(String pin) onComplete;
  final VoidCallback? onBiometrics;
  final String? footer;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 6) {
      setState(() => _busy = true);
      final err = await widget.onComplete(_pin);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = err;
        _pin = '';
      });
    }
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    Widget key(String d) => SizedBox(
          height: 66,
          child: Semantics(
            button: true,
            label: 'Digit $d',
            child: Material(
              color: t.surface,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _digit(d),
                child: Center(
                  child: ExcludeSemantics(
                    child: Text(d,
                        style: TextStyle(fontFamily: SkyFonts.display, fontSize: 26, color: t.textPrimary)),
                  ),
                ),
              ),
            ),
          ),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 48, 32, 28),
        child: Column(children: [
          SkyIcon(SkyIcons.shield, size: 44, color: t.accentText, stroke: 1.6),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text(widget.title,
                style: TextStyle(fontFamily: SkyFonts.display, fontSize: 24, color: t.textPrimary)),
          ),
          const SizedBox(height: 8),
          Text(widget.prompt, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: t.textSecondary)),
          const SizedBox(height: 30),
          Semantics(
            label: '${_pin.length} of 6 digits entered',
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < 6; i++)
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? t.accentText : Colors.transparent,
                    border: Border.all(color: i < _pin.length ? t.accentText : t.border, width: 2),
                  ),
                ),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.danger)),
            ),
          ],
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              crossAxisSpacing: 22,
              childAspectRatio: 1.25,
              children: [
                for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9']) key(d),
                if (widget.onBiometrics != null)
                  IconButton(
                    tooltip: 'Unlock with face or fingerprint',
                    onPressed: widget.onBiometrics,
                    icon: SkyIcon(SkyIcons.lock, size: 28, color: t.accentText, stroke: 1.8),
                  )
                else
                  const SizedBox.shrink(),
                key('0'),
                IconButton(
                  tooltip: 'Delete last digit',
                  onPressed: _back,
                  icon: SkyIcon(SkyIcons.back, size: 26, color: t.textSecondary),
                ),
              ],
            ),
          ),
          if (widget.footer != null) ...[
            const SizedBox(height: 22),
            Text(widget.footer!,
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, height: 1.5, color: t.textSecondary)),
          ],
        ]),
      ),
    );
  }
}

/// Shown over everything while the app is locked.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock});
  final AppLock lock;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.lock.biometrics) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.lock.tryBiometrics());
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = widget.lock;
    return Scaffold(
      body: PinPad(
        title: 'Skyline is locked',
        prompt: lock.biometrics ? 'Enter your PIN, or use your face or fingerprint' : 'Enter your PIN',
        onBiometrics: lock.biometrics ? () => unawaited(lock.tryBiometrics()) : null,
        footer: 'After 5 wrong PINs, you wait 30 seconds, and longer after each further miss.',
        onComplete: (pin) async {
          final r = await lock.tryPin(pin);
          if (r.ok) return null;
          if (r.wait > 0) return 'Too many wrong PINs. Try again in ${_duration(r.wait)}.';
          return 'That PIN is not right.';
        },
      ),
    );
  }
}

/// Choosing a PIN: enter it twice.
Future<String?> choosePin(BuildContext context) => Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ChoosePin()),
    );

class _ChoosePin extends StatefulWidget {
  const _ChoosePin();

  @override
  State<_ChoosePin> createState() => _ChoosePinState();
}

class _ChoosePinState extends State<_ChoosePin> {
  String? _first;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: PinPad(
          key: ValueKey(_first),
          title: _first == null ? 'Choose a PIN' : 'Enter it again',
          prompt: _first == null ? '6 digits. Only you know it; nobody can reset it.' : 'To make sure it is right.',
          footer: 'Forget your PIN and you will need a new activation code, and messages on this device will be lost.',
          onComplete: (pin) async {
            if (_first == null) {
              setState(() => _first = pin);
              return null;
            }
            if (pin != _first) {
              setState(() => _first = null);
              return 'The two PINs did not match. Start again.';
            }
            Navigator.of(context).pop(pin);
            return null;
          },
        ),
      );
}

String _duration(int seconds) {
  if (seconds < 60) return '$seconds seconds';
  final m = (seconds / 60).ceil();
  return '$m minute${m == 1 ? '' : 's'}';
}
