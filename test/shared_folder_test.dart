import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/state/jobs.dart';

void main() {
  test('folders other programs share are never removable', () {
    final home = Sys.home;
    if (Platform.isWindows) {
      for (final shared in [r'C:\', r'C:\Windows', r'C:\Windows\System32', r'C:\ProgramData\chocolatey\bin', p.join(home, 'scoop', 'shims'), r'C:\Program Files', home]) {
        expect(Sys.isSharedFolder(shared), isTrue, reason: shared);
      }
      for (final own in [p.join(home, 'sdks', 'node', '24.0.0'), r'C:\Program Files\nodejs', p.join(home, 'fvm', 'versions', '3.47.7')]) {
        expect(Sys.isSharedFolder(own), isFalse, reason: own);
      }
    } else {
      for (final shared in ['/', '/usr/local', '/usr/local/bin', '/opt/homebrew', '/opt/homebrew/bin', '/opt/homebrew/Cellar/node/24.0.0', '/usr/bin', home]) {
        expect(Sys.isSharedFolder(shared), isTrue, reason: shared);
      }
      for (final own in [p.join(home, 'sdks', 'node', '24.0.0'), p.join(home, '.nvm', 'versions', 'node', 'v24.0.0'), '/Library/Java/JavaVirtualMachines/temurin-21.jdk']) {
        expect(Sys.isSharedFolder(own), isFalse, reason: own);
      }
    }

    final shared = InstalledItem(id: 'x', version: '1', path: Platform.isWindows ? r'C:\ProgramData\chocolatey\bin' : '/opt/homebrew/bin');
    expect(shared.removable, isFalse);
    expect(shared.removeHint, contains('other programs share'));
    final own = InstalledItem(id: 'y', version: '1', path: p.join(home, 'sdks', 'go', '1.0'));
    expect(own.removable, isTrue);
  });

  test('a job refuses to remove a shared folder, whatever asked for it', () async {
    final queue = JobQueue(onJobFinished: (_) {});
    final job = queue.enqueue(PlannedChange(title: 'Remove', recycle: [Sys.home], permanent: true));
    while (job.status == JobStatus.queued || job.status == JobStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(job.status, JobStatus.failed);
    expect(job.error, contains('shared by other programs'));
    expect(Directory(Sys.home).existsSync(), isTrue);
  });
}
