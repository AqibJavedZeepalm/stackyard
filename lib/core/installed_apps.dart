import 'package:path/path.dart' as p;

import 'models.dart';
import 'sys.dart';

/// Programs in Windows' Installed apps, and how to remove them without the user
/// clicking through an uninstaller.
class InstalledApps {
  static Future<List<Map<String, String>>>? _pending;
  static DateTime _loadedAt = DateTime(0);

  /// The visible entries (not hidden components), read once per scan: techs
  /// detect in parallel and would otherwise each query the registry.
  static Future<List<Map<String, String>>> load() {
    if (_pending == null || DateTime.now().difference(_loadedAt) > const Duration(seconds: 20)) {
      _loadedAt = DateTime.now();
      _pending = Sys.installedApps().then((apps) => apps.where((a) => a['SystemComponent'] != '0x1').toList());
    }
    return _pending!;
  }

  /// Forgets the cached list, so a rescan after a fix sees the change.
  static void refresh() => _pending = null;

  /// The entry whose install folder is [folder], if the installer recorded one.
  static Map<String, String>? at(List<Map<String, String>> apps, String folder) {
    final want = p.normalize(folder).toLowerCase();
    return apps.where((a) {
      final loc = a['InstallLocation'];
      return loc != null && loc.isNotEmpty && p.normalize(loc.replaceAll('"', '')).toLowerCase() == want;
    }).firstOrNull;
  }

  /// A silent uninstall for [app]: MSI, Inno Setup and WiX bundles (python.org,
  /// .NET) all have switches for it. Anything else runs its own uninstaller.
  static CommandSpec? uninstall(Map<String, String>? app, {String? title}) {
    if (app == null) return null;
    final name = app['DisplayName'] ?? 'app';
    final admin = (app['Key'] ?? '').startsWith('HKEY_LOCAL_MACHINE');
    final raw = (app['QuietUninstallString'] ?? app['UninstallString'] ?? '').trim();
    if (raw.isEmpty) return null;
    final label = title ?? 'Uninstall $name';

    final code = RegExp(r'\{[0-9A-Fa-f-]{36}\}').firstMatch(raw)?[0];
    if (raw.toLowerCase().startsWith('msiexec') && code != null) {
      return CommandSpec(title: label, executable: 'msiexec.exe', arguments: ['/x', code, '/passive', '/norestart'], needsAdmin: true);
    }
    final (exe, args) = _split(raw);
    final file = p.basename(exe).toLowerCase();
    // Inno Setup: its "quiet" string is only /SILENT, which can still pop up message
    // boxes, so always use the fully silent switches.
    if (RegExp(r'^unins\d{3}\.exe$').hasMatch(file)) {
      return CommandSpec(title: label, executable: exe, arguments: const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'], needsAdmin: admin);
    }
    final quiet = app.containsKey('QuietUninstallString');
    final extra = !quiet && args.any((a) => a.toLowerCase() == '/uninstall')
        ? const ['/quiet', '/norestart'] // WiX bundle (python.org, .NET)
        : const <String>[];
    return CommandSpec(title: label, executable: exe, arguments: [...args, ...extra], needsAdmin: admin);
  }

  /// Removes a Microsoft Store app (for example a Store Python) for this user.
  static CommandSpec storeUninstall(String packageName, String title) => CommandSpec(
    title: title,
    executable: 'powershell.exe',
    arguments: ['-NoProfile', '-NonInteractive', '-Command', "Get-AppxPackage -Name '$packageName' | Remove-AppxPackage"],
  );

  static (String, List<String>) _split(String command) {
    final s = command.trim();
    final String exe;
    final String rest;
    if (s.startsWith('"')) {
      final end = s.indexOf('"', 1);
      exe = s.substring(1, end);
      rest = s.substring(end + 1);
    } else {
      // Unquoted paths may contain spaces: take the longest prefix ending in .exe.
      final m = RegExp(r'^(.+?\.exe)(\s|$)', caseSensitive: false).firstMatch(s);
      exe = m?[1] ?? s.split(' ').first;
      rest = s.substring(exe.length);
    }
    return (exe, rest.split(' ').where((a) => a.isNotEmpty).toList());
  }
}
