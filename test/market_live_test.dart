// Checks the marketplace against the real publishers: every tool lists its
// versions, and the newest stable version of each downloadable tool installs
// into a temp folder (hash checked, unpacked) and runs. Environment variables
// are never touched.
// Run with: flutter test test/market_live_test.dart --dart-define=LIVE=true
// ignore_for_file: avoid_print
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:stackyard/core/market/catalog.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/state/jobs.dart';

const live = bool.fromEnvironment('LIVE');

/// Tools installed for real. Flutter is left out by default (over 1 GB); add it with --dart-define=INSTALL=flutter,…
const installIds = String.fromEnvironment('INSTALL', defaultValue: 'node,go,deno,bun,java,gradle,android-cmdline-tools,python,dotnet,rust');

Future<Job> runJob(PlannedChange change) async {
  final queue = JobQueue(onJobFinished: (_) {});
  final job = queue.enqueue(change);
  while (job.status == JobStatus.queued || job.status == JobStatus.running) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return job;
}

/// Asks for the first byte only, so big downloads aren't fetched.
Future<int> probe(String url) async {
  final req = http.Request('GET', Uri.parse(url))..headers.addAll({'User-Agent': 'Stackyard', 'Range': 'bytes=0-0'});
  final res = await http.Client().send(req).timeout(const Duration(seconds: 30));
  await res.stream.drain<void>();
  return res.statusCode;
}

MarketVersion pick(String id, List<MarketVersion> versions) {
  final stable = versions.where((v) => v.stable).toList();
  if (id == 'node' || id == 'java' || id == 'dotnet') return stable.firstWhere((v) => v.lts, orElse: () => stable.first);
  return stable.first;
}

void main() {
  final root = Directory(p.join(Directory.systemTemp.path, 'sy-live'));
  final sdk = p.join(root.path, 'android-sdk');
  final catalog = buildCatalog(androidSdkRoot: () => sdk);
  final picked = <String, MarketVersion>{};
  final dests = <String, String>{};

  setUpAll(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
  });

  test('every tool lists versions, and its download and checksum answer', () async {
    final failures = <String>[];
    for (final tool in catalog) {
      try {
        final versions = await tool.versions();
        if (versions.isEmpty) throw 'no versions';
        final v = pick(tool.id, versions);
        picked[tool.id] = v;
        final dest = tool is AndroidToolsMarket ? tool.destFor(v) : p.join(root.path, tool.id, v.version);
        dests[tool.id] = dest;
        final plan = await tool.plan(v, dest);
        if (plan == null) throw 'no plan for ${v.version}';
        final d = plan.download;
        var line = '${tool.id.padRight(22)} ${versions.length.toString().padLeft(4)} versions, picked ${v.version}';
        if (d != null) {
          final code = await probe(d.url);
          if (code != 200 && code != 206) throw '${d.url} answered $code';
          final hash = d.sha256 != null ? 'sha256' : d.sha512 != null ? 'sha512' : d.sha1 != null ? 'sha1' : null;
          if (d.checksumUrl != null) {
            final c = await probe(d.checksumUrl!);
            if (c != 200 && c != 206) throw '${d.checksumUrl} answered $c';
          }
          line += ', download ok, checked by ${hash ?? (d.checksumUrl != null ? 'checksum file' : 'NOTHING')}';
          if (hash == null && d.checksumUrl == null) failures.add('${tool.id}: download has no hash');
        } else {
          line += ', via ${plan.commands.map((c) => p.basename(c.executable)).join(', ')}';
        }
        print(line);
      } catch (e) {
        print('${tool.id.padRight(22)} FAILED: $e');
        failures.add('${tool.id}: $e');
      }
    }
    expect(failures, isEmpty);
  }, skip: !live, timeout: const Timeout(Duration(minutes: 5)));

  // What each tool's program is, inside its folder, and how to ask its version.
  final probes = <String, (String, List<String>)>{
    'node': ('node.exe', ['--version']),
    'go': (p.join('bin', 'go.exe'), ['version']),
    'deno': ('deno.exe', ['--version']),
    'bun': ('bun.exe', ['--version']),
    'java': (p.join('bin', 'java.exe'), ['-version']),
    'gradle': (p.join('bin', 'gradle.bat'), ['--version']),
    'android-cmdline-tools': (p.join('bin', 'sdkmanager.bat'), ['--version']),
    'python': ('python.exe', ['--version']),
    'dotnet': ('dotnet.exe', ['--version']),
    'rust': (p.join('cargo', 'bin', 'cargo.exe'), ['--version']),
    'flutter': (p.join('bin', 'flutter.bat'), ['--version']),
  };

  for (final id in installIds.split(',')) {
    test('installs $id for real, runs it, then deletes it', () async {
      final tool = catalog.firstWhere((t) => t.id == id);
      final v = picked[id] ?? pick(id, await tool.versions());
      final dest = dests[id] ?? (tool is AndroidToolsMarket ? tool.destFor(v) : p.join(root.path, id, v.version));
      final plan = (await tool.plan(v, dest))!;
      final sw = Stopwatch()..start();
      final job = await runJob(PlannedChange(title: 'Install $id ${v.version}', downloads: [?plan.download], commands: plan.commands));
      if (job.status != JobStatus.done) print(job.log.join('\n'));
      expect(job.status, JobStatus.done, reason: job.error);

      // Gradle and sdkmanager need a JDK: use the one installed above, if any.
      final env = <String, String>{
        if (dests['java'] != null && Directory(dests['java']!).existsSync()) 'JAVA_HOME': dests['java']!,
        if (id == 'rust') ...{'RUSTUP_HOME': p.join(dest, 'rustup'), 'CARGO_HOME': p.join(dest, 'cargo')},
      };
      final (exe, args) = probes[id]!;
      final r = await Process.run(p.join(dest, exe), args, environment: env, runInShell: exe.endsWith('.bat'));
      final out = '${r.stdout}${r.stderr}'.trim().split('\n').first.trim();
      print('$id ${v.version}: installed in ${sw.elapsed.inSeconds}s, ${p.join(dest, exe)} says "$out"');
      expect(r.exitCode, 0, reason: out);

      if (id != 'java') {
        final rm = await runJob(PlannedChange(title: 'Remove $id', recycle: [dest], permanent: true));
        expect(rm.status, JobStatus.done, reason: rm.error);
        expect(Directory(dest).existsSync(), isFalse);
      }
    }, skip: !live, timeout: const Timeout(Duration(minutes: 20)));
  }

  tearDownAll(() async {
    if (!live) return;
    final rm = await runJob(PlannedChange(title: 'Clean up', recycle: [root.path], permanent: true));
    print('cleanup: ${rm.status.name}');
  });
}
