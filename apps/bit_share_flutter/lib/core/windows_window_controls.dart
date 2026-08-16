import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Small bridge to the native Win32 frame. The app deliberately keeps a
/// standard resizable Windows window; this only adds an optional immersive
/// F11 mode without pulling in a window-management dependency.
abstract final class WindowsWindowControls {
  static const _channel = MethodChannel('bitshare/windows');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<bool> setFullscreen(bool enabled) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('setFullscreen', {
          'enabled': enabled,
        }) ??
        false;
  }
}
