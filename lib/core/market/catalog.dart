import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:ui' show Color;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models.dart';
import '../sys.dart';

enum MarketCategory {
  languages('Languages & runtimes'),
  mobile('Mobile'),
  build('Build tools'),
  cli('Framework CLIs'),
  packages('Package managers');

  const MarketCategory(this.label);
  final String label;
}

/// One installable version of a tool.
class MarketVersion {
  const MarketVersion(this.version, {this.channel, this.stable = true, this.lts = false, this.date, this.data});
  final String version;

  /// "LTS", "beta", "preview"…
  final String? channel;
  final bool stable;
  final bool lts;
  final DateTime? date;

  /// Whatever the source needs later to find the download.
  final Object? data;
}

/// What it takes to install one version: a download, then maybe commands.
class MarketPlan {
  const MarketPlan({this.download, this.commands = const [], this.fixedLocation, this.note});
  final DownloadStep? download;
  final List<CommandSpec> commands;

  /// Set when the tool always installs to one place (e.g. Python's macOS installer).
  final String? fixedLocation;
  final String? note;
}

/// A tool in the marketplace: where its versions come from and how to install one.
abstract class MarketTool {
  String get id;
  String get name;
  String get description;
  MarketCategory get category;
  TechInfo get look;
  String get homepage;

  /// The Stackyard tech (sidebar page) this tool belongs to, if any.
  String? get techId => null;

  /// All versions, newest first. Network.
  Future<List<MarketVersion>> versions();

  /// How to install [v] into [dest], or null when it isn't available for this computer.
  Future<MarketPlan?> plan(MarketVersion v, String dest);

  /// The environment variables this tool needs once installed in [dest].
  /// [root] holds every version of it, so other versions' PATH entries can be swapped out.
  List<EnvChange> env(String dest, String root) => [EnvChange.prependPath(dest, replacePrefix: root)];

  /// Installs through npm instead of into a folder of its own.
  bool get viaNpm => false;

  /// The program PATH should find once this is the default (to tell which version is active).
  String? get binary => {
    'flutter': 'flutter',
    'node': 'node',
    // python.org's macOS installer only adds python3.
    'python': Sys.isWindows ? 'python' : 'python3',
    'java': 'java',
    'dotnet': 'dotnet',
    'go': 'go',
    'rust': 'cargo',
    'deno': 'deno',
    'bun': 'bun',
    'gradle': 'gradle',
    'android-cmdline-tools': 'sdkmanager',
  }[id];
}

// ---- Platform helpers ----

bool get _arm => Abi.current() == Abi.macosArm64 || Abi.current() == Abi.windowsArm64;
bool get _mac => !Sys.isWindows;
String get _exe => Sys.isWindows ? '.exe' : '';

Future<dynamic> _json(String url, {Map<String, String>? headers}) async {
  final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'Stackyard', ...?headers}).timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) throw Exception('$url answered ${res.statusCode}');
  return jsonDecode(res.body);
}

Future<String> _text(String url) async {
  final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'Stackyard'}).timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) throw Exception('$url answered ${res.statusCode}');
  return res.body;
}

DateTime? _date(Object? s) => s is String ? DateTime.tryParse(s) : null;

TechInfo _look(String id, String name, int color, String monogram, {String? logo, LogoTint tint = LogoTint.none, TechKind kind = TechKind.toolchain}) =>
    TechInfo(id: id, name: name, kind: kind, color: Color(color), monogram: monogram, logo: logo, logoTint: tint);

// ---- Tools ----

class FlutterMarket extends MarketTool {
  @override
  final id = 'flutter';
  @override
  final name = 'Flutter';
  @override
  final description = 'Google\'s UI toolkit for mobile, web and desktop apps, with Dart included.';
  @override
  final category = MarketCategory.mobile;
  @override
  final homepage = 'https://flutter.dev';
  @override
  String? get techId => 'flutter';
  @override
  TechInfo get look => _look('flutter', 'Flutter', 0xFF02569B, 'Fl', logo: 'assets/tech/flutter.svg');

  String get _os => Sys.isWindows ? 'windows' : 'macos';

  @override
  Future<List<MarketVersion>> versions() async {
    final j = await _json('https://storage.googleapis.com/flutter_infra_release/releases/releases_$_os.json') as Map;
    final base = j['base_url'] as String;
    final seen = <String>{};
    return [
      for (final r in (j['releases'] as List).cast<Map>())
        // macOS lists an arm64 and an x64 build of each release; pick ours.
        if (!_mac || (r['dart_sdk_arch'] ?? 'x64') == (_arm ? 'arm64' : 'x64'))
          if (seen.add(r['version'] as String))
            MarketVersion(
              r['version'] as String,
              channel: r['channel'] as String,
              stable: r['channel'] == 'stable',
              date: _date(r['release_date']),
              data: (url: '$base/${r['archive']}', sha256: r['sha256'] as String?),
            ),
    ];
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final d = v.data! as ({String url, String? sha256});
    return MarketPlan(
      download: DownloadStep(url: d.url, sha256: d.sha256, label: 'Flutter ${v.version}', extractTo: dest),
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => [EnvChange.prependPath(p.join(dest, 'bin'), replacePrefix: root)];
}

class NodeMarket extends MarketTool {
  @override
  final id = 'node';
  @override
  final name = 'Node.js';
  @override
  final description = 'JavaScript runtime, with npm. LTS versions are the safe choice for most projects.';
  @override
  final category = MarketCategory.languages;
  @override
  final homepage = 'https://nodejs.org';
  @override
  String? get techId => 'node';
  @override
  TechInfo get look => _look('node', 'Node.js', 0xFF5FA04E, 'N', logo: 'assets/tech/node.svg');

  String get _platform => Sys.isWindows ? (_arm ? 'win-arm64' : 'win-x64') : (_arm ? 'darwin-arm64' : 'darwin-x64');
  String get _fileKey => Sys.isWindows ? (_arm ? 'win-arm64-zip' : 'win-x64-zip') : (_arm ? 'osx-arm64-tar' : 'osx-x64-tar');

  @override
  Future<List<MarketVersion>> versions() async {
    final list = (await _json('https://nodejs.org/dist/index.json') as List).cast<Map>();
    return [
      for (final r in list)
        if ((r['files'] as List).contains(_fileKey))
          MarketVersion(
            (r['version'] as String).substring(1),
            channel: r['lts'] is String ? 'LTS ${r['lts']}' : 'Current',
            lts: r['lts'] is String,
            stable: true,
            date: _date(r['date']),
          ),
    ];
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final file = 'node-v${v.version}-$_platform.${Sys.isWindows ? 'zip' : 'tar.gz'}';
    return MarketPlan(
      download: DownloadStep(
        url: 'https://nodejs.org/dist/v${v.version}/$file',
        checksumUrl: 'https://nodejs.org/dist/v${v.version}/SHASUMS256.txt',
        label: 'Node.js ${v.version}',
        extractTo: dest,
      ),
      note: 'If nvm, fnm or Volta also manages Node, whichever comes first on PATH wins.',
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => [EnvChange.prependPath(Sys.isWindows ? dest : p.join(dest, 'bin'), replacePrefix: root)];
}

class PythonMarket extends MarketTool {
  @override
  final id = 'python';
  @override
  final name = 'Python';
  @override
  final description = 'The Python language from python.org, with pip.';
  @override
  final category = MarketCategory.languages;
  @override
  final homepage = 'https://www.python.org';
  @override
  String? get techId => 'python';
  @override
  TechInfo get look => _look('python', 'Python', 0xFF3776AB, 'Py', logo: 'assets/tech/python.svg');

  @override
  Future<List<MarketVersion>> versions() async {
    // python.org's own index of every Windows build (the Python install manager's),
    // read in pages. macOS uses the same version numbers with python.org's installer.
    final out = <MarketVersion>[];
    final seen = <String>{};
    final arch = _arm && Sys.isWindows ? 'arm64' : '64';
    String? next = 'index-windows.json';
    for (var page = 0; next != null && page < 4; page++) {
      final j = await _json('https://www.python.org/ftp/python/$next') as Map;
      for (final e in (j['versions'] as List).cast<Map>()) {
        final id = e['id'] as String;
        if (!RegExp('^pythoncore-\\d+\\.\\d+-$arch\$').hasMatch(id)) continue;
        final v = e['sort-version'] as String;
        if (!seen.add(v)) continue;
        final stable = RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v);
        out.add(
          MarketVersion(
            v,
            stable: stable,
            channel: stable ? null : 'preview',
            data: (url: e['url'] as String, sha256: (e['hash'] as Map?)?['sha256'] as String?),
          ),
        );
      }
      next = j['next'] as String?;
    }
    return out;
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    if (Sys.isWindows) {
      final d = v.data! as ({String url, String? sha256});
      return MarketPlan(
        download: DownloadStep(url: d.url, sha256: d.sha256, label: 'Python ${v.version}', extractTo: dest),
      );
    }
    // macOS: python.org's installer, which always installs into /Library/Frameworks.
    final minor = v.version.split('.').take(2).join('.');
    final pkg = p.join(Sys.home, '.stackyard-downloads', 'python-${v.version}-macos11.pkg');
    // Previews (3.15.0rc1) live in their release's folder (3.15.0).
    final url = 'https://www.python.org/ftp/python/${RegExp(r'^\d+\.\d+\.\d+').stringMatch(v.version) ?? v.version}/python-${v.version}-macos11.pkg';
    return MarketPlan(
      download: DownloadStep(url: url, sha256: await _macPkgSha256(v.version, url), label: 'Python ${v.version}', saveAs: pkg),
      commands: [
        CommandSpec(
          title: 'Run the python.org installer (asks for your password)',
          executable: 'osascript',
          arguments: ['-e', 'do shell script "installer -pkg \'$pkg\' -target /" with administrator privileges'],
        ),
      ],
      fixedLocation: '/Library/Frameworks/Python.framework/Versions/$minor',
      note: 'On macOS, python.org\'s installer always installs into /Library/Frameworks.',
    );
  }

  /// python.org's published SHA-256 of the macOS installer.
  Future<String> _macPkgSha256(String version, String url) async {
    final release = (await _json('https://www.python.org/api/v2/downloads/release/?name=${Uri.encodeQueryComponent('Python $version')}') as List).single as Map;
    final id = (release['resource_uri'] as String).split('/').where((s) => s.isNotEmpty).last;
    final files = (await _json('https://www.python.org/api/v2/downloads/release_file/?release=$id') as List).cast<Map>();
    final sha = files.firstWhere((f) => f['url'] == url)['sha256_sum'] as String?;
    if (sha == null || sha.isEmpty) throw Exception('python.org lists no checksum for $url');
    return sha;
  }

  @override
  List<EnvChange> env(String dest, String root) => Sys.isWindows
      ? [EnvChange.prependPath(p.join(dest, 'Scripts'), replacePrefix: root), EnvChange.prependPath(dest, replacePrefix: root)]
      : [EnvChange.prependPath(p.join(dest, 'bin'))];
}

class JavaMarket extends MarketTool {
  @override
  final id = 'java';
  @override
  final name = 'Java (JDK)';
  @override
  final description = 'Eclipse Temurin, the free OpenJDK build. Android and Flutter builds need 17 or 21.';
  @override
  final category = MarketCategory.languages;
  @override
  final homepage = 'https://adoptium.net';
  @override
  String? get techId => 'java';
  @override
  TechInfo get look => _look('java', 'Java', 0xFFE76F00, 'J', logo: 'assets/tech/java.svg');

  String get _os => Sys.isWindows ? 'windows' : 'mac';
  String get _arch => _arm ? 'aarch64' : 'x64';

  @override
  Future<List<MarketVersion>> versions() async {
    final info = await _json('https://api.adoptium.net/v3/info/available_releases') as Map;
    final lts = (info['available_lts_releases'] as List).cast<int>().toSet();
    final majors = (info['available_releases'] as List).cast<int>().reversed.toList();
    // Recent builds of every major version, fetched side by side.
    final lists = await Future.wait(
      majors.map((m) async {
        try {
          final r = await _json(
            'https://api.adoptium.net/v3/assets/feature_releases/$m/ga?os=$_os&architecture=$_arch&image_type=jdk&jvm_impl=hotspot&page_size=10&sort_order=DESC',
          );
          return (r as List).cast<Map>().map((a) {
            final pkg = ((a['binaries'] as List).first as Map)['package'] as Map;
            final v = (a['version_data'] as Map)['openjdk_version'] as String? ?? a['release_name'] as String;
            return MarketVersion(
              v.replaceFirst(RegExp(r'-LTS$'), ''),
              lts: lts.contains(m),
              channel: lts.contains(m) ? 'LTS' : null,
              date: _date(a['timestamp']),
              data: (url: pkg['link'] as String, sha256: pkg['checksum'] as String?, size: pkg['size'] as int?),
            );
          }).toList();
        } catch (_) {
          return <MarketVersion>[];
        }
      }),
    );
    return lists.expand((l) => l).toList();
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final d = v.data! as ({String url, String? sha256, int? size});
    return MarketPlan(
      download: DownloadStep(url: d.url, sha256: d.sha256, size: d.size, label: 'JDK ${v.version}', extractTo: dest),
    );
  }

  /// macOS JDKs keep the real home in Contents/Home.
  String home(String dest) => _mac ? p.join(dest, 'Contents', 'Home') : dest;

  @override
  List<EnvChange> env(String dest, String root) => [
    EnvChange.set('JAVA_HOME', home(dest)),
    EnvChange.prependPath(p.join(home(dest), 'bin'), replacePrefix: root),
  ];
}

class DotnetMarket extends MarketTool {
  @override
  final id = 'dotnet';
  @override
  final name = '.NET SDK';
  @override
  final description = 'Microsoft\'s SDK for C#, F# and .NET apps.';
  @override
  final category = MarketCategory.languages;
  @override
  final homepage = 'https://dot.net';
  @override
  String? get techId => 'dotnet';
  @override
  TechInfo get look => _look('dotnet', '.NET SDK', 0xFF512BD4, '.N', logo: 'assets/tech/dotnet.svg', tint: LogoTint.brand);

  String get _rid => Sys.isWindows ? (_arm ? 'win-arm64' : 'win-x64') : (_arm ? 'osx-arm64' : 'osx-x64');

  @override
  Future<List<MarketVersion>> versions() async {
    final index = await _json('https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json') as Map;
    final channels = (index['releases-index'] as List).cast<Map>();
    final lists = await Future.wait(
      channels.map((c) async {
        try {
          final j = await _json(c['releases.json'] as String) as Map;
          final type = c['release-type'] as String?;
          final phase = c['support-phase'] as String?;
          return [
            for (final r in (j['releases'] as List).cast<Map>())
              for (final sdk in [...?(r['sdks'] as List?)?.cast<Map>(), if (r['sdks'] == null && r['sdk'] != null) r['sdk'] as Map])
                if ((sdk['files'] as List).cast<Map>().any((f) => f['rid'] == _rid && (f['name'] as String).endsWith(Sys.isWindows ? '.zip' : '.tar.gz')))
                  MarketVersion(
                    sdk['version'] as String,
                    lts: type == 'lts',
                    stable: phase != 'preview' && phase != 'go-live' && !(sdk['version'] as String).contains('-'),
                    channel: [if (type != null) type.toUpperCase(), if (phase == 'eol') 'out of support'].join(' · '),
                    date: _date(r['release-date']),
                    data: (sdk['files'] as List).cast<Map>().firstWhere(
                      (f) => f['rid'] == _rid && (f['name'] as String).endsWith(Sys.isWindows ? '.zip' : '.tar.gz'),
                    ),
                  ),
          ];
        } catch (_) {
          return <MarketVersion>[];
        }
      }),
    );
    final seen = <String>{};
    return [
      for (final v in lists.expand((l) => l))
        if (seen.add(v.version)) v,
    ];
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final f = v.data! as Map;
    return MarketPlan(
      download: DownloadStep(url: f['url'] as String, sha512: f['hash'] as String?, label: '.NET SDK ${v.version}', extractTo: dest),
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => [EnvChange.set('DOTNET_ROOT', dest), EnvChange.prependPath(dest, replacePrefix: root)];
}

class GoMarket extends MarketTool {
  @override
  final id = 'go';
  @override
  final name = 'Go';
  @override
  final description = 'The Go programming language and toolchain.';
  @override
  final category = MarketCategory.languages;
  @override
  final homepage = 'https://go.dev';
  @override
  String? get techId => 'go';
  @override
  TechInfo get look => _look('go', 'Go', 0xFF00ADD8, 'Go', logo: 'assets/tech/go.svg');

  @override
  Future<List<MarketVersion>> versions() async {
    final list = (await _json('https://go.dev/dl/?mode=json&include=all') as List).cast<Map>();
    final os = Sys.isWindows ? 'windows' : 'darwin';
    final arch = _arm ? 'arm64' : 'amd64';
    return [
      for (final r in list)
        if ((r['files'] as List).cast<Map>().where((f) => f['os'] == os && f['arch'] == arch && f['kind'] == 'archive').firstOrNull case final f?)
          MarketVersion(
            (r['version'] as String).replaceFirst('go', ''),
            stable: r['stable'] == true,
            channel: r['stable'] == true ? null : 'preview',
            data: (url: 'https://go.dev/dl/${f['filename']}', sha256: f['sha256'] as String?),
          ),
    ];
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final d = v.data! as ({String url, String? sha256});
    return MarketPlan(
      download: DownloadStep(url: d.url, sha256: d.sha256, label: 'Go ${v.version}', extractTo: dest),
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => [EnvChange.set('GOROOT', dest), EnvChange.prependPath(p.join(dest, 'bin'), replacePrefix: root)];
}

class RustMarket extends MarketTool {
  @override
  final id = 'rust';
  @override
  final name = 'Rust';
  @override
  final description = 'Rust with Cargo, installed with rustup into a folder you choose.';
  @override
  final category = MarketCategory.languages;
  @override
  final homepage = 'https://www.rust-lang.org';
  @override
  String? get techId => 'rust';
  @override
  TechInfo get look => _look('rust', 'Rust', 0xFFDEA584, 'Rs', logo: 'assets/tech/rust.svg', tint: LogoTint.foreground);

  String get _triple => Sys.isWindows ? (_arm ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc') : (_arm ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin');

  @override
  Future<List<MarketVersion>> versions() async {
    final md = await _text('https://raw.githubusercontent.com/rust-lang/rust/master/RELEASES.md');
    return [
      for (final m in RegExp(r'^Version (\d+\.\d+\.\d+) \((\d{4}-\d\d-\d\d)\)', multiLine: true).allMatches(md))
        MarketVersion(m[1]!, date: DateTime.tryParse(m[2]!)),
    ];
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final init = p.join(dest, 'rustup-init$_exe');
    final url = 'https://static.rust-lang.org/rustup/dist/$_triple/rustup-init$_exe';
    return MarketPlan(
      download: DownloadStep(url: url, checksumUrl: '$url.sha256', label: 'rustup', saveAs: init),
      commands: [
        CommandSpec(
          title: 'Install Rust ${v.version} with rustup',
          executable: init,
          arguments: ['-y', '--no-modify-path', '--profile', 'default', '--default-toolchain', v.version],
          environment: {'RUSTUP_HOME': p.join(dest, 'rustup'), 'CARGO_HOME': p.join(dest, 'cargo')},
        ),
      ],
      note: Sys.isWindows ? 'Rust on Windows uses the Visual Studio C++ build tools to link programs.' : null,
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => [
    EnvChange.set('RUSTUP_HOME', p.join(dest, 'rustup')),
    EnvChange.set('CARGO_HOME', p.join(dest, 'cargo')),
    EnvChange.prependPath(p.join(dest, 'cargo', 'bin'), replacePrefix: root),
  ];
}

/// A runtime published as one archive per version, with versions listed on npm.
class _NpmListedRuntime extends MarketTool {
  _NpmListedRuntime({
    required this.id,
    required this.name,
    required this.description,
    required this.homepage,
    required this.look,
    required this.npmPackage,
    required this.url,
    this.checksumUrl,
  });
  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  @override
  final String homepage;
  @override
  final TechInfo look;
  @override
  final category = MarketCategory.languages;
  @override
  String? get techId => id;
  final String npmPackage;
  final String Function(String version) url;
  final String Function(String version)? checksumUrl;

  @override
  Future<List<MarketVersion>> versions() => npmVersions(npmPackage);

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async => MarketPlan(
    download: DownloadStep(url: url(v.version), checksumUrl: checksumUrl?.call(v.version), label: '$name ${v.version}', extractTo: dest),
  );
}

MarketTool denoMarket() => _NpmListedRuntime(
  id: 'deno',
  name: 'Deno',
  description: 'A secure JavaScript and TypeScript runtime, with tooling built in.',
  homepage: 'https://deno.com',
  look: _look('deno', 'Deno', 0xFF000000, 'De', logo: 'assets/tech/deno.svg', tint: LogoTint.foreground),
  npmPackage: 'deno',
  url: (v) => 'https://github.com/denoland/deno/releases/download/v$v/deno-${Sys.isWindows ? 'x86_64-pc-windows-msvc' : (_arm ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin')}.zip',
  checksumUrl: (v) =>
      'https://github.com/denoland/deno/releases/download/v$v/deno-${Sys.isWindows ? 'x86_64-pc-windows-msvc' : (_arm ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin')}.zip.sha256sum',
);

MarketTool bunMarket() => _NpmListedRuntime(
  id: 'bun',
  name: 'Bun',
  description: 'A fast JavaScript runtime, bundler, test runner and package manager.',
  homepage: 'https://bun.sh',
  look: _look('bun', 'Bun', 0xFFFBF0DF, 'Bn', logo: 'assets/tech/bun.svg'),
  npmPackage: 'bun',
  url: (v) => 'https://github.com/oven-sh/bun/releases/download/bun-v$v/bun-${Sys.isWindows ? 'windows-x64' : (_arm ? 'darwin-aarch64' : 'darwin-x64')}.zip',
  checksumUrl: (v) => 'https://github.com/oven-sh/bun/releases/download/bun-v$v/SHASUMS256.txt',
);

class GradleMarket extends MarketTool {
  @override
  final id = 'gradle';
  @override
  final name = 'Gradle';
  @override
  final description = 'The build tool behind Android. Projects usually bring their own through the wrapper.';
  @override
  final category = MarketCategory.build;
  @override
  final homepage = 'https://gradle.org';
  @override
  String? get techId => 'gradle';
  @override
  TechInfo get look => _look('gradle', 'Gradle', 0xFF209BC4, 'G', logo: 'assets/tech/gradle.svg', tint: LogoTint.foreground);

  @override
  Future<List<MarketVersion>> versions() async {
    final list = (await _json('https://services.gradle.org/versions/all') as List).cast<Map>();
    return [
      for (final r in list)
        if (r['snapshot'] != true && r['nightly'] != true && r['releaseNightly'] != true && r['broken'] != true)
          MarketVersion(
            r['version'] as String,
            stable: (r['rcFor'] as String? ?? '').isEmpty && (r['milestoneFor'] as String? ?? '').isEmpty,
            channel: (r['rcFor'] as String? ?? '').isNotEmpty ? 'RC' : ((r['milestoneFor'] as String? ?? '').isNotEmpty ? 'milestone' : null),
            data: (url: r['downloadUrl'] as String, sum: r['checksumUrl'] as String?),
          ),
    ];
  }

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final d = v.data! as ({String url, String? sum});
    return MarketPlan(
      download: DownloadStep(url: d.url, checksumUrl: d.sum, label: 'Gradle ${v.version}', extractTo: dest),
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => [EnvChange.set('GRADLE_HOME', dest), EnvChange.prependPath(p.join(dest, 'bin'), replacePrefix: root)];
}

class AndroidToolsMarket extends MarketTool {
  AndroidToolsMarket(this.sdkRoot);

  /// The Android SDK folder to install into (an existing one, or a new one).
  final String Function() sdkRoot;

  @override
  final id = 'android-cmdline-tools';
  @override
  final name = 'Android command-line tools';
  @override
  final description = 'sdkmanager and avdmanager. With them, Stackyard can install Android platforms, NDKs and emulators.';
  @override
  final category = MarketCategory.mobile;
  @override
  final homepage = 'https://developer.android.com/tools';
  @override
  String? get techId => 'android';
  @override
  TechInfo get look => _look('android', 'Android SDK', 0xFF3DDC84, 'A', logo: 'assets/tech/android.svg', tint: LogoTint.brand);

  @override
  Future<List<MarketVersion>> versions() async {
    final xml = await _text('https://dl.google.com/android/repository/repository2-3.xml');
    final os = Sys.isWindows ? 'windows' : 'macosx';
    final out = <MarketVersion>[];
    for (final pkg in RegExp(r'<remotePackage path="cmdline-tools;([^"]+)">([\s\S]*?)</remotePackage>').allMatches(xml)) {
      final ver = pkg[1]!;
      if (ver == 'latest') continue;
      final archive = RegExp(
        '<archive>([\\s\\S]*?)</archive>',
      ).allMatches(pkg[2]!).map((a) => a[1]!).where((a) => a.contains('<host-os>$os</host-os>')).firstOrNull;
      if (archive == null) continue;
      final url = RegExp(r'<url>([^<]+)</url>').firstMatch(archive)?[1];
      final sha1 = RegExp(r'<checksum type="sha1">([^<]+)</checksum>').firstMatch(archive)?[1];
      if (url == null) continue;
      final stable = !ver.contains('-');
      out.add(MarketVersion(ver, stable: stable, channel: stable ? null : 'preview', data: (url: 'https://dl.google.com/android/repository/$url', sha1: sha1)));
    }
    out.sort((a, b) => _num(b.version).compareTo(_num(a.version)));
    return out;
  }

  static double _num(String v) => double.tryParse(v.split('-').first) ?? 0;

  /// Command-line tools live in `<sdk>/cmdline-tools/<version>`, not a folder of their own.
  String destFor(MarketVersion v) => p.join(sdkRoot(), 'cmdline-tools', v.version);

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final d = v.data! as ({String url, String? sha1});
    return MarketPlan(
      download: DownloadStep(url: d.url, sha1: d.sha1, label: 'Android command-line tools ${v.version}', extractTo: dest),
    );
  }

  @override
  List<EnvChange> env(String dest, String root) {
    final sdk = p.dirname(p.dirname(dest));
    return [
      EnvChange.set('ANDROID_HOME', sdk),
      EnvChange.prependPath(p.join(dest, 'bin'), replacePrefix: p.join(sdk, 'cmdline-tools')),
      EnvChange.prependPath(p.join(sdk, 'platform-tools')),
    ];
  }
}

/// A command-line tool installed globally with npm.
class NpmCliMarket extends MarketTool {
  NpmCliMarket({
    required this.id,
    required this.name,
    required this.description,
    required this.package,
    required this.homepage,
    required this.look,
    this.category = MarketCategory.cli,
  });
  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  final String package;
  @override
  final String homepage;
  @override
  final TechInfo look;
  @override
  final MarketCategory category;
  @override
  bool get viaNpm => true;

  @override
  Future<List<MarketVersion>> versions() => npmVersions(package);

  @override
  Future<MarketPlan?> plan(MarketVersion v, String dest) async {
    final npm = Sys.which('npm');
    if (npm == null) return null;
    return MarketPlan(
      commands: [
        CommandSpec(title: 'Install $name ${v.version}', executable: npm, arguments: ['install', '--global', '$package@${v.version}']),
      ],
    );
  }

  @override
  List<EnvChange> env(String dest, String root) => const [];
}

/// Versions of an npm package, newest first; prereleases marked.
Future<List<MarketVersion>> npmVersions(String package) async {
  final j = await _json('https://registry.npmjs.org/${package.replaceAll('/', '%2F')}', headers: {'Accept': 'application/vnd.npm.install-v1+json'}) as Map;
  final versions = (j['versions'] as Map).keys.cast<String>().toList();
  final latest = (j['dist-tags'] as Map?)?['latest'] as String?;
  int cmp(String a, String b) {
    List<int> nums(String v) => v.split(RegExp(r'[.-]')).take(3).map((x) => int.tryParse(x) ?? 0).toList();
    final x = nums(a), y = nums(b);
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return a.contains('-') == b.contains('-') ? b.compareTo(a) : (a.contains('-') ? -1 : 1);
  }

  versions.sort((a, b) => cmp(b, a));
  return [for (final v in versions) MarketVersion(v, stable: !v.contains('-'), channel: v == latest ? 'latest' : (v.contains('-') ? 'preview' : null))];
}

/// Every tool in the marketplace, in display order.
List<MarketTool> buildCatalog({required String Function() androidSdkRoot}) {
  TechInfo fw(String id, String name, int color, String mono, String logo, [LogoTint tint = LogoTint.none]) =>
      _look(id, name, color, mono, logo: 'assets/tech/$logo.svg', tint: tint, kind: TechKind.framework);
  return [
    FlutterMarket(),
    AndroidToolsMarket(androidSdkRoot),
    NodeMarket(),
    PythonMarket(),
    JavaMarket(),
    DotnetMarket(),
    GoMarket(),
    RustMarket(),
    denoMarket(),
    bunMarket(),
    GradleMarket(),
    NpmCliMarket(
      id: 'angular-cli',
      name: 'Angular CLI',
      description: 'Create, serve and build Angular apps (ng).',
      package: '@angular/cli',
      homepage: 'https://angular.dev',
      look: fw('angular-cli', 'Angular CLI', 0xFFDD0031, 'Ng', 'angular'),
    ),
    NpmCliMarket(
      id: 'eas-cli',
      name: 'Expo (EAS CLI)',
      description: 'Build, submit and update React Native apps with Expo.',
      package: 'eas-cli',
      homepage: 'https://expo.dev',
      look: fw('eas-cli', 'Expo', 0xFF000000, 'Ex', 'expo', LogoTint.foreground),
    ),
    NpmCliMarket(
      id: 'nest-cli',
      name: 'NestJS CLI',
      description: 'Scaffold and run NestJS server apps (nest).',
      package: '@nestjs/cli',
      homepage: 'https://nestjs.com',
      look: fw('nest-cli', 'NestJS', 0xFFE0234E, 'Ns', 'nestjs'),
    ),
    NpmCliMarket(
      id: 'firebase-tools',
      name: 'Firebase CLI',
      description: 'Deploy and emulate Firebase projects (firebase).',
      package: 'firebase-tools',
      homepage: 'https://firebase.google.com',
      look: fw('firebase-tools', 'Firebase', 0xFFFFCA28, 'Fb', 'firebase', LogoTint.brand),
    ),
    NpmCliMarket(
      id: 'vercel',
      name: 'Vercel CLI',
      description: 'Deploy web apps to Vercel (vercel).',
      package: 'vercel',
      homepage: 'https://vercel.com',
      look: fw('vercel', 'Vercel', 0xFF000000, 'Vc', 'vercel', LogoTint.foreground),
    ),
    NpmCliMarket(
      id: 'ionic-cli',
      name: 'Ionic CLI',
      description: 'Create and run Ionic apps (ionic).',
      package: '@ionic/cli',
      homepage: 'https://ionicframework.com',
      look: fw('ionic-cli', 'Ionic', 0xFF3880FF, 'Io', 'ionic'),
    ),
    NpmCliMarket(
      id: 'nx',
      name: 'Nx',
      description: 'Build system and monorepo tools (nx).',
      package: 'nx',
      homepage: 'https://nx.dev',
      look: fw('nx', 'Nx', 0xFF143055, 'Nx', 'nx', LogoTint.foreground),
    ),
    NpmCliMarket(
      id: 'typescript',
      name: 'TypeScript',
      description: 'The TypeScript compiler, available everywhere (tsc).',
      package: 'typescript',
      homepage: 'https://www.typescriptlang.org',
      look: fw('typescript-cli', 'TypeScript', 0xFF3178C6, 'TS', 'typescript'),
    ),
    NpmCliMarket(
      id: 'pnpm',
      name: 'pnpm',
      description: 'A fast, disk-saving package manager for JavaScript.',
      package: 'pnpm',
      homepage: 'https://pnpm.io',
      look: fw('pnpm', 'pnpm', 0xFFF69220, 'pn', 'pnpm'),
      category: MarketCategory.packages,
    ),
    NpmCliMarket(
      id: 'yarn',
      name: 'Yarn',
      description: 'The Yarn package manager (classic 1.x line).',
      package: 'yarn',
      homepage: 'https://classic.yarnpkg.com',
      look: fw('yarn', 'Yarn', 0xFF2C8EBB, 'Yn', 'yarn', LogoTint.brand),
      category: MarketCategory.packages,
    ),
  ];
}
