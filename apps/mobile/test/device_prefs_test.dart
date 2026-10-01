// Boards 48-49: this device's call style and Windows background choices.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyline/core/app/app_controller.dart';
import 'package:skyline/features/settings/data/device_prefs.dart';
import 'package:skyline/features/settings/presentation/calls_settings_screen.dart';

void main() {
  test('the defaults are the approved ones', () {
    final p = DevicePrefs();
    expect(p.callStyle, CallStyle.skyline); // today's behaviour stays the default
    expect(p.startWithWindows, isTrue); // owner decision 2026-10-01
    expect(p.keepRunning, isTrue);
    expect(p.showSender, isTrue);
    expect(p.startupApplied, isFalse);
  });

  group('the calls screen', () {
    for (final size in const [Size(320, 568), Size(412, 915), Size(1280, 800)]) {
      testWidgets('fits at ${size.width.toInt()}x${size.height.toInt()} and switches style', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final app = AppController();
        await tester.pumpWidget(ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => app)],
          child: MaterialApp(theme: app.appearance.darkTheme, home: const CallsSettingsScreen()),
        ));
        expect(find.text('This is how Skyline works today.'), findsOneWidget);
        await tester.tap(find.text('Like a phone call'));
        await tester.pump();
        expect(app.device.callStyle, CallStyle.phone);
        expect(find.text('Skyline opens when you answer, for video, mute and speaker.'), findsOneWidget);
        await tester.tap(find.text('Skyline’s call screen (default)'));
        await tester.pump();
        expect(app.device.callStyle, CallStyle.skyline);
      });
    }
  });
}
