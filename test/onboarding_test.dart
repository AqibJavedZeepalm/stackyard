import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/core/autostart.dart';
import 'package:stackyard/state/settings.dart';
import 'package:stackyard/ui/onboarding.dart';

void main() {
  testWidgets('first run: finds folders, then saves the picks and preferences', (tester) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AutoStart.testValue = false;
    final settings = Settings.memory()
      ..onboarded = false
      ..roots = [];

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: FluentApp(theme: FluentThemeData(), home: const Onboarding(nativeChrome: false)),
      ),
    );
    // The folder search runs in another isolate: let it finish for real.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Stackyard'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Where are your projects?'), findsOneWidget);
    expect(find.text('Add folder…'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Glass'), findsOneWidget);
    expect(find.text('Keep running when closed'), findsOneWidget);

    // Back keeps what was found; then finish.
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Where are your projects?'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start scanning'));
    await tester.pumpAndSettle();

    expect(settings.onboarded, isTrue);
    expect(tester.takeException(), isNull);
  });
}
