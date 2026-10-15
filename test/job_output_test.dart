@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/models.dart';
import 'package:stackyard/state/jobs.dart';

void main() {
  test('progress lines collapse into one and the job remembers how far it got', () async {
    final queue = JobQueue(onJobFinished: (_) {});
    double? seen;
    queue.addListener(() => seen = queue.current?.progress ?? seen);
    // What git and FVM print: a bar redrawn with \r, then a normal line.
    final job = queue.enqueue(
      const PlannedChange(
        title: 'Clone',
        commands: [
          CommandSpec(
            title: 'Clone',
            executable: '/bin/sh',
            arguments: ['-c', r"printf ' Receiving objects: [██.......] 10%%\r Receiving objects: [█████....] 55%%\r Receiving objects: [█████████] 100%%\nDone\n' >&2"],
          ),
        ],
      ),
    );
    while (job.status == JobStatus.queued || job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(job.status, JobStatus.done, reason: job.error);
    expect(job.log.skip(1).take(2).toList(), ['Receiving objects: 100%', 'Done']);
    expect(seen, 1.0);
    expect(job.progress, isNull, reason: 'reset once the command ends');
  });

  Future<void> finish(Job job) async {
    while (job.status == JobStatus.queued || job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('macOS: a terminal command shows progress a tool prints only to terminals', () async {
    final queue = JobQueue(onJobFinished: (_) {});
    // `[ -t 1 ]`: prints the bar only when its output is a terminal, like git.
    final job = queue.enqueue(
      const PlannedChange(
        title: 'Clone',
        commands: [
          CommandSpec(title: 'Clone', executable: '/bin/sh', terminal: true, arguments: ['-c', r"[ -t 1 ] && printf 'Receiving objects:  45%% (1/2)\r\n'; echo ok"]),
        ],
      ),
    );
    await finish(job);
    expect(job.status, JobStatus.done, reason: job.error);
    expect(job.log, contains('Receiving objects:  45% (1/2)'));
  }, testOn: 'mac-os');

  test('Cancel stops the whole process tree and removes the unfinished folder', () async {
    final dir = p.join(Directory.systemTemp.createTempSync('sy-cancel').path, 'versions', 'x');
    final marker = 'sy-cancel-${DateTime.now().microsecondsSinceEpoch}';
    final queue = JobQueue(onJobFinished: (_) {});
    // A parent that starts a long-running child, like fvm starting git.
    final job = queue.enqueue(
      PlannedChange(
        title: 'Install',
        commands: [
          CommandSpec(
            title: 'Install',
            executable: '/bin/sh',
            terminal: true,
            watchPath: dir,
            arguments: ['-c', 'mkdir -p "$dir" && touch "$dir/half" && /bin/sh -c "sleep 300; echo $marker" & wait'],
          ),
        ],
      ),
    );
    while (!Directory(dir).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await queue.cancel(job);
    await finish(job);
    expect(job.status, JobStatus.failed);
    expect((await Process.run('pgrep', ['-f', marker])).exitCode, 1, reason: 'the child was killed too');
    expect(Directory(dir).existsSync(), isFalse, reason: 'half an install is removed');
  });

  test('a finished job can be removed from the list', () async {
    final queue = JobQueue(onJobFinished: (_) {});
    final job = queue.enqueue(const PlannedChange(title: 'Nothing'));
    await finish(job);
    queue.remove(job);
    expect(queue.jobs, isEmpty);
  });
}
