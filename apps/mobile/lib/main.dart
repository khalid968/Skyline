import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app/app_controller.dart';
import 'core/push/push.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/settings/presentation/lock_screen.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads the crypto core (Signal's libsignal, built from crypto-core/).
  await RustLib.init();
  // Firebase, for content-free wake-ups only (Android).
  await initPush();
  runApp(const ProviderScope(child: SkylineApp()));
}

class SkylineApp extends ConsumerWidget {
  const SkylineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Skyline',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) => _LockGate(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// While the app lock is engaged, the lock screen REPLACES the app: nothing of
/// the conversations underneath is even built.
class _LockGate extends ConsumerWidget {
  const _LockGate({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appControllerProvider).lock;
    if (lock == null) return child;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) => lock.locked
          ? Navigator(
              pages: [MaterialPage<void>(child: LockScreen(lock: lock))],
              onDidRemovePage: (_) {},
            )
          : child,
    );
  }
}
