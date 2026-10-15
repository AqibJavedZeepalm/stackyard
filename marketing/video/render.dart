// Renders ad.html frame by frame through headless Chrome (DevTools protocol).
// Each frame calls window.render(t), so the output is exact at any fps.
//
//   dart run render.dart --out <dir> [--fps 60] [--from 0] [--to 30]
//   dart run render.dart --out <dir> --stills 1.5,4.6,12     (PNG previews)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length - 1; i += 2) {
    args[argv[i].replaceFirst('--', '')] = argv[i + 1];
  }
  final out = Directory(args['out'] ?? 'frames')..createSync(recursive: true);
  final fps = int.parse(args['fps'] ?? '60');
  final from = double.parse(args['from'] ?? '0');
  final to = double.parse(args['to'] ?? '30');
  final stills = args['stills']?.split(',').map(double.parse).toList();
  final page = File.fromUri(Platform.script.resolve('ad.html')).absolute.path;

  final chromePath = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].firstWhere((p) => File(p).existsSync());
  final profile = Directory.systemTemp.createTempSync('stackyard-render-');
  const port = 9333;
  final chrome = await Process.start(chromePath, [
    '--headless=new',
    '--remote-debugging-port=$port',
    '--window-size=1920,1080',
    '--force-device-scale-factor=1',
    '--hide-scrollbars',
    '--no-first-run',
    '--no-default-browser-check',
    '--allow-file-access-from-files',
    '--user-data-dir=${profile.path}',
    'about:blank',
  ]);
  chrome.stdout.drain<void>();
  chrome.stderr.drain<void>();

  try {
    // Find the page target.
    String? wsUrl;
    for (var i = 0; i < 100 && wsUrl == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      try {
        final req = await HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
        final res = await req.close();
        final list = jsonDecode(await res.transform(utf8.decoder).join()) as List;
        wsUrl = list.firstWhere((t) => t['type'] == 'page')['webSocketDebuggerUrl'] as String;
      } catch (_) {}
    }
    if (wsUrl == null) throw 'Chrome did not start';
    final cdp = await Cdp.connect(wsUrl);

    await cdp.send('Emulation.setDeviceMetricsOverride', {'width': 1920, 'height': 1080, 'deviceScaleFactor': 1, 'mobile': false});
    await cdp.send('Page.enable');
    final loaded = cdp.once('Page.loadEventFired');
    await cdp.send('Page.navigate', {'url': '${Uri.file(page)}?render'});
    await loaded;
    await cdp.send('Runtime.evaluate', {'expression': 'window.ready', 'awaitPromise': true});

    Future<List<int>> frame(double t, {bool png = false}) async {
      await cdp.send('Runtime.evaluate', {'expression': 'render($t)'});
      final shot = await cdp.send('Page.captureScreenshot', {
        'format': png ? 'png' : 'jpeg',
        if (!png) 'quality': 95,
        'optimizeForSpeed': !png,
      });
      return base64Decode(shot['data'] as String);
    }

    if (stills != null) {
      for (final t in stills) {
        final f = File('${out.path}/still-${t.toStringAsFixed(2)}.png');
        await f.writeAsBytes(await frame(t, png: true));
        stdout.writeln('still $t -> ${f.path}');
      }
    } else {
      final total = ((to - from) * fps).round();
      final sw = Stopwatch()..start();
      for (var i = 0; i < total; i++) {
        final t = from + i / fps;
        await File('${out.path}/f${i.toString().padLeft(5, '0')}.jpg').writeAsBytes(await frame(t));
        if (i % 60 == 0) stdout.writeln('frame $i/$total  ${(sw.elapsedMilliseconds / (i + 1)).toStringAsFixed(0)} ms/frame');
      }
      stdout.writeln('done: $total frames in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
    }
    await cdp.close();
  } finally {
    chrome.kill();
    await chrome.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => 0);
    try {
      profile.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Minimal Chrome DevTools Protocol client.
class Cdp {
  Cdp._(this._ws) {
    _ws.listen((raw) {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final id = msg['id'];
      if (id != null) {
        final c = _pending.remove(id);
        if (msg['error'] != null) {
          c?.completeError(msg['error'].toString());
        } else {
          c?.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? {});
        }
      } else if (msg['method'] != null) {
        _events.remove(msg['method'])?.complete();
      }
    });
  }

  static Future<Cdp> connect(String url) async => Cdp._(await WebSocket.connect(url));

  final WebSocket _ws;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = <String, Completer<void>>{};
  var _id = 0;

  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(jsonEncode({'id': id, 'method': method, 'params': ?params}));
    return c.future;
  }

  Future<void> once(String event) => (_events[event] = Completer<void>()).future;

  Future<void> close() => _ws.close();
}
