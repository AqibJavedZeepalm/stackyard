@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/state/jobs.dart';

void main() {
  test('cancel kills a hung command and marks the job cancelled', () async {
    final finished = <Job>[];
    final queue = JobQueue(onJobFinished: finished.add);
    final job = queue.enqueue(
      const PlannedChange(
        title: 'Hang',
        commands: [
          CommandSpec(title: 'Sleep', executable: 'powershell.exe', arguments: ['-NoProfile', '-Command', 'Start-Sleep 120']),
        ],
      ),
    );
    final queued = queue.enqueue(
      const PlannedChange(
        title: 'Never runs',
        commands: [
          CommandSpec(title: 'Echo', executable: 'cmd.exe', arguments: ['/c', 'echo hi']),
        ],
      ),
    );

    while (job.status != JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    await queue.cancel(queued);
    final started = DateTime.now();
    await queue.cancel(job);
    while (job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(job.status, JobStatus.failed);
    expect(job.error, 'Cancelled.');
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
    expect(queued.status, JobStatus.failed);
    expect(queued.error, 'Cancelled.');
  });

  test('removing a link deletes only the link, never its target', () async {
    final tmp = Directory.systemTemp.createTempSync('stackyard-link-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final target = Directory('${tmp.path}\\real')..createSync();
    File('${target.path}\\keep.txt').writeAsStringSync('precious');
    final link = Link('${tmp.path}\\alias')..createSync(target.path);

    final queue = JobQueue(onJobFinished: (_) {});
    final job = queue.enqueue(PlannedChange(title: 'Remove alias', recycle: [link.path]));
    while (job.status == JobStatus.queued || job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(job.status, JobStatus.done, reason: job.error);
    expect(FileSystemEntity.typeSync(link.path, followLinks: false), FileSystemEntityType.notFound);
    expect(File('${target.path}\\keep.txt').readAsStringSync(), 'precious');
  });

  test('a missing tool fails with a plain explanation', () async {
    final queue = JobQueue(onJobFinished: (_) {});
    final jobs = [
      // Through the shell (no .exe): cmd.exe exits 9009.
      queue.enqueue(
        const PlannedChange(
          title: 'Shell',
          commands: [CommandSpec(title: 'Install thing', executable: 'stackyard-no-such-tool')],
        ),
      ),
      // Direct: Process.start throws.
      queue.enqueue(
        const PlannedChange(
          title: 'Direct',
          commands: [CommandSpec(title: 'Install thing', executable: r'C:\nope\stackyard-no-such-tool.exe')],
        ),
      ),
    ];
    while (jobs.any((j) => j.status == JobStatus.queued || j.status == JobStatus.running)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    for (final job in jobs) {
      expect(job.status, JobStatus.failed);
      expect(job.error, contains('needs stackyard-no-such-tool'));
    }
  });

  test('deleting permanently removes the folder, read-only files too, but never what links point to', () async {
    final tmp = Directory.systemTemp.createTempSync('stackyard-perm-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final precious = Directory('${tmp.path}\\precious')..createSync();
    File('${precious.path}\\keep.txt').writeAsStringSync('precious');
    final junk = Directory('${tmp.path}\\node_modules\\pkg')..createSync(recursive: true);
    File('${junk.path}\\index.js').writeAsStringSync('x');
    final readOnly = File('${junk.path}\\locked.bin')..writeAsStringSync('x');
    if (Platform.isWindows) await Process.run('attrib', ['+R', readOnly.path]);
    Link('${tmp.path}\\node_modules\\shared').createSync(precious.path);

    final queue = JobQueue(onJobFinished: (_) {});
    final job = queue.enqueue(PlannedChange(title: 'Clean', recycle: ['${tmp.path}\\node_modules'], permanent: true));
    while (job.status == JobStatus.queued || job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(job.status, JobStatus.done, reason: job.error);
    expect(Directory('${tmp.path}\\node_modules').existsSync(), isFalse);
    expect(File('${precious.path}\\keep.txt').readAsStringSync(), 'precious');
  });

  test('linkTarget reports real links only', () {
    final tmp = Directory.systemTemp.createTempSync('stackyard-lt-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final real = Directory('${tmp.path}\\real')..createSync();
    final link = Link('${tmp.path}\\alias')..createSync(real.path);
    expect(Sys.linkTarget(real.path), isNull);
    expect(Sys.linkTarget(link.path)?.toLowerCase(), real.path.toLowerCase());
    expect(Sys.canonical(link.path), Sys.canonical(real.path));
  });

  test('Sys.run gives up on a hung command and kills it', () async {
    final sw = Stopwatch()..start();
    final out = await Sys.run('powershell.exe', ['-NoProfile', '-Command', 'Start-Sleep 60'], timeout: const Duration(seconds: 2));
    expect(out, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
