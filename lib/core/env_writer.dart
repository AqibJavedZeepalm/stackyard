import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'sys.dart';

/// Writes environment variable changes where each platform keeps them.
///
/// Windows: the user's (or, with admin, the machine's) environment in the
/// registry. PATH keeps its type, so entries like %USERPROFILE%\bin still work.
/// macOS: one marked block per tool in ~/.zprofile (and ~/.bash_profile if it
/// exists), replaced as a whole on every change; plus `launchctl setenv` so
/// apps started from the Dock see variables like JAVA_HOME.
class EnvWriter {
  /// The PowerShell command that applies [changes] on Windows.
  static CommandSpec windowsCommand(List<EnvChange> changes, {bool forEveryone = false, String? keyOverride}) {
    final key = keyOverride ?? (forEveryone ? r'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' : r'HKCU:\Environment');
    final target = forEveryone ? 'Machine' : 'User';
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final lines = <String>[
      '\$key = ${q(key)}',
      "\$parts = @(((Get-Item \$key).GetValue('Path', '', 'DoNotExpandEnvironmentNames') -split ';') | Where-Object { \$_.Trim() })",
      'function Under(\$entry, \$dir) { \$e = [Environment]::ExpandEnvironmentVariables(\$entry).TrimEnd(\'\\\'); \$d = \$dir.TrimEnd(\'\\\'); '
          '\$e.Equals(\$d, [StringComparison]::OrdinalIgnoreCase) -or \$e.StartsWith(\$d + \'\\\', [StringComparison]::OrdinalIgnoreCase) }',
    ];
    var pathChanged = false;
    // Prepends run last-to-first, so the first one listed ends up first on PATH.
    for (final c in [...changes.where((c) => c.op != EnvOp.prependPath), ...changes.where((c) => c.op == EnvOp.prependPath).toList().reversed]) {
      switch (c.op) {
        case EnvOp.set:
          lines.add('New-ItemProperty -Path \$key -Name ${q(c.name)} -Value ${q(c.value!)} -PropertyType String -Force | Out-Null');
        case EnvOp.remove:
          lines.add('Remove-ItemProperty -Path \$key -Name ${q(c.name)} -ErrorAction SilentlyContinue');
        case EnvOp.removeIfUnder:
          lines.add(
            '\$v = (Get-Item \$key).GetValue(${q(c.name)}, \$null, \'DoNotExpandEnvironmentNames\'); '
            'if (\$v -and (Under \$v ${q(c.value!)})) { Remove-ItemProperty -Path \$key -Name ${q(c.name)} }',
          );
        case EnvOp.prependPath:
          pathChanged = true;
          final prefix = c.replacePrefix;
          lines.add(
            '\$parts = @(${q(c.value!)}) + @(\$parts | Where-Object { -not (Under \$_ ${q(c.value!)})'
            '${prefix == null ? '' : ' -and -not (Under \$_ ${q(prefix)})'} })',
          );
        case EnvOp.dropPathUnder:
          pathChanged = true;
          lines.add('\$parts = @(\$parts | Where-Object { -not (Under \$_ ${q(c.value!)}) })');
      }
    }
    if (pathChanged) lines.add("New-ItemProperty -Path \$key -Name Path -Value (\$parts -join ';') -PropertyType ExpandString -Force | Out-Null");
    // Setting and clearing a throwaway variable makes Windows tell running apps (Explorer) about the change.
    lines.addAll([
      "[Environment]::SetEnvironmentVariable('STACKYARD_REFRESH', '1', '$target')",
      "[Environment]::SetEnvironmentVariable('STACKYARD_REFRESH', \$null, '$target')",
    ]);
    return CommandSpec(
      title: forEveryone ? 'Update environment variables for everyone' : 'Update your environment variables',
      executable: 'powershell.exe',
      arguments: ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', lines.join('; ')],
      needsAdmin: forEveryone,
    );
  }

  /// Applies [changes] on macOS (or Linux): rewrites this tool's block in the shell profiles.
  static Future<List<String>> applyUnix(
    List<EnvChange> changes, {
    required String block,
    String? home,
    Future<String> Function(List<String> args)? launchctl,
  }) async {
    final homeDir = home ?? Sys.home;
    final profiles = [File(p.join(homeDir, '.zprofile')), if (File(p.join(homeDir, '.bash_profile')).existsSync()) File(p.join(homeDir, '.bash_profile'))];
    final start = '# >>> stackyard:$block >>>';
    final end = '# <<< stackyard:$block <<<';
    final blockPattern = RegExp('${RegExp.escape(start)}[\\s\\S]*?${RegExp.escape(end)}\\n?');
    final touched = <String>[];
    for (final file in profiles) {
      var text = file.existsSync() ? file.readAsStringSync() : '';
      final existing = blockPattern.firstMatch(text)?[0] ?? '';
      // Uninstall: drop this tool's block when it points into the removed folder.
      final dropping = changes.where((c) => c.op == EnvOp.dropPathUnder || c.op == EnvOp.removeIfUnder).map((c) => c.value!).toList();
      if (dropping.isNotEmpty && changes.every((c) => c.op == EnvOp.dropPathUnder || c.op == EnvOp.removeIfUnder)) {
        if (existing.isNotEmpty && dropping.any(existing.contains)) {
          text = text.replaceFirst(existing, '');
          file.writeAsStringSync(text);
          touched.add(file.path);
        }
        continue;
      }
      String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$');
      final body = [
        start,
        '# Added by Stackyard. Change it from the app, or delete this block.',
        for (final c in changes)
          switch (c.op) {
            EnvOp.set => 'export ${c.name}="${esc(c.value!)}"',
            EnvOp.remove => 'unset ${c.name}',
            EnvOp.prependPath => 'export PATH="${esc(c.value!)}:\$PATH"',
            _ => '',
          },
        end,
      ].where((l) => l.isNotEmpty).join('\n');
      text = existing.isNotEmpty ? text.replaceFirst(existing, '$body\n') : '${text.isEmpty || text.endsWith('\n') ? text : '$text\n'}\n$body\n';
      file.writeAsStringSync(text);
      touched.add(file.path);
    }
    // Apps started from the Dock don't read shell profiles: set the variables in
    // this login session too, and again at every login. Only for the real home
    // folder; tests write to a temporary one and pass their own [launchctl].
    if (Platform.isMacOS) {
      final run = launchctl ?? (home == null ? (List<String> args) => Process.run('launchctl', args).then((r) => '${r.stdout}'.trim()) : null);
      if (run != null) {
        for (final c in changes) {
          if (c.op == EnvOp.set) await run(['setenv', c.name, c.value!]);
          if (c.op == EnvOp.remove) await run(['unsetenv', c.name]);
          if (c.op == EnvOp.removeIfUnder) {
            final now = await run(['getenv', c.name]);
            if (now.isNotEmpty && (p.equals(now, c.value!) || p.isWithin(c.value!, now))) await run(['unsetenv', c.name]);
          }
        }
      }
      writeLoginAgent(homeDir);
    }
    return touched;
  }

  /// ~/Library/LaunchAgents/dev.stackyard.env.plist: at login, sets the variables
  /// from Stackyard's blocks in ~/.zprofile for apps started from the Dock
  /// (`launchctl setenv` alone only lasts until logout). Removed when no block sets any.
  static void writeLoginAgent(String homeDir) {
    final agent = File(p.join(homeDir, 'Library', 'LaunchAgents', 'dev.stackyard.env.plist'));
    final profile = File(p.join(homeDir, '.zprofile'));
    final text = profile.existsSync() ? profile.readAsStringSync() : '';
    final exports = [
      for (final b in RegExp(r'# >>> stackyard:[\s\S]*?# <<< stackyard:').allMatches(text))
        for (final m in RegExp(r'^export (?!PATH=)(\w+)=(".*")$', multiLine: true).allMatches(b[0]!)) 'launchctl setenv ${m[1]} ${m[2]}',
    ];
    if (exports.isEmpty) {
      if (agent.existsSync()) agent.deleteSync();
      return;
    }
    String xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    agent.parent.createSync(recursive: true);
    agent.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.stackyard.env</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>${xml(exports.join('; '))}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''');
  }
}
