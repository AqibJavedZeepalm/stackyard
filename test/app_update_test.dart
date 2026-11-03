import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/app_update.dart';

void main() {
  // The fields of GitHub's GET /repos/{owner}/{repo}/releases/latest that matter.
  Map<String, dynamic> latest(String tag, {bool assets = true}) => {
    'tag_name': tag,
    'html_url': 'https://github.com/AqibJavedZeepalm/stackyard/releases/tag/$tag',
    'assets': [
      if (assets) ...[
        {'name': 'Stackyard-${tag.substring(1)}.dmg', 'browser_download_url': 'https://example.test/$tag/Stackyard.dmg'},
        {'name': 'Stackyard-Setup-${tag.substring(1)}.exe', 'browser_download_url': 'https://example.test/$tag/Stackyard-Setup.exe'},
      ],
    ],
  };

  test('a newer release offers the installer for this system', () {
    final mac = newerRelease(latest('v1.2.0'), '1.1.0', windows: false)!;
    expect(mac.version, '1.2.0');
    expect(mac.download.toString(), 'https://example.test/v1.2.0/Stackyard.dmg');
    expect(newerRelease(latest('v1.2.0'), '1.1.0', windows: true)!.download.toString(), 'https://example.test/v1.2.0/Stackyard-Setup.exe');
    expect(newerRelease(latest('v1.10.0'), '1.9.3', windows: false)?.version, '1.10.0', reason: 'versions compare as numbers');
  });

  test('the same or an older release, or a local build, offers nothing', () {
    expect(newerRelease(latest('v1.1.0'), '1.1.0', windows: false), isNull);
    expect(newerRelease(latest('v1.0.3'), '1.1.0', windows: false), isNull);
    expect(newerRelease(latest('v9.0.0'), 'dev', windows: false), isNull);
    expect(newerRelease(const {'message': 'Not Found'}, '1.1.0', windows: false), isNull);
  });

  test('without the installer attached yet, it opens the release page', () {
    expect(newerRelease(latest('v1.2.0', assets: false), '1.1.0', windows: true)!.download.toString(), 'https://github.com/AqibJavedZeepalm/stackyard/releases/tag/v1.2.0');
  });
}
