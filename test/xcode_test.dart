import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/techs/xcode_tech.dart';

void main() {
  final tech = XcodeTech();
  InstalledItem runtime() => InstalledItem(
    id: 'xcode:runtime:ABC',
    version: '18.4',
    label: 'iOS 18.4',
    path: '',
    group: XcodeTech.runtimesGroup,
    details: const {'Build': '22E238', 'Identifier': 'ABC'},
  )..sizeBytes = 8825558354;

  test('a runtime no simulator uses is a quick win, deleted through simctl', () {
    final r = runtime();
    expect(r.reclaimable, isTrue);
    final plan = tech.planRemove(r)!;
    expect(plan.recycle, isEmpty, reason: 'runtimes live in a system disk image, never in the Trash');
    expect(plan.commands.single.arguments, ['simctl', 'runtime', 'delete', 'ABC']);
  });

  test('a runtime in use warns that its simulators stop working', () {
    final r = runtime()..usedBy.add(const UsageRef(name: 'iPhone 16 Pro', path: '/x', kind: 'simulator'));
    expect(r.reclaimable, isFalse);
    expect(tech.planRemove(r)!.warning, contains('1 simulator uses it'));
  });

  test('simulators are deleted and erased through simctl', () {
    final sim = InstalledItem(
      id: 'xcode:sim:U1',
      version: 'iPhone 16 Pro',
      path: '/Users/me/Library/Developer/CoreSimulator/Devices/U1',
      group: XcodeTech.simulatorsGroup,
      usageTracked: false,
      details: const {'UDID': 'U1', 'OS': 'iOS 18.4'},
    );
    expect(tech.planRemove(sim)!.commands.single.arguments, ['simctl', 'delete', 'U1']);
    expect(XcodeTech.planErase(sim).commands.single.arguments, ['simctl', 'erase', 'U1']);
    expect(XcodeTech.planErase(sim).confirmLabel, 'Erase', reason: 'not "Uninstall"');
    expect(tech.planRemove(sim)!.confirmLabel, 'Delete');
  });
}
