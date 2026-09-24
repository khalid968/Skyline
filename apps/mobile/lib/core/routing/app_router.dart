import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/activation_screen.dart';
import '../../features/chats/presentation/chat_list_screen.dart';
import '../../features/messages/presentation/conversation_screen.dart';
import '../../features/settings/presentation/privacy_screen.dart';
import '../../features/settings/presentation/safety_number_screen.dart';
import '../app/app_controller.dart';
import '../theme/tokens.dart';

/// Routes follow the app's phase: nothing but activation until this device is
/// activated, nothing at all if its vault cannot be opened.
final appRouterProvider = Provider<GoRouter>((ref) {
  final app = ref.watch(appControllerProvider.notifier);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: app,
    redirect: (context, state) {
      final here = state.matchedLocation;
      return switch (app.phase) {
        AppPhase.loading => here == '/loading' ? null : '/loading',
        AppPhase.activate => here == '/activate' ? null : '/activate',
        AppPhase.vaultLocked || AppPhase.failed => here == '/problem' ? null : '/problem',
        AppPhase.ready => (here == '/loading' || here == '/activate' || here == '/problem') ? '/' : null,
      };
    },
    routes: [
      GoRoute(path: '/loading', builder: (context, state) => const _Loading()),
      GoRoute(path: '/activate', builder: (context, state) => const ActivationScreen()),
      GoRoute(path: '/problem', builder: (context, state) => _Problem(locked: app.phase == AppPhase.vaultLocked)),
      GoRoute(path: '/', builder: (context, state) => const ChatListScreen()),
      GoRoute(path: '/settings', builder: (context, state) => const PrivacyScreen()),
      GoRoute(
        path: '/chat/:peer',
        builder: (context, s) => ConversationScreen(peer: s.pathParameters['peer']!),
        routes: [
          GoRoute(
            path: 'verify',
            builder: (context, s) => SafetyNumberScreen(peer: s.pathParameters['peer']!),
          ),
        ],
      ),
    ],
  );
});

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _Problem extends StatelessWidget {
  const _Problem({required this.locked});
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final t = context.sky;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locked ? 'Skyline can’t open its keys on this device' : 'Skyline couldn’t start',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: SkyFonts.display, fontSize: 22, color: t.textPrimary)),
            const SizedBox(height: 14),
            Text(
              locked
                  ? 'The key that protects this device’s messages is missing from its secure storage (for example after a reset). Nothing can be read without it, by design. Ask your administrator for a new activation code to start again on this device.'
                  : 'Something went wrong while opening Skyline. Close it and open it again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.55, color: t.textSecondary),
            ),
          ]),
        ),
      ),
    );
  }
}
