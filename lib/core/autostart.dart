import 'dart:io';

import 'package:path/path.dart' as p;

import 'sys.dart';

/// Starts Stackyard quietly (tray / menu bar only) when you sign in.
///
/// Windows: a value under HKCU\...\Run. macOS: a LaunchAgent in
/// ~/Library/LaunchAgents. Both run the app with [backgroundFlag].
class AutoStart {
  static const backgroundFlag = '--background';
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _name = 'Stackyard';
  static const _label = 'dev.stackyard.app';

  static String get _exe => Platform.resolvedExecutable;
  static File get _plist => File(p.join(Sys.home, 'Library', 'LaunchAgents', '$_label.plist'));

  /// Set by widget tests, which can't wait on real processes.
  static bool? testValue;

  /// Whether sign-in starts this copy of the app.
  static Future<bool> isEnabled() async {
    if (testValue != null) return testValue!;
    if (Platform.isWindows) {
      final out = await Sys.run('reg.exe', ['query', _runKey, '/v', _name]) ?? '';
      return out.toLowerCase().contains(_exe.toLowerCase());
    }
    if (Platform.isMacOS) {
      try {
        return _plist.existsSync() && _plist.readAsStringSync().contains(_exe);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  static Future<void> setEnabled(bool on) async {
    if (Platform.isWindows) {
      await Sys.run(
        'reg.exe',
        on ? ['add', _runKey, '/v', _name, '/t', 'REG_SZ', '/d', '"$_exe" $backgroundFlag', '/f'] : ['delete', _runKey, '/v', _name, '/f'],
      );
    } else if (Platform.isMacOS) {
      if (!on) {
        if (_plist.existsSync()) _plist.deleteSync();
        return;
      }
      String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      _plist.parent.createSync(recursive: true);
      _plist.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>${esc(_exe)}</string>
    <string>$backgroundFlag</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''');
    }
  }
}
