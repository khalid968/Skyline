// Board 42: "Please update" covers the app on a 426, and fits the smallest phone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyline/core/api/api_client.dart';
import 'package:skyline/core/theme/app_theme.dart';
import 'package:skyline/features/updates/data/release_service.dart';
import 'package:skyline/features/updates/presentation/update_widgets.dart';

void main() {
  tearDown(() => ApiClient.updateRequired.value = null);

  for (final size in const [Size(320, 568), Size(412, 915), Size(1280, 800)]) {
    testWidgets('gate at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final releases = ReleaseService.from(
        fetch: (_) async => {
          'minimum': '0.0.0',
          'latest': {
            'version': '9.0.0',
            'notes': ['Security fix'],
            'windows': {'url': '/downloads/skyline-setup-9.0.0.exe'},
            'android': {'url': '/downloads/skyline-9.0.0.apk'},
            'ios': {'url': 'https://testflight.apple.com/join/x'},
            'linux': {'url': '/downloads/x'},
            'macos': {'url': '/downloads/x'},
          },
        },
        base: Uri.parse('https://chat.example.org/api'),
      );
      await releases.check();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: UpdateRequiredGate(releases: releases, child: const Text('the app')),
      ));
      expect(find.text('the app'), findsOneWidget);

      ApiClient.updateRequired.value = '2.0.0';
      releases.start(); // listens to 426s
      await tester.pump();
      expect(find.text('Please update Skyline'), findsOneWidget);
      expect(find.text('Download 9.0.0'), findsOneWidget);
      expect(find.text('the app'), findsNothing);
      releases.dispose();
    });
  }
}
