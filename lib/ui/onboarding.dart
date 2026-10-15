import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../core/project_scanner.dart';
import '../core/settings_defaults.dart';
import '../core/sys.dart';
import '../state/settings.dart';
import 'motion.dart';
import 'pages/settings_page.dart';
import 'widgets.dart';

/// First run: finds where your projects live, lets you add more folders, and
/// asks the few preferences that matter. Shown once; Settings changes them later.
class Onboarding extends StatefulWidget {
  const Onboarding({super.key, this.nativeChrome = true});

  /// False in widget tests, where there's no real window to drag.
  final bool nativeChrome;

  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  int _step = 0;

  /// Folders with projects in them, and how many each holds (null while searching).
  List<(String, int)>? _found;
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    // Searching starts right away, so the list is usually ready by step two.
    // A failed search still ends with a list, so "Add folder…" appears.
    findProjectFolders().catchError((_) => <(String, int)>[]).then((found) {
      if (!mounted) return;
      setState(() {
        _found = found;
        _picked.addAll(found.map((f) => f.$1));
      });
    });
  }

  Future<void> _addFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Add folder');
    if (dir == null || _found!.any((f) => f.$1 == dir)) return;
    final count = (await ProjectScanner.scan([dir])).length;
    if (!mounted) return;
    setState(() {
      _found = [..._found!, (dir, count)];
      _picked.add(dir);
    });
  }

  void _finish() {
    final roots = [for (final f in _found ?? const <(String, int)>[]) if (_picked.contains(f.$1)) f.$1];
    context.read<Settings>().update((s) {
      s.roots = roots;
      s.onboarded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final steps = [_welcome, _folders, _preferences];
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          // The title bar is hidden; this strip still moves the window.
          if (widget.nativeChrome) const Positioned(top: 0, left: 0, right: 0, height: 40, child: DragToMoveArea(child: SizedBox.expand())),
          // Windows draws its own minimize / maximize / close buttons (macOS keeps its traffic lights).
          if (widget.nativeChrome && Platform.isWindows)
            Positioned(
              top: 0,
              right: 0,
              width: 138,
              height: 48,
              child: WindowCaption(brightness: theme.brightness, backgroundColor: Colors.transparent),
            ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 56, 32, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: SmoothSwitcher(
                        alignment: Alignment.topCenter,
                        child: KeyedSubtree(key: ValueKey(_step), child: steps[_step](theme)),
                      ),
                    ),
                    const SizedBox(height: 28),
                    _footer(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final last = _step == 2;
    return Row(
      children: [
        // Where you are: three dots, the current one long.
        for (var i = 0; i < 3; i++)
          AnimatedContainer(
            duration: Motion.of(context, Motion.normal),
            curve: Motion.move,
            margin: const EdgeInsets.only(right: 6),
            width: i == _step ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == _step ? FluentTheme.of(context).accentColor : FluentTheme.of(context).resources.controlStrongFillColorDisabled,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const Spacer(),
        if (_step > 0) ...[Button(onPressed: () => setState(() => _step--), child: const Text('Back')), const SizedBox(width: 8)],
        FilledButton(
          onPressed: last ? _finish : () => setState(() => _step++),
          child: Text(switch (_step) {
            0 => 'Get started',
            1 => 'Continue',
            _ => 'Start scanning',
          }),
        ),
      ],
    );
  }

  Widget _welcome(FluentThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Appear(child: StackyardMark(size: 48)),
      const SizedBox(height: 24),
      Appear(index: 1, child: Text('Welcome to Stackyard', style: theme.typography.titleLarge)),
      const SizedBox(height: 12),
      Appear(
        index: 2,
        child: Text(
          'See every SDK, toolchain and framework on this ${Sys.isWindows ? 'PC' : 'Mac'}, which projects use each one, '
          'and what\'s safe to remove. Then fix what\'s wrong with one click.',
          style: theme.typography.bodyLarge,
        ),
      ),
      const SizedBox(height: 16),
      const Appear(index: 3, child: Muted('Everything stays on this computer: no account, no telemetry. Stackyard never changes your projects.')),
    ],
  );

  Widget _folders(FluentThemeData theme) {
    final found = _found;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Where are your projects?', style: theme.typography.title),
        const SizedBox(height: 8),
        const Muted('Stackyard reads these folders to see which projects use which versions. You can change them later in Settings.'),
        const SizedBox(height: 20),
        if (found == null)
          const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: BusyLabel('Looking for projects in your home folder…', muted: true))
        else ...[
          if (found.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 12), child: Muted('No projects found in the usual places. Add the folder where you keep them.')),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (i, (path, count)) in found.indexed)
                  Appear(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SurfaceCard(
                        onPressed: () => setState(() => _picked.contains(path) ? _picked.remove(path) : _picked.add(path)),
                        child: Row(
                          children: [
                            Checkbox(
                              checked: _picked.contains(path),
                              onChanged: (v) => setState(() => v == true ? _picked.add(path) : _picked.remove(path)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(_tidy(path), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            Muted(count == 1 ? '1 project' : '$count projects'),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Button(
            onPressed: _addFolder,
            child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(WindowsIcons.add, size: 12), SizedBox(width: 8), Text('Add folder…')]),
          ),
        ],
      ],
    );
  }

  Widget _preferences(FluentThemeData theme) {
    final settings = context.watch<Settings>();
    Widget row(String title, String subtitle, Widget control) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title), Muted(subtitle)]),
            ),
            const SizedBox(width: 12),
            control,
          ],
        ),
      ),
    );
    final where = Sys.isWindows ? 'system tray' : 'menu bar';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Make it yours', style: theme.typography.title),
        const SizedBox(height: 8),
        const Muted('A few choices; all of them are in Settings later.'),
        const SizedBox(height: 20),
        row(
          'Theme',
          'Follow the system, or pick one.',
          SizedBox(
            width: 140,
            child: ComboBox<ThemeMode>(
              value: settings.themeMode,
              items: const [
                ComboBoxItem(value: ThemeMode.system, child: Text('System')),
                ComboBoxItem(value: ThemeMode.light, child: Text('Light')),
                ComboBoxItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (v) => settings.update((s) => s.themeMode = v ?? ThemeMode.system),
            ),
          ),
        ),
        if (Platform.isWindows || Platform.isMacOS) row('Glass', 'How much the desktop shows through. Try it: the window changes as you drag.', const GlassSlider()),
        row(
          'Keep running when closed',
          'Stays in the $where and tells you when something needs attention.',
          ToggleSwitch(checked: settings.runInBackground, onChanged: (v) => settings.update((s) => s.runInBackground = v)),
        ),
        row(Sys.isWindows ? 'Start with Windows' : 'Open at login', 'Starts quietly in the $where.', const AutoStartToggle()),
      ],
    );
  }

  /// "~/Projects" instead of "/Users/me/Projects".
  static String _tidy(String path) => !Sys.isWindows && path.startsWith(Sys.home) ? '~${path.substring(Sys.home.length)}' : path;
}
