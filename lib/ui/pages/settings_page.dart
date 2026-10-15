import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../core/autostart.dart';
import '../../core/sys.dart';
import '../../state/app_state.dart';
import '../../state/settings.dart';
import '../motion.dart';
import '../stack_dialogs.dart';
import '../widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final state = context.read<AppState>();
    final theme = FluentTheme.of(context);

    Widget row(int i, {required IconData icon, required String title, String? subtitle, required Widget trailing}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Appear(
        index: i,
        child: SurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.typography.body),
                    if (subtitle != null) Muted(subtitle),
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 36),
      header: const PageHeader(padding: 36, title: Text('Settings')),
      children: [
        SectionTitle(
          'Project folders',
          top: 0,
          trailing: Button(
            child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(WindowsIcons.add, size: 12), SizedBox(width: 8), Text('Add folder')]),
            onPressed: () async {
              final dir = await getDirectoryPath(confirmButtonText: 'Add folder');
              if (dir == null || settings.roots.contains(dir)) return;
              settings.update((s) => s.roots = [...s.roots, dir]);
              state.scan();
            },
          ),
        ),
        const Padding(padding: EdgeInsets.only(bottom: 8), child: Muted('Stackyard looks in these folders to see which projects use which versions.')),
        for (final (i, root) in settings.roots.indexed)
          row(
            i,
            icon: WindowsIcons.folder,
            title: root,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: 'Open folder',
                  child: IconButton(icon: const Icon(WindowsIcons.open_in_new_window, size: 14), onPressed: () => Sys.openFolder(root)),
                ),
                Tooltip(
                  message: 'Stop scanning this folder',
                  child: IconButton(
                    icon: const Icon(WindowsIcons.delete, size: 14),
                    onPressed: () {
                      settings.update((s) => s.roots = s.roots.where((r) => r != root).toList());
                      state.scan();
                    },
                  ),
                ),
              ],
            ),
          ),
        row(
          settings.roots.length,
          icon: WindowsIcons.view_all,
          title: 'Folder depth',
          subtitle: 'How many levels deep to look for projects',
          trailing: SizedBox(
            width: 170,
            child: ComboBox<int>(
              value: settings.scanDepth,
              items: [
                for (final d in [3, 4, 5, 6, 8]) ComboBoxItem(value: d, child: Text('$d levels')),
              ],
              onChanged: (v) {
                if (v == null) return;
                settings.update((s) => s.scanDepth = v);
                state.scan();
              },
            ),
          ),
        ),
        const SectionTitle('Appearance'),
        row(
          10,
          icon: WindowsIcons.color,
          title: 'Theme',
          trailing: SizedBox(
            width: 170,
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
        if (Sys.isWindows)
          row(
            11,
            icon: WindowsIcons.personalize,
            title: 'Mica background',
            subtitle: 'Let your wallpaper tint the window, like other Windows 11 apps',
            trailing: ToggleSwitch(checked: settings.mica, onChanged: (v) => settings.update((s) => s.mica = v)),
          ),
        row(
          12,
          icon: WindowsIcons.speed_high,
          title: 'Reduce motion',
          subtitle: 'Turn off animations. Stackyard also follows the ${Sys.isWindows ? 'Windows' : 'system'} animation setting.',
          trailing: ToggleSwitch(checked: settings.reduceMotion, onChanged: (v) => settings.update((s) => s.reduceMotion = v)),
        ),
        const SectionTitle('Background'),
        row(
          20,
          icon: WindowsIcons.taskbar_phone,
          title: 'Keep running when closed',
          subtitle: 'Closing the window keeps Stackyard in the ${Sys.isWindows ? 'system tray' : 'menu bar'}, where it can check your setup.',
          trailing: ToggleSwitch(checked: settings.runInBackground, onChanged: (v) => settings.update((s) => s.runInBackground = v)),
        ),
        row(
          21,
          icon: WindowsIcons.ringer,
          title: 'Check for updates and problems',
          subtitle: settings.lastCheckAt == 0
              ? 'Notifies you only when there\'s something new.'
              : 'Notifies you only when there\'s something new. Last checked ${timeAgo(DateTime.fromMillisecondsSinceEpoch(settings.lastCheckAt)).toLowerCase()}.',
          trailing: SizedBox(
            width: 170,
            child: ComboBox<String>(
              value: settings.checkEvery,
              items: const [
                ComboBoxItem(value: 'daily', child: Text('Daily')),
                ComboBoxItem(value: 'weekly', child: Text('Weekly')),
                ComboBoxItem(value: 'off', child: Text('Never')),
              ],
              onChanged: (v) => settings.update((s) => s.checkEvery = v ?? 'weekly'),
            ),
          ),
        ),
        row(
          22,
          icon: WindowsIcons.power_button,
          title: Sys.isWindows ? 'Start with Windows' : 'Open at login',
          subtitle: 'Starts quietly in the ${Sys.isWindows ? 'tray' : 'menu bar'}, without opening the window.',
          trailing: const _AutoStartToggle(),
        ),
        const SectionTitle('Get tools'),
        row(
          24,
          icon: WindowsIcons.download,
          title: 'Install tools to',
          subtitle:
              '${settings.installRoot}. Each tool gets its own folder, each version a folder inside it. You can still pick another folder for any install.',
          trailing: Button(
            child: const Text('Change…'),
            onPressed: () async {
              final dir = await getDirectoryPath(confirmButtonText: 'Use this folder');
              if (dir != null) settings.update((s) => s.installRoot = dir);
            },
          ),
        ),
        const SectionTitle('Your stack'),
        row(
          23,
          icon: WindowsIcons.share,
          title: 'Move your setup to another computer',
          subtitle:
              'Export saves your Flutter, Node, Python, Java, .NET and Android SDK versions to a file. Import it on another computer to install what\'s missing.',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Button(onPressed: () => exportStack(context), child: const Text('Export…')),
              const SizedBox(width: 8),
              Button(onPressed: () => importStack(context), child: const Text('Import…')),
            ],
          ),
        ),
        const SectionTitle('About'),
        row(
          13,
          icon: WindowsIcons.info,
          title: 'Stackyard 0.1.0',
          subtitle: 'Open source. Your data stays on this ${Sys.isWindows ? 'PC' : 'Mac'}: no accounts, no telemetry.',
          trailing: Muted('Data: ${Settings.dataDir.path}'),
        ),
      ],
    );
  }
}

/// The sign-in setting lives in the system (registry / LaunchAgent), so it's read from there.
class _AutoStartToggle extends StatefulWidget {
  const _AutoStartToggle();

  @override
  State<_AutoStartToggle> createState() => _AutoStartToggleState();
}

class _AutoStartToggleState extends State<_AutoStartToggle> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    AutoStart.isEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) => ToggleSwitch(
    checked: _on ?? false,
    onChanged: _on == null
        ? null
        : (v) async {
            setState(() => _on = v);
            await AutoStart.setEnabled(v);
            final actual = await AutoStart.isEnabled();
            if (mounted) setState(() => _on = actual);
          },
  );
}
