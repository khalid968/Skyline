// Board 40, for real: an operator suspends Bob through the dashboard API, and
// Alice's app shows him as unavailable at once. The chat stays; the composer,
// call buttons and timer go; a send is refused and marked; the chat list
// greys his row. Reinstated, everything comes back.
//   (same --dart-defines as groups_test.dart, including OPERATOR_PASSWORD,
//    plus --dart-define=SHOTS=<folder> for PNGs)
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/app/app_controller.dart';
import 'package:skyline/core/config.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/core/theme/app_theme.dart';
import 'package:skyline/features/chats/presentation/chat_list_screen.dart';
import 'package:skyline/features/messages/data/messenger.dart';
import 'package:skyline/features/messages/domain/models.dart';
import 'package:skyline/features/messages/presentation/conversation_screen.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobId = String.fromEnvironment('BOB_ID');
const bobCode = String.fromEnvironment('BOB_CODE');
const operatorPassword = String.fromEnvironment('OPERATOR_PASSWORD');
const shots = String.fromEnvironment('SHOTS');

final _frame = GlobalKey();

/// The dashboard's API, as an operator would call it (a bearer token: no
/// cookie, so no CSRF header is involved).
Future<void> asOperator(String path) async {
  final client = HttpClient();
  Future<Map<String, Object?>> call(String method, String p, {String? token, Object? body}) async {
    final req = await client.openUrl(method, AppConfig.apiBase.resolve(p));
    req.headers.contentType = ContentType.json;
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    expect(res.statusCode, lessThan(300), reason: '$method $p: $text');
    return text.isEmpty ? {} : jsonDecode(text) as Map<String, Object?>;
  }

  final login = await call('POST', '/admin/auth/login', body: {'username': 'fixture.admin', 'password': operatorPassword});
  await call('POST', path, token: login['token']! as String);
  client.close();
}

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

  testWidgets('a suspended contact is unavailable, and comes back when reinstated', (tester) async {
    expect(operatorPassword, isNotEmpty, reason: 'run with the fixture --dart-defines');
    late Messenger alice;
    late Messenger bob;
    await tester.runAsync(() async {
      alice = await device(aliceCode, 'Alice test PC');
      bob = await device(bobCode, 'Bob test PC');
      for (final d in [alice, bob]) {
        await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
        await d.refreshContacts();
      }
      final hello = await bob.sendText(alice.me, "I'll bring the badge list to the morning briefing.");
      await eventually(() => alice.store.message(hello.id));
      await alice.sendText(bobId, 'Great, thanks. See you at 8.');

      // The operator suspends Bob; Alice's app hears about it by itself.
      await asOperator('/admin/users/$bobId/suspend');
      await eventually(() async => alice.contact(bobId)?.suspended == true ? true : null);

      // A message written anyway is refused and marked.
      final refused = await alice.sendText(bobId, 'Are you coming in today?');
      await eventually(() async => (await alice.store.message(refused.id))?.status == MessageStatus.failed ? true : null);
    });

    await _show(tester, alice, const ConversationScreen(peer: bobId));
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text("You can't message or call Bob right now"), findsOneWidget);
    expect(find.text('Not sent · this account is unavailable'), findsOneWidget);
    expect(find.byTooltip('Voice call'), findsNothing);
    expect(find.byTooltip('Video call'), findsNothing);
    expect(find.byType(TextField), findsNothing, reason: 'no composer');
    await _shot(tester, '40-unavailable-chat');

    await _show(tester, alice, const ChatListScreen());
    expect(find.text('Unavailable'), findsOneWidget);
    await _shot(tester, '40-unavailable-list');

    // Reinstated: available again, and messages go.
    await tester.runAsync(() async {
      await asOperator('/admin/users/$bobId/reinstate');
      await eventually(() async => alice.contact(bobId)?.suspended == false ? true : null);
      final back = await alice.sendText(bobId, 'Welcome back.');
      await eventually(() async => (await alice.store.message(back.id))?.status != MessageStatus.sending ? true : null);
      expect((await alice.store.message(back.id))!.status, isNot(MessageStatus.failed));
    });
    await _show(tester, alice, const ConversationScreen(peer: bobId));
    expect(find.text('Unavailable'), findsNothing);
    expect(find.byTooltip('Voice call'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.runAsync(() async {
      alice.dispose();
      bob.dispose();
    });
  });
}
