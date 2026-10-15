import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/env_writer.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/state/jobs.dart';

/// Serves one file over local HTTP, like a vendor's download server.
Future<(HttpServer, String)> serve(File file) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.headers.contentLength = file.lengthSync();
    await req.response.addStream(file.openRead());
    await req.response.close();
  });
  return (server, 'http://127.0.0.1:${server.port}/${p.basename(file.path)}');
}

Future<Job> runJob(PlannedChange change) async {
  final queue = JobQueue(onJobFinished: (_) {});
  final job = queue.enqueue(change);
  while (job.status == JobStatus.queued || job.status == JobStatus.running) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return job;
}

void main() {
  late Directory tmp;
  late File archive;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('stackyard-market-');
    // An archive shaped like a real SDK: one top folder (tool-1.0/) with files inside.
    final src = Directory(p.join(tmp.path, 'src', 'tool-1.0', 'bin'))..createSync(recursive: true);
    File(p.join(src.path, 'tool.txt')).writeAsStringSync('hello');
    archive = File(p.join(tmp.path, 'tool-1.0.tar.gz'));
    final r = await Process.run('tar', ['-czf', archive.path, '-C', p.join(tmp.path, 'src'), 'tool-1.0']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a download is checked against its hash, unpacked, and its top folder flattened', () async {
    final (server, url) = await serve(archive);
    addTearDown(server.close);
    final sha = await Sys.hashFile(archive.path, 'sha256');
    final dest = p.join(tmp.path, 'sdks', 'tool', '1.0');
    final job = await runJob(
      PlannedChange(
        title: 'Install tool 1.0',
        downloads: [DownloadStep(url: url, sha256: sha, label: 'tool', extractTo: dest)],
      ),
    );
    expect(job.status, JobStatus.done, reason: job.error);
    expect(File(p.join(dest, 'bin', 'tool.txt')).readAsStringSync(), 'hello');
    expect(Directory('$dest.partial').existsSync(), isFalse);
    expect(job.log.any((l) => l.contains('SHA256 verified')), isTrue);
  });

  test('a download that doesn\'t match its hash is never installed', () async {
    final (server, url) = await serve(archive);
    addTearDown(server.close);
    final dest = p.join(tmp.path, 'sdks', 'tool', '1.0');
    final job = await runJob(
      PlannedChange(
        title: 'Install tool',
        downloads: [DownloadStep(url: url, sha256: 'ab' * 32, label: 'tool', extractTo: dest)],
      ),
    );
    expect(job.status, JobStatus.failed);
    expect(job.error, contains('doesn\'t match'));
    expect(Directory(dest).existsSync(), isFalse);
  });

  test('a checksum file listing several files picks the right line', () async {
    final (server, url) = await serve(archive);
    addTearDown(server.close);
    final sha = await Sys.hashFile(archive.path, 'sha256');
    final sums = File(p.join(tmp.path, 'SHASUMS256.txt'))..writeAsStringSync('${'cd' * 32}  other.zip\n$sha  tool-1.0.tar.gz\n');
    final (sumServer, sumUrl) = await serve(sums);
    addTearDown(sumServer.close);
    final dest = p.join(tmp.path, 'sdks', 'tool', '1.0');
    final job = await runJob(
      PlannedChange(
        title: 'Install tool',
        downloads: [DownloadStep(url: url, checksumUrl: sumUrl, label: 'tool', extractTo: dest)],
      ),
    );
    expect(job.status, JobStatus.done, reason: job.error);
  });

  test('Windows: env changes set variables, swap PATH entries, keep PATH\'s type', () async {
    const key = r'HKCU\Software\StackyardEnvTest';
    await Process.run('reg.exe', ['add', key, '/v', 'Path', '/t', 'REG_EXPAND_SZ', '/d', r'%SystemRoot%;C:\sdks\java\17\bin;C:\other', '/f']);
    addTearDown(() => Process.run('reg.exe', ['delete', key, '/f']));
    Future<String> query(String name) async => '${(await Process.run('reg.exe', ['query', key, '/v', name])).stdout}';

    // Install JDK 21: JAVA_HOME set, its bin first on PATH, JDK 17's entry gone.
    var cmd = EnvWriter.windowsCommand(const [
      EnvChange.set('JAVA_HOME', r'C:\sdks\java\21'),
      EnvChange.prependPath(r'C:\sdks\java\21\bin', replacePrefix: r'C:\sdks\java'),
    ], keyOverride: r'HKCU:\Software\StackyardEnvTest');
    var r = await Process.run(cmd.executable, cmd.arguments);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(await query('JAVA_HOME'), contains(r'C:\sdks\java\21'));
    final path = await query('Path');
    expect(path, contains('REG_EXPAND_SZ'));
    expect(RegExp(r'REG_EXPAND_SZ\s+(.*)').firstMatch(path)![1]!.trim(), r'C:\sdks\java\21\bin;%SystemRoot%;C:\other');

    // Remove it again: PATH entry and JAVA_HOME go, everything else stays.
    cmd = EnvWriter.windowsCommand(const [
      EnvChange.dropPathUnder(r'C:\sdks\java\21'),
      EnvChange.removeIfUnder('JAVA_HOME', r'C:\sdks\java\21'),
    ], keyOverride: r'HKCU:\Software\StackyardEnvTest');
    r = await Process.run(cmd.executable, cmd.arguments);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(await query('JAVA_HOME'), isNot(contains('JAVA_HOME')));
    expect(RegExp(r'REG_EXPAND_SZ\s+(.*)').firstMatch(await query('Path'))![1]!.trim(), r'%SystemRoot%;C:\other');
  }, skip: !Platform.isWindows);

  test('macOS: one marked block per tool in the shell profile, replaced and removed cleanly', () async {
    final home = Directory(p.join(tmp.path, 'home'))..createSync();
    File(p.join(home.path, '.zprofile')).writeAsStringSync('export EDITOR=vim\n');
    // A stand-in for launchd's environment, so the test never changes the real one.
    final launchd = <String, String>{};
    Future<String> launchctl(List<String> a) async => switch (a[0]) {
      'setenv' => (launchd[a[1]] = a[2]),
      'unsetenv' => (launchd.remove(a[1]) ?? ''),
      _ => launchd[a[1]] ?? '',
    };
    await EnvWriter.applyUnix(
      const [EnvChange.set('JAVA_HOME', '/u/sdks/java/17'), EnvChange.prependPath('/u/sdks/java/17/bin')],
      block: 'java',
      home: home.path,
      launchctl: launchctl,
    );
    await EnvWriter.applyUnix(
      const [EnvChange.set('JAVA_HOME', '/u/sdks/java/21'), EnvChange.prependPath('/u/sdks/java/21/bin')],
      block: 'java',
      home: home.path,
      launchctl: launchctl,
    );
    var text = File(p.join(home.path, '.zprofile')).readAsStringSync();
    expect(text, startsWith('export EDITOR=vim\n'));
    expect('# >>> stackyard:java >>>'.allMatches(text).length, 1);
    expect(text, contains('export JAVA_HOME="/u/sdks/java/21"'));
    expect(text, isNot(contains('java/17')));

    // Apps started from the Dock: set now (launchctl) and at every login (a LaunchAgent).
    final agent = File(p.join(home.path, 'Library', 'LaunchAgents', 'dev.stackyard.env.plist'));
    expect(agent.readAsStringSync(), contains('launchctl setenv JAVA_HOME "/u/sdks/java/21"'));
    expect(agent.readAsStringSync(), isNot(contains('PATH')));
    expect(launchd['JAVA_HOME'], '/u/sdks/java/21');

    await EnvWriter.applyUnix(
      const [EnvChange.dropPathUnder('/u/sdks/java/21'), EnvChange.removeIfUnder('JAVA_HOME', '/u/sdks/java/21')],
      block: 'java',
      home: home.path,
      launchctl: launchctl,
    );
    text = File(p.join(home.path, '.zprofile')).readAsStringSync();
    expect(text, isNot(contains('stackyard')));
    expect(text, contains('export EDITOR=vim'));
    expect(agent.existsSync(), isFalse, reason: 'no variables left to set at login');
    expect(launchd.containsKey('JAVA_HOME'), isFalse);
  });
}
