import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/stack_file.dart';
import 'package:stackyard/ui/stack_dialogs.dart';

import 'ui_test.dart' show fakeState;

void main() {
  Map<String, TechSnapshot> snapshots() => {
    for (final t in fakeState().techs)
      if (t.info.kind == TechKind.toolchain) t.id: t.snapshot,
  };

  test('export lists toolchain versions, marks the default, and skips broken things', () {
    final stack = StackFile.fromMachine(snapshots());
    final labels = stack.items.map((i) => i.label).toList();
    expect(labels, containsAll(['Flutter 3.35.5', 'Flutter 3.29.3', 'NDK 23.1.7779620']));
    expect(stack.items.firstWhere((i) => i.label == 'Flutter 3.29.3').global, isTrue);
    // The fake emulator is broken and emulators aren't part of a stack anyway.
    expect(labels.any((l) => l.contains('Pixel')), isFalse);
  });

  test('a stack survives saving and loading, and this machine has all of it', () {
    final snaps = snapshots();
    final back = StackFile.decode(StackFile.fromMachine(snaps).encode());
    expect(back.items, isNotEmpty);
    for (final item in back.items) {
      expect(StackFile.isInstalled(item, snaps[item.tech]), isTrue, reason: item.label);
    }
  });

  test('files that aren\'t stacks get a plain message', () {
    expect(() => StackFile.decode('not json'), throwsA(isA<FormatException>()));
    expect(() => StackFile.decode('{"hello": 1}'), throwsA(isA<FormatException>()));
  });

  test('Java and Python match by major / minor version', () {
    expect(StackFile.javaMajorOf('17.0.9'), 17);
    expect(StackFile.javaMajorOf('1.8.0_392'), 8);
    final py = TechSnapshot(
      managerLabel: 'x',
      items: [InstalledItem(id: 'p', version: '3.12.7', path: '')],
    );
    expect(StackFile.isInstalled(const StackItem(tech: 'python', kind: 'version', version: '3.12.4', label: 'Python 3.12.4'), py), isTrue);
    expect(StackFile.isInstalled(const StackItem(tech: 'python', kind: 'version', version: '3.11.9', label: 'Python 3.11.9'), py), isFalse);
  });

  testWidgets('the import screen says what is here, what installs, and what can\'t', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = fakeState();
    final stack = StackFile(
      from: 'OTHER-PC (Windows)',
      items: const [
        StackItem(tech: 'flutter', kind: 'version', version: '3.35.5', label: 'Flutter 3.35.5'),
        StackItem(tech: 'flutter', kind: 'version', version: '3.19.6', label: 'Flutter 3.19.6'),
      ],
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: state)],
        child: FluentApp(home: ImportStackDialog(stack: stack)),
      ),
    );
    await tester.pump();
    expect(find.text('Already here'), findsOneWidget);
    // No FVM in the fake machine, so the missing Flutter can't be installed here.
    expect(find.textContaining('Needs FVM'), findsOneWidget);
    expect(find.text('Nothing to install'), findsOneWidget);
    expect(find.textContaining('1 of 2 items'), findsOneWidget);
  });
}
