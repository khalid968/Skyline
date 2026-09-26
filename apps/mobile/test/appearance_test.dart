// Board 44: whatever colours a person picks, text stays readable and the
// security colours keep their meaning. Board 43: an update is never installed
// unless it is exactly what the server published.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyline/core/app/app_controller.dart';
import 'package:skyline/core/theme/appearance.dart';
import 'package:skyline/core/theme/tokens.dart';
import 'package:skyline/features/settings/presentation/appearance_screen.dart';
import 'package:skyline/features/updates/data/release_service.dart';
import 'package:skyline/features/updates/data/update_installer.dart';

const bases = {
  'midnight': SkylineTokens.dark,
  'black': AppearancePresets.black,
  'light': SkylineTokens.light,
  'sand': AppearancePresets.sand,
};

void main() {
  group('colours stay readable', () {
    for (final base in bases.entries) {
      test('every preset on ${base.key}', () {
        for (final p in AppearancePresets.accents) {
          final t = (Appearance()..update(accent: p.id)).tokens(base.value);
          expect(ColourMath.contrast(t.onAccent, t.accentFill), greaterThanOrEqualTo(4.5), reason: '${p.name} text');
          expect(ColourMath.contrast(t.accentText, t.ground), greaterThanOrEqualTo(4.5), reason: '${p.name} links');
          expect(t.verified, base.value.verified);
          expect(t.caution, base.value.caution);
          expect(t.danger, base.value.danger);
        }
      });
    }

    test('any colour at all: text and links adapt', () {
      for (final c in const [
        Color(0xFFFFFF00),
        Color(0xFFF5F5F5),
        Color(0xFF101010),
        Color(0xFF7F7F7F),
        Color(0xFF00FF88)
      ]) {
        for (final base in bases.values) {
          final t = (Appearance()..update(accent: 'custom', customAccent: c)).tokens(base);
          expect(ColourMath.contrast(t.onAccent, t.accentFill), greaterThanOrEqualTo(4.5), reason: ColourMath.hex(c));
          expect(ColourMath.contrast(t.accentText, t.ground), greaterThanOrEqualTo(4.5), reason: ColourMath.hex(c));
        }
      }
    });

    test('a light chat background in a dark theme: incoming bubbles switch to dark text', () {
      for (final bg in const [
        Color(0xFFF6E7EA),
        Color(0xFFFFFFFF),
        Color(0xFF000000),
        Color(0xFF808080),
        Color(0xFF1B2A3A)
      ]) {
        final t = (Appearance()..update(background: 'custom', customBackground: bg)).tokens(SkylineTokens.dark);
        expect(t.chatBackground, bg);
        expect(ColourMath.contrast(t.bubbleIncomingText, t.bubbleIncoming), greaterThanOrEqualTo(4.5),
            reason: ColourMath.hex(bg));
        expect(ColourMath.contrast(t.incomingAccent, t.bubbleIncoming), greaterThanOrEqualTo(4.5),
            reason: ColourMath.hex(bg));
      }
    });

    test('the default is exactly the approved design', () {
      final t = Appearance().tokens(SkylineTokens.dark);
      expect(t.accentFill, SkylineTokens.dark.accentFill);
      expect(t.accentText, SkylineTokens.dark.accentText);
      expect(t.bubbleIncoming, SkylineTokens.dark.bubbleIncoming);
      expect(t.onAccent, Colors.white);
      expect(t.chatBackground, SkylineTokens.dark.ground);
    });

    test('colours near green, amber or red are flagged', () {
      expect(ColourMath.nearSecurityHue(const Color(0xFF2EAD5B)), isTrue);
      expect(ColourMath.nearSecurityHue(const Color(0xFFE8A33D)), isTrue);
      expect(ColourMath.nearSecurityHue(const Color(0xFFD02020)), isTrue);
      expect(ColourMath.nearSecurityHue(const Color(0xFF3A63D8)), isFalse);
      expect(ColourMath.nearSecurityHue(const Color(0xFF808080)), isFalse);
    });

    test('theme choice picks the mode', () {
      final a = Appearance();
      expect(a.mode, ThemeMode.system);
      a.update(theme: ThemeChoice.black);
      expect(a.mode, ThemeMode.dark);
      expect(a.darkTheme.scaffoldBackgroundColor, const Color(0xFF000000));
      a.update(theme: ThemeChoice.sand);
      expect(a.mode, ThemeMode.light);
      expect(a.lightTheme.scaffoldBackgroundColor, AppearancePresets.sand.ground);
    });
  });

  group('the appearance screen', () {
    for (final size in const [Size(320, 568), Size(412, 915), Size(1280, 800)]) {
      testWidgets('fits at ${size.width.toInt()}x${size.height.toInt()} and applies a tap', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final app = AppController();
        await tester.pumpWidget(ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => app)],
          child: ListenableBuilder(
            listenable: app.appearance,
            builder: (context, _) => MaterialApp(
              theme: app.appearance.lightTheme,
              darkTheme: app.appearance.darkTheme,
              themeMode: ThemeMode.dark,
              home: const AppearanceScreen(),
            ),
          ),
        ));
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(find.text('Black'), 100, scrollable: list);
        await tester.ensureVisible(find.text('Black'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Black'));
        await tester.pump();
        expect(app.appearance.theme, ThemeChoice.black);
        await tester.scrollUntilVisible(find.byTooltip('Violet'), 200, scrollable: list);
        await tester.ensureVisible(find.byTooltip('Violet'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Violet'));
        await tester.pump();
        expect(app.appearance.accent, 'violet');
        await tester.scrollUntilVisible(find.text('Grid'), 200, scrollable: list);
        await tester.ensureVisible(find.text('Grid'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Grid'));
        await tester.pump();
        expect(app.appearance.pattern, ChatPattern.grid);
      });
    }
  });

  group('update download', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('skyline-update-test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Release release(String sha) => Release(
          version: '9.0.0',
          notes: const [],
          url: Uri.parse('https://chat.example.org/downloads/skyline-9.0.0.apk'),
          sha256: sha,
        );

    test('a file that does not match the published checksum is deleted, never installed', () async {
      final i = UpdateInstaller(
        client: MockClient((_) async => http.Response('not the real app', 200)),
        dir: () async => tmp,
      );
      await i.run(release('0' * 64));
      expect(i.phase, InstallPhase.failed);
      expect(i.problem, contains("didn't match"));
      expect(tmp.listSync(recursive: true).whereType<File>(), isEmpty);
    }, skip: !UpdateInstaller.inApp ? 'installs in the app only on Android and Windows' : false);

    test('a failed download says so', () async {
      final i = UpdateInstaller(client: MockClient((_) async => http.Response('', 404)), dir: () async => tmp);
      await i.run(release('0' * 64));
      expect(i.phase, InstallPhase.failed);
      expect(i.problem, contains("Couldn't download"));
    }, skip: !UpdateInstaller.inApp ? 'installs in the app only on Android and Windows' : false);

    test('without a checksum or over plain http it never installs in the app', () {
      expect(
          UpdateInstaller.canInstallInApp(
              Release(version: '9.0.0', notes: const [], url: Uri.parse('https://x/a.apk'))),
          isFalse);
      expect(
          UpdateInstaller.canInstallInApp(
              Release(version: '9.0.0', notes: const [], url: Uri.parse('http://x/a.apk'), sha256: 'a' * 64)),
          isFalse);
    });
  });
}
