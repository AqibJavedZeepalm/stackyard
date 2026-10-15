// A real `fvm install` through the job queue, into a throwaway FVM cache:
// progress percentages arrive, and Cancel stops git and removes the half-made SDK.
// Run with: flutter test test/fvm_progress_live_test.dart --dart-define=LIVE=true
// ignore_for_file: avoid_print
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/state/jobs.dart';

void main() {
  test('fvm install shows real progress and cancels cleanly', () async {
    final fvm = Sys.which('fvm');
    expect(fvm, isNotNull, reason: 'needs FVM');
    final cache = Directory.systemTemp.createTempSync('sy-fvm');
    addTearDown(() => cache.deleteSync(recursive: true));
    final dest = p.join(cache.path, 'versions', '3.24.0');

    final queue = JobQueue(onJobFinished: (_) {});
    final seen = <double>[];
    queue.addListener(() {
      final v = queue.current?.progress;
      if (v != null && (seen.isEmpty || seen.last != v)) seen.add(v);
    });
    final job = queue.enqueue(
      PlannedChange(
        title: 'Install Flutter 3.24.0',
        commands: [
          CommandSpec(
            title: 'Download and set up Flutter 3.24.0',
            executable: fvm!,
            arguments: const ['install', '3.24.0'],
            environment: {'FVM_CACHE_PATH': cache.path},
            watchPath: dest,
            terminal: true,
          ),
        ],
      ),
    );

    final end = DateTime.now().add(const Duration(minutes: 3));
    while (seen.where((v) => v > 0.05).length < 3 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    print('progress samples: ${seen.length}, last ${(seen.lastOrNull ?? 0) * 100}% · status line: ${job.log.last}');
    expect(seen.where((v) => v > 0.05), isNotEmpty, reason: 'git\'s percentages reach the job');

    await queue.cancel(job);
    while (job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    expect((await Process.run('pgrep', ['-f', cache.path])).exitCode, 1, reason: 'no git or fvm left running');
    expect(Directory(dest).existsSync(), isFalse, reason: 'the unfinished SDK folder is removed');
  }, skip: !const bool.fromEnvironment('LIVE'), timeout: const Timeout(Duration(minutes: 5)));
}
