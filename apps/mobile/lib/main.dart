import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app/app_controller.dart';
import 'core/platform/desktop_shell.dart';
import 'core/push/push.dart';
import 'core/routing/app_router.dart';
import 'features/calls/presentation/call_overlay.dart';
import 'features/settings/presentation/lock_screen.dart';
import 'features/updates/presentation/update_widgets.dart';
import 'shared/widgets/avatar.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads the crypto core (Signal's libsignal, built from crypto-core/).
  await RustLib.init();
  // Firebase, for content-free wake-ups only (Android).
  await initPush();
  // Windows (board 49): the icon by the clock, notifications, and closing
  // to the background.
  await DesktopShell.init();
  runApp(const ProviderScope(child: SkylineApp()));
}

class SkylineApp extends ConsumerWidget {
  const SkylineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final appearance = ref.watch(appControllerProvider.select((c) => c.appearance));

    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => MaterialApp.router(
        title: 'Skyline',
        debugShowCheckedModeBanner: false,
        theme: appearance.lightTheme,
        darkTheme: appearance.darkTheme,
        themeMode: appearance.mode,
        routerConfig: router,
        builder: (context, child) => ProfilePhotoScope(
          photos: ref.watch(appControllerProvider).photos,
          child: _Calls(child: _DesktopLinks(child: _LockGate(child: _Updates(child: child ?? const SizedBox.shrink())))),
        ),
      ),
    );
  }
}

/// Board 49: a click on a message notification opens that chat.
class _DesktopLinks extends ConsumerStatefulWidget {
  const _DesktopLinks({required this.child});
  final Widget child;

  @override
  ConsumerState<_DesktopLinks> createState() => _DesktopLinksState();
}

class _DesktopLinksState extends ConsumerState<_DesktopLinks> {
  @override
  void initState() {
    super.initState();
    DesktopShell.openChat = (peer) {
      if (ref.read(appControllerProvider).phase != AppPhase.ready) return;
      ref.read(appRouterProvider).push('/chat/$peer');
    };
  }

  @override
  void dispose() {
    DesktopShell.openChat = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Board 42: a version the server no longer supports covers the app with
/// "Please update" (inside the lock: a locked app stays locked).
class _Updates extends ConsumerWidget {
  const _Updates({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      UpdateRequiredGate(
          releases: ref.watch(appControllerProvider).releases,
          installer: ref.watch(appControllerProvider).installer,
          child: child);
}

/// A call rings over everything, the lock screen included (like a phone): it
/// shows only who is calling, and answering opens only the call.
class _Calls extends ConsumerWidget {
  const _Calls({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      CallOverlay(calls: ref.watch(appControllerProvider).calls, child: child);
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
