import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:path/path.dart' as p;

import 'window_guard.dart';

/// Small helpers for paths, processes and disk usage.
class Sys {
  /// Environment variables (case-insensitive, like Windows). Refreshed before each
  /// scan by [refreshEnvironment], so tools a fix just installed are found.
  static final Map<String, String> env = LinkedHashMap<String, String>(
    equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
    hashCode: (k) => k.toLowerCase().hashCode,
  )..addAll(Platform.environment);

  /// Re-reads the user and system variables (PATH above all) from the registry.
  /// Windows only hands a new PATH to programs when they start, but installers
  /// change it while Stackyard is running.
  static Future<void> refreshEnvironment() async {
    if (!isWindows) return _refreshUnixEnvironment();
    final value = RegExp(r'^ {4}(\S.*?) {4}(REG_SZ|REG_EXPAND_SZ) {4}(.*)$');
    Future<Map<String, String>> read(String key) async => {
      for (final line in const LineSplitter().convert(await run('reg.exe', ['query', key]) ?? ''))
        if (value.firstMatch(line) case final m?) m[1]!: m[3]!,
    };
    final machine = await read(r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment');
    final user = await read(r'HKCU\Environment');
    if (machine.isEmpty && user.isEmpty) return;
    String expandVars(String s) => s.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) => env[m[1]!] ?? m[0]!);
    for (final source in [machine, user]) {
      for (final MapEntry(:key, value: v) in source.entries) {
        if (key.toLowerCase() != 'path') env[key] = expandVars(v);
      }
    }
    env['PATH'] = [machine['Path'] ?? machine['PATH'], user['Path'] ?? user['PATH']].whereType<String>().map(expandVars).join(';');
  }

  /// macOS: an app opened from Finder, the Dock or at login gets a bare PATH
  /// (/usr/bin:/bin:/usr/sbin:/sbin), not the one your terminal has. Asks your
  /// login shell for its variables, which also picks up Stackyard's own
  /// ~/.zprofile changes, and falls back to the usual Homebrew folders.
  static Future<void> _refreshUnixEnvironment() async {
    final login = Platform.environment['SHELL'];
    final shell = login != null && (login.endsWith('zsh') || login.endsWith('bash')) ? login : '/bin/zsh';
    const marker = '__STACKYARD_ENV__';
    try {
      final proc = await Process.start(shell, ['-l', '-i', '-c', 'printf "$marker"; env -0'], environment: {'HOME': home});
      proc.stdin.close();
      final out = proc.stdout.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      proc.stderr.drain<void>();
      final code = await proc.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
        proc.kill();
        return -1;
      });
      final text = utf8.decode(await out, allowMalformed: true);
      final start = text.indexOf(marker);
      if (code == 0 && start >= 0) {
        for (final entry in text.substring(start + marker.length).split('\u0000')) {
          final eq = entry.indexOf('=');
          if (eq <= 0) continue;
          final key = entry.substring(0, eq);
          // Shell bookkeeping, not settings.
          if (const {'SHLVL', 'PWD', 'OLDPWD', '_'}.contains(key)) continue;
          env[key] = entry.substring(eq + 1);
        }
      }
    } catch (_) {}
    final path = (env['PATH'] ?? '').split(':').where((s) => s.isNotEmpty).toList();
    for (final dir in ['/opt/homebrew/bin', '/opt/homebrew/sbin', '/usr/local/bin', p.join(home, '.local', 'bin')]) {
      if (!path.contains(dir) && dirExists(dir)) path.add(dir);
    }
    env['PATH'] = path.join(':');
  }

  static bool get isWindows => Platform.isWindows;

  /// The Windows build number ("10.0 (Build 26200)" → 26200), or 0 elsewhere.
  static final int windowsBuild = int.tryParse(RegExp(r'Build (\d+)').firstMatch(Platform.operatingSystemVersion)?[1] ?? '') ?? 0;

  /// Windows 11 and macOS can show the desktop through the window.
  static bool get hasGlass => Platform.isMacOS || (isWindows && windowsBuild >= 22000);

  /// Platform words for the UI.
  static String get trashName => isWindows ? 'Recycle Bin' : 'Trash';
  static String get fileManager => isWindows ? 'Explorer' : 'Finder';
  static String get computer => isWindows ? 'PC' : 'Mac';

  static String get home => env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path;
  static String get appData => env['APPDATA'] ?? p.join(home, 'AppData', 'Roaming');
  static String get localAppData => env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local');

  static String expand(String path) {
    if (path.startsWith('~')) path = p.join(home, path.substring(1).replaceFirst(RegExp(r'^[\\/]'), ''));
    return path.replaceAllMapped(RegExp(r'%([A-Za-z_]+)%'), (m) => env[m[1]!] ?? m[0]!);
  }

  // A folder Windows won't let us look into throws instead of answering: treat it as absent.
  static bool dirExists(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static bool fileExists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String? readText(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? readJson(String path) {
    final text = readText(path);
    if (text == null) return null;
    try {
      final v = jsonDecode(text);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static List<Directory> subdirs(String path) {
    try {
      return Directory(path).listSync(followLinks: false).whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {
      return [];
    }
  }

  /// Every entry in [path] (folders, files and links, without following links).
  static List<String> entries(String path) {
    try {
      return Directory(path).listSync(followLinks: false).map((e) => e.path).toList();
    } catch (_) {
      return [];
    }
  }

  /// Resolves a junction or symlink, returning null if [path] isn't one.
  ///
  /// Only real links count (Dart reports Windows junctions as links). A plain
  /// folder that merely resolves elsewhere (OneDrive, subst, app-container
  /// redirection) is not a link.
  static String? linkTarget(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.link) return null;
      final target = Link(path).targetSync();
      return p.isAbsolute(target) ? p.normalize(target) : p.normalize(p.join(p.dirname(path), target));
    } catch (_) {
      return null;
    }
  }

  /// Folders that many programs share: system folders, Homebrew, package
  /// manager shims, a drive or the home folder. Stackyard never removes one of
  /// these as a whole, whichever tech pointed at it.
  static bool isSharedFolder(String path) {
    final n = p.normalize(p.absolute(path)).toLowerCase();
    final h = p.normalize(home).toLowerCase();
    if (p.rootPrefix(n) == n || n == h) return true;
    bool at(String dir) => n == p.normalize(dir).toLowerCase();
    bool atOrIn(String dir) => at(dir) || p.isWithin(p.normalize(dir).toLowerCase(), n);
    if (isWindows) {
      final windows = env['SystemRoot'] ?? r'C:\Windows';
      final programData = env['ProgramData'] ?? r'C:\ProgramData';
      return atOrIn(windows) ||
          atOrIn(p.join(programData, 'chocolatey')) ||
          atOrIn(p.join(h, 'scoop')) ||
          at(programData) ||
          at(env['ProgramFiles'] ?? r'C:\Program Files') ||
          at(env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)') ||
          at(p.join(h, 'AppData')) ||
          at(appData) ||
          at(localAppData) ||
          at(p.join(h, '.local', 'bin'));
    }
    return const ['/usr/bin', '/usr/sbin', '/usr/lib', '/usr/libexec', '/usr/share', '/bin', '/sbin', '/System', '/opt/homebrew', '/opt/local',
              '/usr/local/bin', '/usr/local/Cellar', '/usr/local/Caskroom', '/usr/local/Homebrew', '/usr/local/opt', '/nix']
            .any(atOrIn) ||
        const ['/usr', '/usr/local', '/usr/local/lib', '/usr/local/share', '/opt', '/Applications', '/Library', '/Library/Java/JavaVirtualMachines'].any(at) ||
        at(p.join(h, 'Library')) ||
        at(p.join(h, '.local')) ||
        at(p.join(h, '.local', 'bin'));
  }

  /// The fully resolved form of [path], for comparing two paths to one place.
  static String canonical(String path) {
    try {
      return p.normalize(Directory(path).resolveSymbolicLinksSync()).toLowerCase();
    } catch (_) {
      return p.normalize(path).toLowerCase();
    }
  }

  static DateTime? modified(String path) {
    try {
      return FileSystemEntity.isDirectorySync(path) ? Directory(path).statSync().modified : File(path).statSync().modified;
    } catch (_) {
      return null;
    }
  }

  /// Finds an executable on PATH (Windows: tries PATHEXT).
  static String? which(String name) {
    final paths = (env['PATH'] ?? env['Path'] ?? '').split(isWindows ? ';' : ':');
    final exts = isWindows ? (env['PATHEXT'] ?? '.EXE;.CMD;.BAT').toLowerCase().split(';') : [''];
    // "cmd.exe" is already complete; "winget" needs an extension.
    if (isWindows && p.extension(name).isNotEmpty) exts.insert(0, '');
    for (final dir in paths) {
      if (dir.isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir, '$name$ext');
        // Not existsSync: Store app aliases (winget, python) are reparse points it reports as missing.
        if (FileSystemEntity.typeSync(candidate, followLinks: false) != FileSystemEntityType.notFound) return candidate;
      }
    }
    return null;
  }

  /// Runs a command and returns trimmed stdout, or null on failure or timeout.
  /// A command that times out is killed so it can't linger in the background.
  static Future<String?> run(String exe, List<String> args, {String? cwd, Duration timeout = const Duration(seconds: 20)}) async {
    Process? process;
    try {
      process = await Process.start(exe, args, workingDirectory: cwd, environment: env, runInShell: isWindows && !exe.toLowerCase().endsWith('.exe'));
      process.stdin.close();
      final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
      process.stderr.drain<void>();
      final code = await process.exitCode.timeout(timeout);
      if (code != 0) return null;
      return (await out).trim();
    } catch (_) {
      if (process != null) await killTree(process);
      return null;
    } finally {
      WindowGuard.reclaim();
    }
  }

  /// Programs listed in Windows' Installed apps, as their registry values
  /// (DisplayName, DisplayVersion, UninstallString, QuietUninstallString…) plus
  /// 'Key', the registry key they came from.
  static Future<List<Map<String, String>>> installedApps() async {
    if (!isWindows) return const [];
    const roots = [
      r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    ];
    final apps = <Map<String, String>>[];
    final value = RegExp(r'^ {4}(\S.*?) {4}REG_\w+ {4}(.*)$');
    for (final root in roots) {
      Map<String, String>? current;
      for (final line in const LineSplitter().convert(await run('reg.exe', ['query', root, '/s']) ?? '')) {
        if (line.startsWith('HKEY_')) {
          apps.add(current = {'Key': line.trim()});
        } else if (value.firstMatch(line) case final m? when current != null) {
          current[m[1]!] = m[2]!.trim();
        }
      }
    }
    return apps.where((a) => a['DisplayName'] != null).toList();
  }

  /// Kills a process and everything it started (a shell's children too).
  static Future<void> killTree(Process process) async {
    if (isWindows) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      // Its children too (fvm → git), deepest first, so nothing keeps running after Cancel.
      Future<List<int>> descendants(int pid) async {
        final r = await Process.run('pgrep', ['-P', '$pid']);
        final kids = '${r.stdout}'.split('\n').map((s) => int.tryParse(s.trim())).whereType<int>().toList();
        return [for (final k in kids) ...await descendants(k), ...kids];
      }

      for (final pid in await descendants(process.pid)) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      process.kill(ProcessSignal.sigkill);
    }
    WindowGuard.reclaim();
  }

  /// Splits a folder into work for parallel sizing: returns the bytes of files
  /// in the top two levels plus the folders two levels down, which callers
  /// measure separately (in parallel) with [dirSize].
  static Future<(int, List<String>)> sizeUnits(String path) => Isolate.run(() {
    var bytes = 0;
    final deeper = <String>[];
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file) return (File(path).lengthSync(), deeper);
    if (type != FileSystemEntityType.directory) return (0, deeper);
    void scan(Directory dir, bool collect) {
      try {
        for (final e in dir.listSync(followLinks: false)) {
          if (e is File) {
            try {
              bytes += e.lengthSync();
            } catch (_) {}
          } else if (e is Directory) {
            if (collect) {
              deeper.add(e.path);
            } else {
              scan(e, true);
            }
          }
        }
      } catch (_) {}
    }

    scan(Directory(path), false);
    return (bytes, deeper);
  });

  /// Total size of a directory, computed off the UI isolate.
  static Future<int> dirSize(String path) => Isolate.run(() => _dirSizeSync(path));

  static int _dirSizeSync(String path) {
    var total = 0;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file) return File(path).lengthSync();
    if (type != FileSystemEntityType.directory) return 0;
    final stack = <Directory>[Directory(path)];
    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      try {
        for (final e in dir.listSync(followLinks: false)) {
          if (e is File) {
            try {
              total += e.lengthSync();
            } catch (_) {}
          } else if (e is Directory) {
            stack.add(e);
          }
        }
      } catch (_) {}
    }
    return total;
  }

  /// macOS: moves to the Trash with the system's own call (no permission
  /// prompt). Finder through AppleScript is the fallback.
  static Future<ProcessResult> _trash(String path) async {
    try {
      await const MethodChannel('stackyard/files').invokeMethod<void>('trash', path);
      return ProcessResult(0, 0, '', '');
    } on PlatformException catch (e) {
      return ProcessResult(0, 1, '', e.message ?? 'Couldn\'t move it to the Trash.');
    } catch (_) {
      final quoted = path.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      return Process.run('osascript', ['-e', 'tell application "Finder" to delete POSIX file "$quoted"']);
    }
  }

  /// Moves a file or folder to the Recycle Bin using the Windows shell,
  /// which shows its own progress and confirmation dialogs.
  static Future<ProcessResult> recycle(String path) {
    if (!isWindows) return _trash(path);
    const script = r'''
Add-Type -AssemblyName Microsoft.VisualBasic
$t = $env:STACKYARD_TARGET
if (Test-Path -LiteralPath $t -PathType Container) {
  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($t, 'AllDialogs', 'SendToRecycleBin')
} else {
  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($t, 'AllDialogs', 'SendToRecycleBin')
}
''';
    return Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], environment: {'STACKYARD_TARGET': path});
  }

  /// A file's hash with the system's own tools ('sha256', 'sha512' or 'sha1'), lowercase hex.
  static Future<String?> hashFile(String path, String algorithm) async {
    final r = isWindows
        ? await Process.run('certutil', ['-hashfile', path, algorithm.toUpperCase()])
        : await Process.run('shasum', ['-a', algorithm.replaceFirst('sha', ''), path]);
    if (r.exitCode != 0) return null;
    return RegExp(r'\b[0-9a-fA-F]{40,128}\b').firstMatch('${r.stdout}'.replaceAll(' ', ''))?[0]?.toLowerCase();
  }

  /// Unpacks a .zip or .tar.gz into [dest] (which must not exist yet). It goes into
  /// `<dest>.partial` first and only takes [dest]'s name once complete, and a
  /// single top folder in the archive (flutter/, jdk-17…/) is flattened away.
  static Future<void> extract(String archive, String dest) async {
    if (dirExists(dest) && Directory(dest).listSync().isNotEmpty) {
      throw Exception('$dest already has files in it. Pick an empty folder.');
    }
    final partial = Directory('$dest.partial');
    if (partial.existsSync()) await deletePermanently(partial.path);
    partial.createSync(recursive: true);
    final lower = archive.toLowerCase();
    final ProcessResult r;
    if (isWindows) {
      r = await Process.run('tar', ['-xf', archive, '-C', partial.path]);
    } else if (lower.endsWith('.zip')) {
      r = await Process.run('ditto', ['-x', '-k', archive, partial.path]);
    } else {
      r = await Process.run('tar', ['-xzf', archive, '-C', partial.path]);
    }
    if (r.exitCode != 0) {
      await deletePermanently(partial.path);
      throw Exception('Couldn\'t unpack the download: ${'${r.stderr}'.trim().split('\n').first}');
    }
    final top = partial.listSync(followLinks: false);
    if (dirExists(dest)) Directory(dest).deleteSync();
    Directory(dest).parent.createSync(recursive: true);
    if (top.length == 1 && top.single is Directory) {
      top.single.renameSync(dest);
      partial.deleteSync();
    } else {
      partial.renameSync(dest);
    }
  }

  /// Deletes a file or folder for good, without the Recycle Bin / Trash. Links
  /// inside (symlinks, junctions) are removed as links; what they point to is
  /// never touched.
  static Future<void> deletePermanently(String path) async {
    // Antivirus scans hold freshly unpacked programs for a moment, so a
    // delete right after an install can fail once; try again before giving up.
    for (final wait in const [0, 1, 2, 4]) {
      if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
      await _deleteOnce(path);
      if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) return;
    }
  }

  static Future<void> _deleteOnce(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        await File(path).delete();
      }
    } catch (_) {
      // Read-only files stop Dart's delete on Windows; rd removes them and,
      // like Dart, deletes junctions without following them. Unix: rm -rf.
      if (isWindows) {
        await Process.run('cmd.exe', ['/c', 'rd', '/s', '/q', path]);
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file) {
          await Process.run('cmd.exe', ['/c', 'del', '/f', '/q', path]);
        }
      } else {
        await Process.run('rm', ['-rf', path]);
      }
    }
  }

  static Future<void> reveal(String path) async {
    if (isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else {
      await Process.run('open', ['-R', path]);
    }
  }

  static Future<void> openFolder(String path) async {
    await Process.run(isWindows ? 'explorer.exe' : 'open', [path]);
  }

  static Future<bool> openInVsCode(String path) async {
    final code = which('code');
    if (code == null) return false;
    await Process.start(code, [path], runInShell: true, mode: ProcessStartMode.detached);
    return true;
  }

  static Future<void> openTerminal(String path) async {
    if (isWindows) {
      final wt = which('wt');
      if (wt != null) {
        await Process.start(wt, ['-d', path], mode: ProcessStartMode.detached);
      } else {
        await Process.start('cmd.exe', ['/c', 'start', 'cmd.exe'], workingDirectory: path, mode: ProcessStartMode.detached);
      }
    } else {
      await Process.run('open', ['-a', 'Terminal', path]);
    }
  }
}
