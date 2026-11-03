import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/app_update.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/state/background.dart';
import 'package:stackyard/state/settings.dart';

import 'ui_test.dart' show fakeState;

void main() {
  test('the notification sums up updates, problems and space in one line', () {
    final alert = backgroundAlert(fakeState())!;
    expect(alert.body, startsWith('Flutter 3.47.7 is available · 1 problem needs attention · '));
    expect(alert.body, endsWith('GB can be freed.'));
  });

  test('the same news has the same key, so it is announced once', () {
    expect(backgroundAlert(fakeState())!.key, backgroundAlert(fakeState())!.key);
  });

  test('a newer Stackyard comes first', () {
    final state = fakeState()..appUpdate = AppRelease(version: '1.2.0', download: Uri.parse('https://example.test/Stackyard.dmg'));
    expect(backgroundAlert(state)!.body, startsWith('2 updates are available'));
    expect(backgroundAlert(state)!.key, startsWith('Stackyard 1.2.0,'));
  });

  test('nothing to say means no notification', () {
    expect(backgroundAlert(AppState(Settings.memory())), isNull);
  });
}
