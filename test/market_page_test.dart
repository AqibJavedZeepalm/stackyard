import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/autostart.dart';

import 'ui_test.dart' show app, fakeState, settle;

void main() {
  testWidgets('the marketplace shows every tool, what you have, and filters', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AutoStart.testValue = false;
    final state = fakeState()..npmGlobalsForTest = {'firebase-tools': '15.1.0'};

    await tester.pumpWidget(app(state));
    await settle(tester);
    await tester.tap(find.text('Get tools'));
    await settle(tester);

    // Cards for SDKs and CLIs, with what's installed from the last scan or npm.
    expect(find.text('Flutter'), findsWidgets);
    expect(find.text('Go'), findsOneWidget);
    expect(find.text('Firebase CLI'), findsOneWidget);
    expect(find.textContaining('Installed · 15.1.0'), findsOneWidget);
    expect(find.textContaining('Installed · '), findsWidgets);
    expect(tester.takeException(), isNull);

    // Categories narrow the grid.
    // (The chip comes before the cards that also name their category.)
    await tester.tap(find.text('Package managers').first);
    await settle(tester);
    expect(find.text('pnpm'), findsOneWidget);
    expect(find.text('Go'), findsNothing);

    // Search works across names and descriptions.
    await tester.tap(find.text('All'));
    await settle(tester);
    await tester.enterText(find.byType(TextBox).first, 'rust');
    await settle(tester);
    expect(find.text('Rust'), findsOneWidget);
    expect(find.text('Go'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
