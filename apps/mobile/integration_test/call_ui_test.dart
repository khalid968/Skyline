// Boards 32-35, rendered for real during a live call between two test
// devices: the chat header, the incoming call, the voice call, the video
// layout, the "On a call" bar, and the call lines in the chat. Every size is
// checked for layout overflow; PNGs go to SHOTS when it is set.
//   (same --dart-defines as groups_test.dart, plus --dart-define=SHOTS=<folder>)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/app/app_controller.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/core/theme/app_theme.dart';
import 'package:skyline/features/calls/data/call_service.dart';
import 'package:skyline/features/calls/presentation/call_overlay.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/presentation/conversation_screen.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');
const shots = String.fromEnvironment('SHOTS');

const sizes = {
  'phone-s': Size(360, 740),
  'phone': Size(412, 915),
  'windows': Size(1170, 620), // the owner's window, where the voice call overflowed
  'windows-short': Size(900, 480),
};

final _frame = GlobalKey();
final overflows = <String>[];

Future<void> _show(WidgetTester tester, Messenger me, CallService calls, Size size) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  final app = AppController()
    ..messenger = me
    ..calls = calls;
  await tester.pumpWidget(ProviderScope(
    overrides: [appControllerProvider.overrideWith((ref) => app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      builder: (context, child) => Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _frame,
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: MediaQueryData(size: size),
              child: CallOverlay(calls: calls, child: child!),
            ),
          ),
        ),
      ),
      home: const ConversationScreen(peer: aliceId),
    ),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  if (shots.isEmpty) return;
  final boundary = _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  });
  await File('$shots${Platform.pathSeparator}$name.png').writeAsBytes(bytes!);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('call screens fit at every size', (tester) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (d) {
      final text = d.exceptionAsString();
      if (text.contains('overflowed')) {
        overflows.add('$text\n${d.informationCollector?.call().take(3).join('\n') ?? ''}');
      } else {
        previous?.call(d);
      }
    };
    addTearDown(() => FlutterError.onError = previous);

    late Messenger alice;
    late Messenger bob;
    late CallService aCalls;
    late CallService bCalls;
    await tester.runAsync(() async {
      alice = await device(aliceCode, 'Alice test PC');
      bob = await device(bobCode, 'Bob test PC');
      for (final d in [alice, bob]) {
        await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
        await d.refreshContacts();
      }
      aCalls = CallService(messenger: alice, api: alice.api, captureMedia: false);
      bCalls = CallService(messenger: bob, api: bob.api, captureMedia: false);
      await bob.sendText(aliceId, 'Can you call me when you land?');
      await eventually(() async => (await alice.store.messages(bobId)).isNotEmpty ? true : null);
    });

    for (final e in sizes.entries) {
      final tag = e.key;
      // The chat, with its call buttons (board 35).
      await _show(tester, bob, bCalls, e.value);
      await _shot(tester, '35-chat-header-$tag');

      // Incoming (board 32).
      await tester.runAsync(() async {
        await aCalls.start(bobId, video: false);
        await eventually(() async => bCalls.current?.phase == CallPhase.incoming ? true : null);
      });
      await _settle(tester);
      await _shot(tester, '32-incoming-$tag');

      // Voice call, connected (board 33).
      await tester.runAsync(() async {
        await bCalls.accept();
        await eventually(() async => bCalls.current?.phase == CallPhase.connected ? true : null);
      });
      await _settle(tester);
      await _shot(tester, '33-voice-$tag');

      // The video layout (board 34), as if Alice turned her camera on.
      bCalls.current!.remoteVideo = true;
      bCalls.toggleMute();
      await _settle(tester);
      await _shot(tester, '34-video-$tag');
      bCalls.current!.remoteVideo = false;
      bCalls.toggleMute();

      // Minimised: the "On a call" bar over the chat (board 35).
      await tester.tap(find.byKey(const ValueKey('call-minimise')));
      await _settle(tester);
      await _shot(tester, '35-on-a-call-$tag');

      // Hang up; the chat gets its call line.
      await tester.runAsync(() async {
        await aCalls.hangUp();
        await eventually(() async => bCalls.current == null ? true : null);
        await eventually(() async => aCalls.current == null ? true : null);
      });
      await _settle(tester);
      await _shot(tester, '35-call-line-$tag');
    }

    await tester.runAsync(() async {
      aCalls.dispose();
      bCalls.dispose();
      alice.dispose();
      bob.dispose();
    });
    expect(overflows, isEmpty, reason: overflows.join('\n---\n'));
  });
}
