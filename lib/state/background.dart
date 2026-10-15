import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'notify.dart';

/// What a background check would tell you: null when there's nothing new.
/// [key] identifies the news so the same thing isn't announced twice.
({String key, String title, String body})? backgroundAlert(AppState state) {
  final updates = [for (final t in state.techs.where((t) => t.updateAvailable)) '${t.info.name} ${t.snapshot.latest}'];
  final problems = state.notes.length + state.systemIssues.length;
  final idleBytes = state.cleanups.where((c) => c.isIdle).fold<int>(0, (s, c) => s + c.bytes);
  final free = state.reclaimableBytes + idleBytes;
  const gb = 1024 * 1024 * 1024;
  final parts = [
    if (updates.isNotEmpty) updates.length == 1 ? '${updates.single} is available' : '${updates.length} updates are available',
    if (problems > 0) '$problems problem${problems == 1 ? '' : 's'} need${problems == 1 ? 's' : ''} attention',
    if (free >= gb) '${formatGb(free)} can be freed',
  ];
  if (parts.isEmpty) return null;
  final body = '${parts.first[0].toUpperCase()}${parts.join(' · ').substring(1)}.';
  // Whole gigabytes only: a few MB more shouldn't count as news.
  return (key: '${updates.join(',')}|$problems|${free ~/ gb}', title: 'Stackyard', body: body);
}

String formatGb(int bytes) => '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';

/// Keeps Stackyard in the tray (Windows) or menu bar (macOS) when its window is
/// closed, checks the machine now and then, and notifies when there's news.
class Background with TrayListener, WindowListener {
  Background(this.state, {required this.onShow});
  final AppState state;

  /// Called after the window is shown again (to re-apply Mica on Windows).
  final Future<void> Function() onShow;

  Timer? _timer;
  bool _quitting = false;
  DateTime? _lastScan;

  bool get _tray => Platform.isWindows || Platform.isMacOS;
  String get _trayName => Platform.isMacOS ? 'menu bar' : 'system tray';

  Future<void> start() async {
    if (!_tray) return;
    await Notify.setup(show);
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray/tray.ico' : 'assets/tray/tray_template.png', isTemplate: Platform.isMacOS);
    if (Platform.isWindows) await trayManager.setToolTip('Stackyard');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: 'Open Stackyard'),
          MenuItem(key: 'check', label: 'Check now'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit Stackyard'),
        ],
      ),
    );
    state.addListener(_onState);
    // Every half hour, see whether a scheduled check is due.
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => _checkIfDue());
  }

  /// A finished scan counts as a check; while hidden, it may be worth a notification.
  void _onState() {
    final scan = state.lastScan;
    if (scan == null || scan == _lastScan || state.phase != ScanPhase.idle) return;
    _lastScan = scan;
    state.settings.update((s) => s.lastCheckAt = scan.millisecondsSinceEpoch);
    windowManager.isVisible().then((visible) {
      if (!visible) _notify();
    });
  }

  Future<void> _checkIfDue() async {
    final every = state.settings.checkInterval;
    if (every == null || state.scanning || state.measuring) return;
    final last = DateTime.fromMillisecondsSinceEpoch(state.settings.lastCheckAt);
    if (DateTime.now().difference(last) < every) return;
    await state.scan(quiet: true);
  }

  void _notify() {
    final alert = backgroundAlert(state);
    if (alert == null || alert.key == state.settings.lastAlert) return;
    state.settings.update((s) => s.lastAlert = alert.key);
    Notify.show(alert.title, alert.body);
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
    await onShow();
  }

  Future<void> quit() async {
    _quitting = true;
    _timer?.cancel();
    state.removeListener(_onState);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ---- Window ----

  @override
  void onWindowClose() async {
    if (_quitting || !state.settings.runInBackground) {
      await quit();
      return;
    }
    await windowManager.hide();
    if (!state.settings.trayTipShown) {
      state.settings.update((s) => s.trayTipShown = true);
      Notify.show('Stackyard is still running', 'It checks your setup now and then. Open or quit it from its icon in the $_trayName.');
    }
  }

  // ---- Tray ----

  @override
  void onTrayIconMouseDown() {
    // Windows: click opens the window. macOS: the menu, like other menu bar apps.
    if (Platform.isMacOS) {
      trayManager.popUpContextMenu();
    } else {
      show();
    }
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        show();
      case 'check':
        state.scan();
      case 'quit':
        // Let the menu close before tearing the tray down.
        Timer.run(quit);
    }
  }
}
