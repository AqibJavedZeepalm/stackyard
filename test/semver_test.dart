import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/semver.dart';

void main() {
  test('prefix pins', () {
    expect(satisfies('20.11.0', '20'), isTrue);
    expect(satisfies('20.11.0', 'v20.11'), isTrue);
    expect(satisfies('20.11.0', '20.11.1'), isFalse);
    expect(satisfies('18.19.0', '20'), isFalse);
  });

  test('ranges', () {
    expect(satisfies('20.11.0', '>=18'), isTrue);
    expect(satisfies('16.0.0', '>=18'), isFalse);
    expect(satisfies('18.2.0', '^18.0.0'), isTrue);
    expect(satisfies('19.0.0', '^18.0.0'), isFalse);
    expect(satisfies('3.11.4', '~3.11'), isTrue);
    expect(satisfies('3.12.0', '~3.11'), isFalse);
    expect(satisfies('20.1.0', '>=18 <21'), isTrue);
    expect(satisfies('22.0.0', '>=18 <21'), isFalse);
    expect(satisfies('16.0.0', '^14 || ^16'), isTrue);
    expect(satisfies('3.12.0', '>=3.10,<4'.replaceAll(',', ' ')), isTrue);
  });

  test('best match picks the highest satisfying version', () {
    expect(bestMatch(['18.19.0', '20.11.0', '20.18.1', '22.1.0'], '20'), '20.18.1');
    expect(bestMatch(['18.19.0'], '20'), isNull);
  });

  test('ordering handles prereleases', () {
    expect(compareVersions('3.29.3', '3.29.2'), greaterThan(0));
    expect(compareVersions('3.49.0-0.2.pre', '3.49.0'), lessThan(0));
    expect(compareVersions('10.0.0', '9.9.9'), greaterThan(0));
  });
}
