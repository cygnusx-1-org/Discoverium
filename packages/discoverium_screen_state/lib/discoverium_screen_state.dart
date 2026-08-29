import 'package:flutter/services.dart';

/// Whether the device is locked, used to hold background installs until the
/// phone is idle (replacing a running app kills it).
///
/// Needs no permission. Throws [PlatformException]/[MissingPluginException]
/// like any other channel call; callers decide how to fall open.
class ScreenState {
  static const MethodChannel _channel = MethodChannel(
    'org.cygnusx1.discoverium/screen_state',
  );

  /// True when the keyguard is showing, or the screen is off.
  static Future<bool> isLocked() async =>
      (await _channel.invokeMethod<bool>('isLocked')) ?? false;
}
