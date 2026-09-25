// View once (board 24): the native side really keeps the window out of
// screenshots. No server needed.
//   flutter test integration_test/screen_protection_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/platform/screen_protection.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screen protection switches on and off', (_) async {
    final supported = Platform.isAndroid || Platform.isWindows;
    expect(await ScreenProtection.protect(true), supported);
    expect(await ScreenProtection.protect(false), supported);
  });
}
