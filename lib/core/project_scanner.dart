import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'models.dart';

/// npm packages we surface as "frameworks".
const watchedPackages = [
  'react',
  'react-dom',
  'react-native',
  'expo',
  'next',
  'vue',
  'nuxt',
  '@angular/core',
  'svelte',
  'astro',
  'electron',
  'vite',
  'typescript',
];

const _skipDirs = {
  'node_modules',
  '.git',
  'build',
  '.dart_tool',
  'pods',
  '.gradle',
  '.idea',
  '.vscode',
  'dist',
  'out',
  'target',
  'venv',
  '.venv',
  'env',
  '__pycache__',
  '.next',
  '.nuxt',
  '.expo',
  'deriveddata',
  'bin',
  'obj',
  r'$recycle.bin',
  'system volume information',
  'windows',
  'program files',
  'program files (x86)',
  'programdata',
  'appdata',
  '.cache',
  'vendor',
  'ephemeral',
  '.symlinks',
  '.pub-cache',
  'fvm',
  '.fvm',
  'library',
  'steamlibrary',
  'site-packages',
  '.android',
  '.npm',
  '.nvm',
  'coverage',
};

/// Folders inside a project that commonly hold more projects (monorepos).
const _monorepoDirs = {'packages', 'apps', 'libs', 'modules', 'services'};

class ProjectScanner {
  /// Walks [roots] off the UI isolate and returns every project found.
  static Future<List<Project>> scan(List<String> roots, {int maxDepth = 5}) => Isolate.run(() => scanSync(roots, maxDepth: maxDepth));

  static List<Project> scanSync(List<String> roots, {int maxDepth = 5}) {
    final found = <String, Project>{};
    for (final root in roots) {
      if (Directory(root).existsSync()) _walk(Directory(root), 0, maxDepth, found);
    }
    final list = found.values.toList()..sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return list;
  }

  static void _walk(Directory dir, int depth, int maxDepth, Map<String, Project> found) {
    if (depth > maxDepth) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    final names = {for (final e in entries) p.basename(e.path).toLowerCase()};

    final project = _detect(dir.path, names);
    if (project != null) {
      found[p.normalize(project.path).toLowerCase()] = project;
      for (final e in entries) {
        if (e is Directory && _monorepoDirs.contains(p.basename(e.path).toLowerCase())) {
          _walk(e, depth + 1, maxDepth, found);
        }
      }
      return;
    }

    for (final e in entries) {
      if (e is! Directory) continue;
      final name = p.basename(e.path).toLowerCase();
      if (_skipDirs.contains(name) || name.startsWith('.')) continue;
      _walk(e, depth + 1, maxDepth, found);
    }
  }

  static Project? _detect(String path, Set<String> names) {
    final isPub = names.contains('pubspec.yaml');
    final isNode = names.contains('package.json');
    final isGradle = names.contains('settings.gradle') || names.contains('settings.gradle.kts');
    final isPython = names.contains('pyproject.toml') || names.contains('requirements.txt') || names.contains('.python-version');
    final isDotnet = names.contains('global.json') || names.any((n) => n.endsWith('.sln') || n.endsWith('.csproj'));
    final isJava = names.contains('pom.xml') || names.contains('.java-version');
    if (!(isPub || isNode || isGradle || isPython || isDotnet || isJava)) return null;

    final project = Project(path: path, name: p.basename(path), lastModified: _activity(path, names));

    if (isPub) _parseDart(project);
    if (isNode) _parseNode(project, names);
    if (isPython) _parsePython(project);
    if (isDotnet) _parseDotnet(project);
    if (isJava) _parseJava(project);

    // Android lives in ./android for Flutter and React Native apps.
    final androidRoot = isGradle ? path : p.join(path, 'android');
    if (File(p.join(androidRoot, 'settings.gradle')).existsSync() || File(p.join(androidRoot, 'settings.gradle.kts')).existsSync()) {
      _parseAndroid(project, androidRoot);
    }
    if (Directory(p.join(path, 'ios')).existsSync()) project.types.add('ios');
    return project;
  }

  /// Best guess at when the project was last worked on.
  static DateTime _activity(String path, Set<String> names) {
    DateTime best = DateTime.fromMillisecondsSinceEpoch(0);
    void consider(String rel) {
      try {
        final s = FileStat.statSync(p.join(path, rel));
        if (s.type != FileSystemEntityType.notFound && s.modified.isAfter(best)) {
          best = s.modified;
        }
      } catch (_) {}
    }

    for (final rel in [
      '.',
      '.git/index',
      '.git/HEAD',
      'pubspec.lock',
      'pubspec.yaml',
      'package.json',
      'package-lock.json',
      'yarn.lock',
      'pnpm-lock.yaml',
      'lib',
      'src',
      'app',
      '.dart_tool',
      'node_modules/.package-lock.json',
    ]) {
      consider(rel);
    }
    return best;
  }

  static String? _read(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _json(String path) {
    final t = _read(path);
    if (t == null) return null;
    try {
      final v = jsonDecode(t);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static void _parseDart(Project project) {
    final pubspec = _read(p.join(project.path, 'pubspec.yaml')) ?? '';
    final isFlutter = RegExp(r'^\s+sdk:\s*flutter\s*$', multiLine: true).hasMatch(pubspec);
    project.types.add(isFlutter ? 'flutter' : 'dart');

    final fvmrc = _json(p.join(project.path, '.fvmrc'));
    final legacy = _json(p.join(project.path, '.fvm', 'fvm_config.json'));
    final pinned = fvmrc?['flutter'] ?? legacy?['flutterSdkVersion'];
    if (pinned is String && pinned.isNotEmpty) {
      project.pins['flutter'] = Pin(raw: pinned, source: fvmrc != null ? '.fvmrc' : '.fvm/fvm_config.json');
    }
  }

  static void _parseNode(Project project, Set<String> names) {
    project.types.add('node');
    final pkg = _json(p.join(project.path, 'package.json')) ?? {};

    project.packageManager = names.contains('pnpm-lock.yaml')
        ? 'pnpm'
        : names.contains('yarn.lock')
        ? 'yarn'
        : (names.contains('bun.lockb') || names.contains('bun.lock'))
        ? 'bun'
        : 'npm';

    final nvmrc = _read(p.join(project.path, '.nvmrc'))?.trim();
    final nodeVersion = _read(p.join(project.path, '.node-version'))?.trim();
    final volta = (pkg['volta'] is Map) ? pkg['volta']['node'] : null;
    final engines = (pkg['engines'] is Map) ? pkg['engines']['node'] : null;
    if (nvmrc != null && nvmrc.isNotEmpty) {
      project.pins['node'] = Pin(raw: nvmrc.split('\n').first.trim(), source: '.nvmrc');
    } else if (nodeVersion != null && nodeVersion.isNotEmpty) {
      project.pins['node'] = Pin(raw: nodeVersion, source: '.node-version');
    } else if (volta is String) {
      project.pins['node'] = Pin(raw: volta, source: 'package.json (volta)');
    } else if (engines is String) {
      project.pins['node'] = Pin(raw: engines, source: 'package.json (engines)', exact: false);
    }

    final all = <String, dynamic>{if (pkg['devDependencies'] is Map) ...pkg['devDependencies'], if (pkg['dependencies'] is Map) ...pkg['dependencies']};
    for (final name in watchedPackages) {
      final declared = all[name];
      if (declared is! String) continue;
      final installedPkg = _json(p.join(project.path, 'node_modules', name, 'package.json'));
      project.deps[name] = DepVersion(declared: declared, installed: installedPkg?['version'] as String?);
    }
  }

  static void _parseAndroid(Project project, String androidRoot) {
    project.types.add('android');
    final wrapper = _read(p.join(androidRoot, 'gradle', 'wrapper', 'gradle-wrapper.properties'));
    final url = wrapper == null ? null : RegExp(r'distributionUrl=.*/(gradle-[^/]+?)\.zip').firstMatch(wrapper)?[1];
    if (url != null) project.buildInfo['gradle'] = url;

    final local = _read(p.join(androidRoot, 'local.properties'));
    final sdkDir = local == null ? null : RegExp(r'^sdk\.dir=(.+)$', multiLine: true).firstMatch(local)?[1];
    if (sdkDir != null) {
      // Java properties escape backslashes and colons.
      project.buildInfo['sdkDir'] = sdkDir.trim().replaceAll(r'\\', '\\').replaceAll(r'\:', ':');
    }

    final app = _read(p.join(androidRoot, 'app', 'build.gradle.kts')) ?? _read(p.join(androidRoot, 'app', 'build.gradle')) ?? '';
    final compile = RegExp(r'compileSdk(?:Version)?\s*(?:=\s*)?(flutter\.compileSdkVersion|\d+)').firstMatch(app)?[1];
    if (compile != null) {
      project.buildInfo['compileSdk'] = compile.startsWith('flutter') ? 'flutter' : compile;
    }
    final ndk = RegExp(r'''ndkVersion\s*(?:=\s*)?(flutter\.ndkVersion|["'][^"']+["'])''').firstMatch(app)?[1];
    if (ndk != null) {
      project.buildInfo['ndk'] = ndk.startsWith('flutter') ? 'flutter' : ndk.replaceAll(RegExp(r'''["']'''), '');
    }
    final buildTools = RegExp(r'''buildToolsVersion\s*(?:=\s*)?["']([^"']+)["']''').firstMatch(app)?[1];
    if (buildTools != null) project.buildInfo['buildTools'] = buildTools;
  }

  static void _parsePython(Project project) {
    project.types.add('python');
    final pv = _read(p.join(project.path, '.python-version'))?.trim();
    if (pv != null && pv.isNotEmpty) {
      project.pins['python'] = Pin(raw: pv.split('\n').first.trim(), source: '.python-version');
      return;
    }
    final pyproject = _read(p.join(project.path, 'pyproject.toml'));
    final req = pyproject == null ? null : RegExp(r'''requires-python\s*=\s*["']([^"']+)["']''').firstMatch(pyproject)?[1];
    if (req != null) {
      project.pins['python'] = Pin(raw: req, source: 'pyproject.toml', exact: false);
    }
  }

  static void _parseDotnet(Project project) {
    project.types.add('dotnet');
    final global = _json(p.join(project.path, 'global.json'));
    final v = (global?['sdk'] is Map) ? global!['sdk']['version'] : null;
    if (v is String) project.pins['dotnet'] = Pin(raw: v, source: 'global.json');
  }

  static void _parseJava(Project project) {
    project.types.add('java');
    final jv = _read(p.join(project.path, '.java-version'))?.trim();
    if (jv != null && jv.isNotEmpty) {
      project.pins['java'] = Pin(raw: jv, source: '.java-version');
    }
  }
}
