// Runs the Simulators page's actions against a real, throwaway simulator:
// start, shut down, erase, delete. macOS with Xcode only.
// Run with: flutter test test/simulators_live_test.dart --dart-define=LIVE=true
// ignore_for_file: avoid_print
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/techs/tech.dart';
import 'package:stackyard/core/techs/xcode_tech.dart';
import 'package:stackyard/state/jobs.dart';

const live = bool.fromEnvironment('LIVE');

Future<Job> runJob(PlannedChange change) async {
  final queue = JobQueue(onJobFinished: (_) {});
  final job = queue.enqueue(change);
  while (job.status == JobStatus.queued || job.status == JobStatus.running) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return job;
}

void main() {
  test('start, shut down, erase and delete a throwaway simulator', () async {
    final tech = XcodeTech();
    Future<InstalledItem?> find(String udid) async =>
        (await tech.detect(ScanContext(const [])))?.items.where((i) => XcodeTech.udid(i) == udid).firstOrNull;

    // An iPhone 16 on an iOS runtime this Mac has.
    final snap = (await tech.detect(ScanContext(const [])))!;
    final runtime = snap.items.where((i) => i.group == XcodeTech.runtimesGroup && i.title.startsWith('iOS') && !i.isBroken).first;
    final rid = 'com.apple.CoreSimulator.SimRuntime.iOS-${runtime.version.replaceAll('.', '-')}';
    final created = await Process.run('xcrun', ['simctl', 'create', 'Stackyard Test', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', rid]);
    expect(created.exitCode, 0, reason: '${created.stderr}');
    final udid = '${created.stdout}'.trim();
    addTearDown(() => Process.run('xcrun', ['simctl', 'delete', udid]));

    var sim = (await find(udid))!;
    expect(sim.details['OS'], 'iOS ${runtime.version}');
    expect(sim.isBroken, isFalse);
    expect(snap.items.firstWhere((i) => i.id == runtime.id).usedBy, isNotEmpty);

    // Start boots it (and opens Simulator.app); shut down stops it.
    await Process.run('xcrun', ['simctl', 'boot', udid]);
    expect(await XcodeTech.booted(), contains(udid));
    await XcodeTech.shutDown(sim);
    expect(await XcodeTech.booted(), isNot(contains(udid)));

    final erase = await runJob(XcodeTech.planErase(sim));
    expect(erase.status, JobStatus.done, reason: erase.error);

    sim = (await find(udid))!;
    final remove = await runJob(tech.planRemove(sim)!);
    expect(remove.status, JobStatus.done, reason: remove.error);
    expect(await find(udid), isNull);
    print('simulator $udid: created, booted, shut down, erased, deleted');
  }, skip: !live, timeout: const Timeout(Duration(minutes: 5)));
}
