// Boards 27 and 29, rendered for real: a group conversation and its info
// screen on Alice's device after Bob and Carol write, saved as PNGs.
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
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/presentation/conversation_screen.dart';
import 'package:skyline/features/messages/presentation/group_info_screen.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobCode = String.fromEnvironment('BOB_CODE');
const carolCode = String.fromEnvironment('CAROL_CODE');
const groupId = String.fromEnvironment('GROUP_ID');
const shots = String.fromEnvironment('SHOTS');

final _frame = GlobalKey();

Future<void> _show(WidgetTester tester, Messenger me, Widget screen) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  final app = AppController()..messenger = me;
  await tester.pumpWidget(ProviderScope(
    overrides: [appControllerProvider.overrideWith((ref) => app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      builder: (context, child) => Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _frame,
          child: SizedBox(
            width: 390,
            height: 844,
            child: MediaQuery(data: const MediaQueryData(size: Size(390, 844)), child: child!),
          ),
        ),
      ),
      home: screen,
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
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

  testWidgets('a group, as Alice sees it', (tester) async {
    late Messenger alice;
    late Messenger bob;
    late Messenger carol;
    await tester.runAsync(() async {
      alice = await device(aliceCode, 'Alice test PC');
      bob = await device(bobCode, 'Bob test PC');
      carol = await device(carolCode, 'Carol test PC');
      for (final d in [alice, bob, carol]) {
        await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
        await d.refreshContacts();
        await d.refreshGroups();
      }
      await bob.sendText(groupId, 'Morning all. The gate code changes Friday.');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await carol.sendText(groupId, 'Thanks Bob, I will tell the night shift.');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final mine = await alice.sendText(groupId, 'Got it. See you all at 10.');
      await eventually(() async => (await alice.store.messages(groupId)).where((m) => !m.isNotice).length >= 3 ? true : null);
      // Board 27's details: a pin, reactions, a reply with its quote, an edit
      // and a deleted message.
      final bobs = (await alice.store.messages(groupId)).firstWhere((m) => m.text.startsWith('Morning'));
      await alice.pin(bobs.id, true);
      await eventually(() => bob.store.message(mine.id));
      await bob.react(mine.id, '👍');
      await carol.react(mine.id, '👍');
      final quote = await eventually(() => carol.store.message(bobs.id));
      await carol.sendText(groupId, 'Which gate, @Bob?', replyTo: carol.quoteOf(quote), mentions: [bobs.senderUserId!]);
      final oops = await bob.sendText(groupId, 'Wrong chat, sorry');
      await bob.deleteForEveryone(oops.id);
      await alice.editMessage(mine.id, 'Got it. See you all at 10:30.');
      await eventually(() async {
        final m = await alice.store.message(mine.id);
        return m != null && m.reactions.length == 2 ? true : null;
      });
      await eventually(() async => (await alice.store.message(oops.id))?.deleted == true ? true : null);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await _show(tester, alice, const ConversationScreen(peer: groupId));
    await _shot(tester, '27-group-conversation');
    // Board 28: the actions on one of Alice's own messages.
    await tester.longPress(find.textContaining('See you all at 10:30'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _shot(tester, '28-message-actions');
    await _show(tester, alice, const GroupInfoScreen(groupId: groupId));
    await _shot(tester, '29-group-info');
    await tester.runAsync(() async {
      alice.dispose();
      bob.dispose();
      carol.dispose();
    });
  });
}
