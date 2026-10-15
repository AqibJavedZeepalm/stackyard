import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';

import '../core/env_writer.dart';
import '../core/models.dart';
import '../core/sys.dart';
import '../core/window_guard.dart';

enum JobStatus { queued, running, done, failed }

class Job {
  Job(this.change, {this.removesItemIds = const []}) : id = _next++;
  static int _next = 1;

  final int id;
  final PlannedChange change;

  /// Items that disappear when this job succeeds (for the collapse animation).
  final List<String> removesItemIds;
  JobStatus status = JobStatus.queued;
  final List<String> log = [];
  int step = 0;
  DateTime? startedAt;
  DateTime? finishedAt;
  DateTime? lastOutputAt;
  String? error;
  bool cancelRequested = false;

  /// How far the current download is (0–1), when its size is known.
  double? progress;

  /// How much the running command has written to its [CommandSpec.watchPath] so far.
  int? receivedBytes;

  int get totalSteps => change.downloads.length + change.edits.length + change.recycle.length + change.commands.length + (change.env.isEmpty ? 0 : 1);
  String get title => change.title;
}

/// Runs planned changes one at a time and streams their output.
class JobQueue extends ChangeNotifier {
  JobQueue({required this.onJobFinished});

  final void Function(Job job) onJobFinished;
  final List<Job> jobs = [];
  bool _running = false;

  int get activeCount => jobs.where((j) => j.status == JobStatus.queued || j.status == JobStatus.running).length;
  Job? get current => jobs.where((j) => j.status == JobStatus.running).firstOrNull;

  /// Jobs waiting or running.
  Iterable<Job> get active => jobs.where((j) => j.status == JobStatus.queued || j.status == JobStatus.running);

  /// A waiting or running job has this title (fix and Update buttons use it to show they're busy).
  bool isBusy(String? title) => title != null && active.any((j) => j.title == title);

  /// A waiting or running job removes this item, or touches files in or around [path].
  bool touches({String? id, String? path}) {
    String norm(String s) => s.replaceAll('\\', '/').toLowerCase();
    final p = path == null || path.isEmpty ? null : norm(path);
    return active.any(
      (j) =>
          (id != null && j.removesItemIds.contains(id)) ||
          (p != null &&
              j.change.recycle.any((r) {
                final q = norm(r);
                return q == p || q.startsWith('$p/') || p.startsWith('$q/');
              })),
    );
  }

  Job enqueue(PlannedChange change, {List<String> removesItemIds = const []}) {
    final job = Job(change, removesItemIds: removesItemIds);
    jobs.insert(0, job);
    notifyListeners();
    _pump();
    return job;
  }

  /// Stops a running job (killing its process) or drops a queued one.
  Future<void> cancel(Job job) async {
    if (job.status == JobStatus.queued) {
      job.status = JobStatus.failed;
      job.error = 'Cancelled.';
      job.finishedAt = DateTime.now();
      notifyListeners();
      return;
    }
    if (job.status != JobStatus.running) return;
    job.cancelRequested = true;
    _log(job, 'Cancelling…');
    final process = _process;
    if (process != null) await Sys.killTree(process);
  }

  Process? _process;

  /// Takes one finished job off the list.
  void remove(Job job) {
    if (job.status != JobStatus.done && job.status != JobStatus.failed) return;
    jobs.remove(job);
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.status == JobStatus.done || j.status == JobStatus.failed);
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    while (true) {
      final next = jobs.lastWhere((j) => j.status == JobStatus.queued, orElse: () => _none);
      if (identical(next, _none)) break;
      await _run(next);
      onJobFinished(next);
    }
    _running = false;
  }

  static final _none = Job(const PlannedChange(title: ''));

  void _log(Job job, String line) {
    job.log.add(line);
    job.lastOutputAt = DateTime.now();
    if (job.log.length > 2000) job.log.removeRange(0, job.log.length - 2000);
    notifyListeners();
  }

  Future<void> _run(Job job) async {
    job.status = JobStatus.running;
    job.startedAt = DateTime.now();
    notifyListeners();
    try {
      for (final d in job.change.downloads) {
        if (job.cancelRequested) throw Exception('Cancelled.');
        job.step++;
        await _download(job, d);
      }
      for (final edit in job.change.edits) {
        job.step++;
        _log(job, '> write ${edit.path}');
        await File(edit.path).writeAsString(edit.content);
      }
      for (final path in job.change.recycle) {
        job.step++;
        // Links (symlinks, junctions) are pointers: delete the link only,
        // never what it points to. This works for dangling links too.
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link) {
          _log(job, '> remove link $path');
          Link(path).deleteSync();
          continue;
        }
        if (!FileSystemEntity.isDirectorySync(path) && !FileSystemEntity.isFileSync(path)) {
          _log(job, '> skip $path (already gone)');
          continue;
        }
        if (FileSystemEntity.isDirectorySync(path) && Sys.isSharedFolder(path)) {
          throw Exception('Stopped: $path is shared by other programs, so Stackyard won\'t remove it.');
        }
        if (job.change.permanent) {
          _log(job, '> delete permanently: $path');
          await Sys.deletePermanently(path);
          if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) {
            throw Exception('Couldn\'t delete all of $path. Something may be using it; close it and try again.');
          }
          continue;
        }
        _log(job, '> move to ${Sys.trashName}: $path');
        final r = await Sys.recycle(path);
        final stillThere = FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
        if (r.exitCode != 0 || stillThere) {
          final err = '${r.stderr}'.trim();
          throw Exception(
            err.contains('OperationCanceled') || err.contains('canceled')
                ? 'Cancelled.'
                : 'Couldn\'t remove $path. ${err.split('\n').first}',
          );
        }
      }
      for (final cmd in job.change.commands) {
        if (job.cancelRequested) throw Exception('Cancelled.');
        job.step++;
        // Say plainly when a needed tool (winget, fvm, sdkmanager…) isn't there,
        // instead of a bare exit code from the shell.
        final exe = cmd.executable;
        final isPath = exe.contains('\\') || exe.contains('/');
        final exists = isPath ? FileSystemEntity.typeSync(exe, followLinks: false) != FileSystemEntityType.notFound : Sys.which(exe) != null;
        if (!exists) throw Exception(_missing(cmd));
        final int code;
        try {
          code = await _runCommand(job, cmd);
        } on ProcessException {
          throw Exception(_missing(cmd));
        }
        if (job.cancelRequested) throw Exception('Cancelled.');
        if (code != 0 && cmd.needsAdmin && job.log.any((l) => l.contains('canceled by the user'))) {
          throw Exception('Cancelled in the Windows admin prompt. Nothing was changed.');
        }
        if (code != 0) throw Exception('"${cmd.title}" failed (exit code $code).');
      }
      if (job.change.env.isNotEmpty) {
        if (job.cancelRequested) throw Exception('Cancelled.');
        job.step++;
        if (Sys.isWindows) {
          final cmd = EnvWriter.windowsCommand(job.change.env, forEveryone: job.change.envForEveryone);
          for (final c in job.change.env) {
            _log(job, '> ${c.describe}');
          }
          final code = await _runCommand(job, cmd);
          if (code != 0 && job.log.any((l) => l.contains('canceled by the user'))) {
            throw Exception("Installed, but environment variables weren't changed: the Windows admin prompt was cancelled.");
          }
          if (code != 0) throw Exception("Couldn't update environment variables (exit code $code).");
        } else {
          final files = await EnvWriter.applyUnix(job.change.env, block: job.change.envBlock ?? 'tools');
          for (final c in job.change.env) {
            _log(job, '> ${c.describe}');
          }
          if (files.isNotEmpty) _log(job, 'Updated ${files.join(', ')}. Open a new terminal to use it.');
        }
      }
      job.status = JobStatus.done;
      _log(job, 'Done.');
    } catch (e) {
      job.error = e.toString().replaceFirst('Exception: ', '');
      _log(job, job.error!);
      job.status = JobStatus.failed;
    }
    job.finishedAt = DateTime.now();
    notifyListeners();
  }

  /// Downloads one file with progress, checks its hash, then unpacks it or keeps it.
  Future<void> _download(Job job, DownloadStep d) async {
    _log(job, '> download ${d.url}');
    final tmpDir = Directory.systemTemp.createTempSync('stackyard-dl-');
    final file = File('${tmpDir.path}${Platform.pathSeparator}${Uri.parse(d.url).pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => 'download')}');
    try {
      final client = HttpClient()..userAgent = 'Stackyard';
      try {
        final res = await (await client.getUrl(Uri.parse(d.url))).close();
        if (res.statusCode != 200) throw Exception('Download failed: ${d.url} answered ${res.statusCode}.');
        final total = res.contentLength > 0 ? res.contentLength : d.size;
        final sink = file.openWrite();
        var got = 0;
        var lastPct = -1;
        await for (final chunk in res) {
          if (job.cancelRequested) {
            await sink.close();
            throw Exception('Cancelled.');
          }
          sink.add(chunk);
          got += chunk.length;
          if (total != null && total > 0) {
            job.progress = got / total;
            final pct = (job.progress! * 100).floor();
            if (pct ~/ 10 != lastPct ~/ 10) _log(job, '  $pct% of ${(total / 1048576).toStringAsFixed(0)} MB');
            if (pct != lastPct) {
              lastPct = pct;
              notifyListeners();
            }
          }
        }
        await sink.close();
      } finally {
        client.close();
        job.progress = null;
      }

      // Check it's exactly the file the publisher released.
      final expected = await _expectedHash(d, file);
      if (expected != null) {
        final actual = await Sys.hashFile(file.path, expected.$1);
        if (actual == null || actual.toLowerCase() != expected.$2.toLowerCase()) {
          throw Exception("The download doesn't match its published ${expected.$1.toUpperCase()} hash, so it wasn't installed. Try again later.");
        }
        _log(job, '  ${expected.$1.toUpperCase()} verified.');
      } else {
        _log(job, '  (No published hash to check this file against.)');
      }

      if (d.saveAs != null) {
        File(d.saveAs!).parent.createSync(recursive: true);
        await file.copy(d.saveAs!);
        // Downloaded installers (rustup-init…) must be runnable on macOS.
        if (!Sys.isWindows && !d.saveAs!.endsWith('.pkg')) await Process.run('chmod', ['+x', d.saveAs!]);
      }
      if (d.extractTo != null) {
        _log(job, '> unpack to ${d.extractTo}');
        await Sys.extract(file.path, d.extractTo!);
      }
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// The published hash for a download: given directly, or read from its checksum file.
  Future<(String, String)?> _expectedHash(DownloadStep d, File file) async {
    if (d.sha256 != null) return ('sha256', d.sha256!);
    if (d.sha512 != null) return ('sha512', d.sha512!);
    if (d.sha1 != null) return ('sha1', d.sha1!);
    final url = d.checksumUrl;
    if (url == null) return null;
    final client = HttpClient()..userAgent = 'Stackyard';
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != 200) return null;
      final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      // A bare hash, or "hash  filename" lines (pick the one for this file).
      final name = file.uri.pathSegments.last;
      final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty).toList();
      final line = lines.firstWhere((l) => l.contains(name), orElse: () => lines.length == 1 ? lines.first : '');
      final hash = RegExp(r'\b[0-9a-fA-F]{40,128}\b').firstMatch(line)?[0];
      if (hash == null) return null;
      return (
        switch (hash.length) {
          40 => 'sha1',
          128 => 'sha512',
          _ => 'sha256',
        },
        hash,
      );
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Runs one command, streaming its output into the job log.
  Future<int> _runCommand(Job job, CommandSpec cmd) async {
    _log(job, '> ${cmd.display}');
    var exe = cmd.executable;
    var args = cmd.arguments;
    var shell = cmd.runInShell || (Sys.isWindows && !exe.toLowerCase().endsWith('.exe'));
    if (cmd.needsAdmin && Sys.isWindows) {
      // Run it elevated: Windows shows its admin prompt, we wait and pass the exit code on.
      // An elevated process's output can't be read from here, so the log shows the result only.
      String q(String s) => "'${s.replaceAll("'", "''")}'";
      final argList = args.isEmpty ? '' : ' -ArgumentList @(${args.map((a) => q(a.contains(' ') ? '"$a"' : a)).join(',')})';
      final script = '\$p = Start-Process -FilePath ${q(exe)}$argList -Verb RunAs -Wait -PassThru -WindowStyle Hidden; exit \$p.ExitCode';
      _log(job, 'Windows will ask for administrator permission.');
      exe = 'powershell.exe';
      args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script];
      shell = false;
    }
    if (cmd.terminal && Platform.isMacOS) {
      // git (inside fvm) prints its progress only to a terminal: give it one.
      args = ['-q', '/dev/null', exe, ...args];
      exe = '/usr/bin/script';
    }
    final createsWatched = cmd.watchPath != null && !Sys.dirExists(cmd.watchPath!);
    final process = await Process.start(
      exe,
      args,
      workingDirectory: cmd.workingDirectory,
      runInShell: shell,
      environment: {...Sys.env, 'CI': 'true', 'FORCE_COLOR': '0', 'NO_COLOR': '1', ...cmd.environment},
    );
    _process = process;
    process.stdin.close();
    final done = Completer<void>();
    var open = 2;
    void closeOne() {
      if (--open == 0) done.complete();
    }

    for (final stream in [process.stdout, process.stderr]) {
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .map(_stripAnsi)
          .where((l) => l.trim().isNotEmpty)
          .listen((l) => _output(job, l), onDone: closeOne);
    }
    // A tool's hidden prompt can disable our window mid-job; keep Cancel clickable.
    final guard = Timer.periodic(const Duration(seconds: 1), (_) => WindowGuard.reclaim());
    var measuring = false;
    final watch = cmd.watchPath == null
        ? null
        : Timer.periodic(const Duration(seconds: 2), (_) async {
            if (measuring) return;
            measuring = true;
            final bytes = await Sys.dirSize(cmd.watchPath!);
            measuring = false;
            if (bytes > 0 && bytes != job.receivedBytes && job.status == JobStatus.running) {
              job.receivedBytes = bytes;
              notifyListeners();
            }
          });
    final code = await process.exitCode;
    // Only a cancel that stopped the process counts; one that lands after it
    // finished must not delete a completed install.
    final killed = job.cancelRequested && code != 0;
    guard.cancel();
    watch?.cancel();
    _process = null;
    WindowGuard.reclaim();
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    // After the last output: a late "100%" line mustn't leave the bar full for the next step.
    job.progress = null;
    job.receivedBytes = null;
    // A cancelled install leaves half a folder that the tool would later take for a real one.
    if (killed && createsWatched && Sys.dirExists(cmd.watchPath!)) {
      _log(job, 'Removing the unfinished ${cmd.watchPath}');
      await Sys.deletePermanently(cmd.watchPath!);
    }
    return code;
  }

  static String _missing(CommandSpec cmd) {
    final name = cmd.executable.split(RegExp(r'[\\/]')).last;
    final hint = name.toLowerCase().startsWith('winget')
        ? ' winget comes with "App Installer" from the Microsoft Store.'
        : ' Install it, then restart Stackyard.';
    return '"${cmd.title}" needs $name, which isn\'t installed or isn\'t on PATH.$hint';
  }

  static final _percent = RegExp(r'(\d{1,3}(?:\.\d+)?) ?%');

  /// Text progress bars like "[█████.....]" (FVM, git, sdkmanager).
  static final _bar = RegExp(r'\[[█▓▒░#=>.\- ]{5,}\] *');

  /// One line of a command's output. A percentage moves the job's progress bar,
  /// and replaces the previous line of the same kind ("Receiving objects: 45%")
  /// so the log doesn't fill up with one line per update.
  void _output(Job job, String line) {
    line = line.replaceAll(_bar, '').trim();
    if (line.isEmpty) return;
    final m = _percent.firstMatch(line);
    if (m != null) {
      final pct = double.parse(m[1]!);
      if (pct <= 100) job.progress = pct / 100;
      final kind = line.substring(0, m.start).trim();
      final last = job.log.lastOrNull;
      if (kind.isNotEmpty && last != null && last.startsWith(kind) && _percent.hasMatch(last)) job.log.removeLast();
    }
    _log(job, line);
  }

  /// Colors and cursor moves, plus the "^D" a terminal echoes when its input closes.
  static String _stripAnsi(String s) =>
      s.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '').replaceAll(RegExp(r'\^D\x08*'), '').replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '');
}
