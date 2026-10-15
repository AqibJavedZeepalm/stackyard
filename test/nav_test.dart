import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/state/app_state.dart';

import 'ui_test.dart' show app, fakeState, settle;

void main() {
  testWidgets('Overview stays selected while sidebar tiles appear', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final full = fakeState();
    final all = List<TechEntry>.of(full.techs);
    final state = fakeState()..techs = [];
    await tester.pumpWidget(app(state));
    await settle(tester);
    expect(find.text('Quick wins'), findsNothing);

    // First scan: tiles arrive one at a time.
    for (var i = 1; i <= all.length; i++) {
      state.techs = all.sublist(0, i);
      state.notifyListeners();
      await settle(tester);
    }
    expect(find.text('Quick wins'), findsOneWidget, reason: 'Overview should still be showing');

    // Section headers are visible in the open pane.
    expect(find.text('Toolchains'), findsOneWidget);
    expect(find.text('Frameworks'), findsOneWidget);
  });
}
