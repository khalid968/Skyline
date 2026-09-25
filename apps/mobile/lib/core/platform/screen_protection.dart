import 'package:flutter/services.dart';

/// Keeps what is on screen out of screenshots and screen recordings while a
/// view-once photo or video is open (board 24). Android: FLAG_SECURE.
/// Windows: excluded from capture. iPhone: not possible, so [protect]
/// returns false and the viewer says so.
class ScreenProtection {
  static const _channel = MethodChannel('skyline/screen');

  static Future<bool> protect(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('protect', on) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
