import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/autostart.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/state/jobs.dart';

import 'ui_test.dart' show app, fakeState, settle;

void main() {
  testWidgets('work in progress shows loaders where it happens', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AutoStart.testValue = false;

    final state = fakeState();
    // A removal of the unused Flutter 3.22.3 that's running right now (no real process).
    state.jobs.jobs.add(
      Job(
          const PlannedChange(title: 'Remove Flutter 3.22.3', recycle: [r'C:\fvm\versions\3.22.3']),
          removesItemIds: ['f4'],
        )
        ..status = JobStatus.running
        ..step = 1,
    );
    await tester.pumpWidget(app(state));
    await settle(tester);

    // Title bar names the job; Overview's quick win and its Clean up button show it's busy.
    expect(find.text('Remove Flutter 3.22.3'), findsOneWidget);
    expect(find.text('Removing…'), findsOneWidget);
    expect(find.text('Cleaning…'), findsOneWidget);

    // The Flutter page's row for 3.22.3 too.
    await tester.tap(find.text('Flutter').first);
    await settle(tester);
    expect(find.text('Removing…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('a job touches an item by id, by its path, or by files inside it', () {
    final queue = JobQueue(onJobFinished: (_) {});
    queue.jobs.add(
      Job(
        const PlannedChange(title: 'Wipe Pixel', recycle: [r'C:\avd\Pixel.avd\userdata-qemu.img']),
        removesItemIds: ['x'],
      )..status = JobStatus.queued,
    );
    expect(queue.touches(id: 'x'), isTrue);
    expect(queue.touches(path: r'C:\avd\Pixel.avd'), isTrue);
    expect(queue.touches(path: r'C:\avd\Other.avd'), isFalse);
    expect(queue.isBusy('Wipe Pixel'), isTrue);
    expect(queue.isBusy('Something else'), isFalse);
  });
}
