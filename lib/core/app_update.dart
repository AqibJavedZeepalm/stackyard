import 'dart:convert';

import 'package:http/http.dart' as http;

import 'semver.dart';
import 'sys.dart';

/// This build's version, set by the release workflow; "dev" for local runs.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// A newer Stackyard on GitHub, and the file to download for this computer.
class AppRelease {
  const AppRelease({required this.version, required this.download});
  final String version;
  final Uri download;
}

/// The newer release in GitHub's "latest release" [json], or null when [current]
/// is already that version (or newer, or a local build).
AppRelease? newerRelease(Map<String, dynamic> json, String current, {required bool windows}) {
  final tag = json['tag_name'];
  if (tag is! String || current == 'dev') return null;
  final version = tag.replaceFirst(RegExp('^v'), '');
  if (compareVersions(version, current) <= 0) return null;
  // The installer for this system, or the release page when it isn't attached.
  final asset = [
    for (final a in json['assets'] as List? ?? const [])
      if (a is Map && '${a['name']}'.endsWith(windows ? '.exe' : '.dmg')) a['browser_download_url'],
  ].whereType<String>().firstOrNull;
  final url = asset ?? json['html_url'];
  return url is String ? AppRelease(version: version, download: Uri.parse(url)) : null;
}

/// Asks GitHub whether a newer Stackyard is out. Network; null when it isn't or GitHub can't be reached.
Future<AppRelease?> checkForAppUpdate() async {
  if (appVersion == 'dev') return null;
  final res = await http
      .get(Uri.parse('https://api.github.com/repos/AqibJavedZeepalm/stackyard/releases/latest'), headers: {'Accept': 'application/vnd.github+json'})
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return null;
  return newerRelease(jsonDecode(res.body) as Map<String, dynamic>, appVersion, windows: Sys.isWindows);
}
