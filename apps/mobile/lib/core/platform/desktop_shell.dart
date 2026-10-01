import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/calls/data/call_service.dart';
import '../../features/messages/data/messenger.dart';
import '../../features/settings/data/device_prefs.dart';

/// Board 49: Skyline on Windows keeps working in the background.
///
/// - Starts with Windows (on by default), quietly: the runner starts it hidden
///   when given [backgroundFlag], with only the icon by the clock.
/// - Closing the window hides it (when "keep running" is on); the icon's menu
///   opens it again or quits.
/// - While the window is hidden or not in front, a message shows a Windows
///   notification that says who it is from (or only "New message"), never its
///   text, and a call shows one with Answer and Decline.
///
/// One copy runs at a time (the runner hands a second launch over to the
/// first): two copies would open the same vault.
abstract final class DesktopShell {
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// What the Run key starts Skyline with.
  static const backgroundFlag = '--background';

  static final _notices = FlutterLocalNotificationsPlugin();
  static final _window = _WindowWatcher();
  static final _tray = _TrayWatcher();
  static bool _ready = false;

  static DevicePrefs? _prefs;
  static Messenger? _messenger;
  static CallService? _calls;

  /// Opens a chat once the window is showing (set by the app's widget tree).
  static void Function(String peer)? openChat;

  /// Before runApp.
  static Future<void> init() async {
    if (!supported) return;
    await windowManager.ensureInitialized();
    windowManager.addListener(_window);
    trayManager.addListener(_tray);
    try {
      await trayManager.setIcon('assets/icons/tray.ico');
      await trayManager.setToolTip('Skyline');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Open Skyline'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit Skyline'),
      ]));
    } on Object catch (e) {
      debugPrint('tray unavailable: $e');
    }
    try {
      await _notices.initialize(
        settings: InitializationSettings(
          windows: WindowsInitializationSettings(
            appName: 'Skyline',
            appUserModelId: 'Skyline.Messenger${kReleaseMode ? '' : '.Dev'}',
            // Fixed for good: Windows ties notification clicks to it.
            guid: !kReleaseMode
                ? '5c0f8a62-6c43-4a8e-9a3b-4f0b7c9e2d11'
                : '9d4b6e1a-2f7c-4c1e-8b5d-3a6e0f1c7b42',
            iconPath: _assetPath('assets/icons/tray.ico'),
          ),
        ),
        onDidReceiveNotificationResponse: _onNotice,
      );
      _ready = true;
    } on Object catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  static String _assetPath(String asset) =>
      [File(Platform.resolvedExecutable).parent.path, 'data', 'flutter_assets', ...asset.split('/')]
          .join(Platform.pathSeparator);

  /// Once the vault is open: the person's choices take effect.
  static Future<void> attach(DevicePrefs prefs) async {
    if (!supported) return;
    _prefs?.removeListener(_applyPrefs);
    _prefs = prefs..addListener(_applyPrefs);
    launchAtStartup.setup(
      // The installed app's entry is "Skyline" (the uninstaller removes it).
      appName: kReleaseMode ? 'Skyline' : 'Skyline (development)',
      // Quoted: the install folder may contain spaces.
      appPath: '"${Platform.resolvedExecutable}"',
      args: const [backgroundFlag],
    );
    if (!prefs.startupApplied) {
      // First run: the default applies once (owner decision 2026-10-01).
      // A development build never starts itself.
      prefs.update(startupApplied: true, startWithWindows: kReleaseMode && prefs.startWithWindows);
    }
    await _applyPrefs();
  }

  static Future<void> _applyPrefs() async {
    final p = _prefs;
    if (p == null) return;
    try {
      await windowManager.setPreventClose(p.keepRunning);
      final on = await launchAtStartup.isEnabled();
      if (p.startWithWindows && !on) await launchAtStartup.enable();
      if (!p.startWithWindows && on) await launchAtStartup.disable();
    } on Object catch (e) {
      debugPrint('desktop settings not applied: $e');
    }
  }

  /// Whether "Start with Windows" is really on right now (it can also be
  /// turned off in Task Manager).
  static Future<bool> startsWithWindows() async {
    if (!supported) return false;
    try {
      return await launchAtStartup.isEnabled();
    } on Object {
      return false;
    }
  }

  /// The services whose events become notifications.
  static void watch({required Messenger messenger, required CallService calls}) {
    if (!supported) return;
    _messenger?.onIncoming = null;
    _calls?.removeListener(_onCalls);
    _messenger = messenger..onIncoming = _onIncoming;
    _calls = calls..addListener(_onCalls);
  }

  static void unwatch() {
    _messenger?.onIncoming = null;
    _calls?.removeListener(_onCalls);
    _messenger = null;
    _calls = null;
  }

  static Future<bool> _inFront() async {
    try {
      return await windowManager.isVisible() && await windowManager.isFocused() && !await windowManager.isMinimized();
    } on Object {
      return true;
    }
  }

  static int _nextId = 1;

  /// Test hook: the last notification's title and payload.
  @visibleForTesting
  static (String, String)? lastNotice;
  static final _lastShownAt = <String, DateTime>{};

  static Future<void> _onIncoming(String peer, {required String chatName, String? senderName}) async {
    if (!_ready || await _inFront()) return;
    // One notice per chat every few seconds: a burst (or the backlog fetched
    // when Windows starts) must not stack up a pile of them.
    final now = DateTime.now();
    final last = _lastShownAt[peer];
    if (last != null && now.difference(last) < const Duration(seconds: 5)) return;
    _lastShownAt[peer] = now;
    final who = _prefs?.showSender ?? true;
    final title = !who
        ? 'New message'
        : senderName == null
            ? 'New message from $chatName'
            : 'New message from $senderName in $chatName';
    lastNotice = (title, 'chat:$peer');
    try {
      await _notices.show(id: _nextId++, title: title, payload: 'chat:$peer');
    } on Object catch (e) {
      debugPrint('notice not shown: $e');
    }
  }

  static String? _notifiedCall;

  static void _onCalls() {
    final c = _calls?.current;
    if (c == null || c.outgoing || c.phase != CallPhase.incoming || c.id == _notifiedCall) return;
    _notifiedCall = c.id;
    unawaited(_showCall(c));
  }

  static Future<void> _showCall(Call c) async {
    if (!_ready || await _inFront()) return;
    final name = (_prefs?.showSender ?? true) ? (_messenger?.contact(c.peer)?.displayName ?? 'Contact') : 'Skyline';
    lastNotice = (name, 'call:open:${c.id}');
    try {
      await _notices.show(
        id: _nextId++,
        title: name,
        body: c.video ? 'Incoming video call' : 'Incoming voice call',
        payload: 'call:open:${c.id}',
        notificationDetails: NotificationDetails(
          windows: WindowsNotificationDetails(
            scenario: WindowsNotificationScenario.incomingCall,
            // Skyline plays its own chime while it rings.
            audio: WindowsNotificationAudio.silent(),
            actions: [
              WindowsAction(content: 'Decline', arguments: 'call:decline:${c.id}', buttonStyle: WindowsButtonStyle.critical),
              WindowsAction(content: 'Answer', arguments: 'call:answer:${c.id}', buttonStyle: WindowsButtonStyle.success),
            ],
          ),
        ),
      );
    } on Object catch (e) {
      debugPrint('call notice not shown: $e');
    }
  }

  static void _onNotice(NotificationResponse r) {
    final p = r.payload ?? '';
    if (p.startsWith('chat:')) {
      unawaited(showWindow());
      openChat?.call(p.substring(5));
      return;
    }
    final parts = p.split(':');
    if (parts.length != 3 || parts[0] != 'call') return;
    final calls = _calls;
    final c = calls?.current;
    // A notice for a call that already stopped ringing does nothing.
    final ringing = c != null && c.id == parts[2] && c.phase == CallPhase.incoming;
    switch (parts[1]) {
      case 'answer':
        unawaited(showWindow());
        if (ringing) unawaited(calls!.accept());
      case 'decline':
        if (ringing) unawaited(calls!.decline());
      default:
        unawaited(showWindow());
    }
  }

  static Future<void> showWindow() async {
    if (!supported) return;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Really quits (the tray's Quit, or closing with "keep running" off).
  static Future<void> quit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}

class _WindowWatcher with WindowListener {
  @override
  void onWindowClose() {
    // Only reached while closing is prevented, i.e. "keep running" is on.
    unawaited(windowManager.hide());
  }
}

class _TrayWatcher with TrayListener {
  @override
  void onTrayIconMouseDown() => unawaited(DesktopShell.showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(DesktopShell.showWindow());
      case 'quit':
        unawaited(DesktopShell.quit());
    }
  }
}
