import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:provider/provider.dart';
import 'package:system_theme/system_theme.dart';
import 'package:window_manager/window_manager.dart';

import 'core/autostart.dart';
import 'state/app_state.dart';
import 'state/background.dart';
import 'state/settings.dart';
import 'ui/shell.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Started at sign-in: stay in the tray / menu bar until opened.
  runApp(await bootstrap(hidden: args.contains(AutoStart.backgroundFlag), tray: true));
}

/// Sets up the window and app state; integration tests call this too.
/// [tray] keeps Stackyard running in the tray / menu bar when the window closes.
Future<Widget> bootstrap({bool hidden = false, bool tray = false}) async {
  await SystemTheme.accentColor.load();

  await acrylic.Window.initialize();
  await windowManager.ensureInitialized();
  if (Platform.isWindows) await acrylic.Window.hideWindowControls();

  final settings = await Settings.load();
  final state = AppState(settings);
  if (tray) {
    final background = Background(state, onShow: () => applyWindowEffect(settings, force: true));
    try {
      await background.start();
    } catch (e) {
      // No tray (or notifications) available: the app still works, it just quits on close.
      debugPrint('background mode unavailable: $e');
      await windowManager.setPreventClose(false);
    }
  }

  windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size(1180, 780),
      minimumSize: Size(720, 520),
      center: true,
      title: 'Stackyard',
      titleBarStyle: TitleBarStyle.hidden,
      // macOS keeps its own traffic-light buttons; Windows draws Fluent ones in the title bar.
      windowButtonVisibility: Platform.isMacOS,
    ),
    () async {
      if (hidden) return;
      await windowManager.show();
      await windowManager.focus();
      // Mica only sticks once the window is visible.
      await applyWindowEffect(settings, force: true);
    },
  );

  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: state),
      ChangeNotifierProvider.value(value: state.jobs),
    ],
    child: const StackyardApp(),
  );
}

class StackyardApp extends StatefulWidget {
  const StackyardApp({super.key});

  @override
  State<StackyardApp> createState() => _StackyardAppState();
}

class _StackyardAppState extends State<StackyardApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Follow Windows when it switches between light and dark.
  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final accent = SystemTheme.accentColor.accent.toAccentColor();
    final mica = settings.mica && Platform.isWindows;

    WidgetsBinding.instance.addPostFrameCallback((_) => applyWindowEffect(settings));

    FluentThemeData theme(Brightness b) => FluentThemeData(
      brightness: b,
      accentColor: accent,
      visualDensity: VisualDensity.standard,
      focusTheme: const FocusThemeData(glowFactor: 0),
      micaBackgroundColor: mica ? Colors.transparent : null,
      navigationPaneTheme: NavigationPaneThemeData(
        backgroundColor: mica ? Colors.transparent : null,
        // fluent_ui's default (12 + 16 + 12 = 40 px) overflows the 38 px item on the
        // first frame of the pane opening; 2 px less on the end side fits.
        iconPadding: const EdgeInsetsDirectional.only(start: 12, end: 10),
      ),
    );

    return FluentApp(
      title: 'Stackyard',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const Shell(),
    );
  }
}

String? _appliedEffect;

/// Applies Mica (or turns it off) to match the theme; skips repeat calls.
Future<void> applyWindowEffect(Settings settings, {bool force = false}) async {
  if (!Platform.isWindows) return;
  final platformDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  final dark = settings.themeMode == ThemeMode.dark || (settings.themeMode == ThemeMode.system && platformDark);
  final key = '${settings.mica}-$dark';
  if (!force && key == _appliedEffect) return;
  _appliedEffect = key;
  await acrylic.Window.setEffect(
    effect: settings.mica ? acrylic.WindowEffect.mica : acrylic.WindowEffect.solid,
    color: settings.mica ? Colors.transparent : (dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3)),
    dark: dark,
  );
}
