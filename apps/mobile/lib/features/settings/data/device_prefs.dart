import 'package:flutter/foundation.dart';

import '../../messages/data/local_store.dart';

/// How an incoming call rings while Skyline is open (board 48).
enum CallStyle {
  /// Skyline's own call screen (the default, how it always worked).
  skyline,

  /// The phone's own call screen, even while Skyline is open.
  phone,
}

/// Choices that belong to this device only (boards 48 and 49), kept in the
/// vault like Appearance. Exists from the start with the defaults, which are
/// also what applies before the vault is open.
class DevicePrefs extends ChangeNotifier {
  CallStyle callStyle = CallStyle.skyline;

  /// Windows (board 49): open by the clock when Windows starts. On by
  /// default (owner decision 2026-10-01).
  bool startWithWindows = true;

  /// Windows: closing the window hides Skyline instead of quitting.
  bool keepRunning = true;

  /// Windows: notifications say who a message is from. Never its text.
  bool showSender = true;

  /// Windows: whether "start with Windows" has been set up once on this
  /// device. The default is applied only the first time, so turning it off
  /// in Task Manager is never undone behind the person's back.
  bool startupApplied = false;

  LocalStore? _store;

  Future<void> load(LocalStore store) async {
    _store = store;
    callStyle = CallStyle.skyline;
    startWithWindows = true;
    keepRunning = true;
    showSender = true;
    startupApplied = false;
    try {
      final m = await store.setting('device');
      if (m is Map) {
        callStyle = CallStyle.values.asNameMap()[m['callStyle']] ?? callStyle;
        startWithWindows = m['startWithWindows'] as bool? ?? startWithWindows;
        keepRunning = m['keepRunning'] as bool? ?? keepRunning;
        showSender = m['showSender'] as bool? ?? showSender;
        startupApplied = m['startupApplied'] as bool? ?? startupApplied;
      }
    } on Object {
      // unreadable: keep the defaults
    }
    notifyListeners();
  }

  void update({CallStyle? callStyle, bool? startWithWindows, bool? keepRunning, bool? showSender, bool? startupApplied}) {
    this.callStyle = callStyle ?? this.callStyle;
    this.startWithWindows = startWithWindows ?? this.startWithWindows;
    this.keepRunning = keepRunning ?? this.keepRunning;
    this.showSender = showSender ?? this.showSender;
    this.startupApplied = startupApplied ?? this.startupApplied;
    notifyListeners();
    _store?.putSetting('device', {
      'callStyle': this.callStyle.name,
      'startWithWindows': this.startWithWindows,
      'keepRunning': this.keepRunning,
      'showSender': this.showSender,
      'startupApplied': this.startupApplied,
    });
  }
}
