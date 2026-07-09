import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Root route table. Feature routes are registered here as each feature
/// lands; kept to a single placeholder route until Phase 6 (Messaging UI).
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const _SkylineRoot(),
      ),
    ],
  );
});

class _SkylineRoot extends StatelessWidget {
  const _SkylineRoot();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Skyline'),
      ),
    );
  }
}
