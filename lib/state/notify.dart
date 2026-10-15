import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';

/// Desktop notifications. macOS uses the system's UserNotifications (see
/// MainFlutterWindow.swift); Windows uses local_notifier (toasts).
class Notify {
  static const _mac = MethodChannel('stackyard/notify');
  static void Function()? _onClick;

  /// Asks for permission on macOS (once; the system remembers the answer).
  /// [onClick] runs when someone clicks a notification.
  static Future<void> setup(void Function() onClick) async {
    _onClick = onClick;
    if (Platform.isMacOS) {
      _mac.setMethodCallHandler((call) async {
        if (call.method == 'clicked') _onClick?.call();
      });
      // Not awaited: macOS only answers once the person picks Allow or Don't
      // Allow, and the window mustn't wait for that. A refusal just means no banners.
      unawaited(_mac.invokeMethod<bool>('setup').catchError((_) => false));
    } else {
      try {
        await localNotifier.setup(appName: 'Stackyard', shortcutPolicy: ShortcutPolicy.requireCreate);
      } catch (_) {
        // No notifications; the tray still works.
      }
    }
  }

  /// Never throws: notifications turned off in system settings are not an error.
  static Future<void> show(String title, String body) async {
    try {
      if (Platform.isMacOS) {
        await _mac.invokeMethod<void>('show', {'title': title, 'body': body});
      } else {
        final n = LocalNotification(title: title, body: body)..onClick = _onClick;
        await n.show();
      }
    } catch (_) {}
  }
}
