import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/semver.dart';
import '../core/sys.dart';
import '../state/app_state.dart';
import '../state/jobs.dart';
import 'motion.dart';
import 'widgets.dart';

/// The buttons that fix a problem. Each shows what it will do, then runs as a
/// job; while it runs, its button turns into a spinner and the others wait.
class FixButtons extends StatelessWidget {
  const FixButtons({super.key, required this.fixes, this.compact = false});
  final List<NoteFix> fixes;

  /// Only the main fix, for tight rows like the Overview's.
  final bool compact;

  /// "Update" → "Updating…", "Install JDK 17" → "Installing…".
  static String busyWord(String label) {
    final first = label.split(' ').first.toLowerCase();
    return switch (first) {
      'update' => 'Updating…',
      'install' => 'Installing…',
      'remove' || 'uninstall' || 'delete' => 'Removing…',
      'clean' => 'Cleaning…',
      'switch' => 'Switching…',
      _ => 'Fixing…',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (fixes.isEmpty) return const SizedBox.shrink();
    final jobs = context.watch<JobQueue>();
    final ordered = [...fixes]..sort((a, b) => (b.recommended ? 1 : 0) - (a.recommended ? 1 : 0));
    final shown = compact ? ordered.take(1) : ordered;
    final running = fixes.where((f) => jobs.isBusy(f.change.title)).firstOrNull;
    if (running != null) return BusyLabel(busyWord(running.label));
    Future<void> run(NoteFix fix) async {
      if (await confirmChange(context, fix.change) && context.mounted) context.read<AppState>().run(fix.change);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (i, fix) in shown.indexed)
          i == 0 ? FilledButton(onPressed: () => run(fix), child: Text(fix.label)) : Button(onPressed: () => run(fix), child: Text(fix.label)),
      ],
    );
  }
}

/// Shows exactly what will happen and asks before doing it.
Future<bool> confirmChange(BuildContext context, PlannedChange change, {int? bytes, bool destructive = false}) async =>
    (await _confirm(context, change, bytes: bytes, destructive: destructive)) != null;

/// Like [confirmChange] for removals: also offers to skip the Recycle Bin / Trash.
/// Returns the change to run (marked permanent if chosen), or null if cancelled.
Future<PlannedChange?> confirmRemoval(BuildContext context, PlannedChange change, {int? bytes}) =>
    _confirm(context, change, bytes: bytes, destructive: true, offerPermanent: change.recycle.isNotEmpty);

Future<PlannedChange?> _confirm(BuildContext context, PlannedChange change, {int? bytes, bool destructive = false, bool offerPermanent = false}) async {
  var permanent = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final theme = FluentTheme.of(context);
        final mono = TextStyle(
          fontFamily: 'Cascadia Mono',
          fontFamilyFallback: const ['Consolas', 'SF Mono', 'Menlo'],
          fontSize: 12.5,
          color: theme.resources.textFillColorPrimary,
        );
        Widget step(IconData icon, String label, String detail) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 14)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.typography.body),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: theme.resources.subtleFillColorSecondary, borderRadius: BorderRadius.circular(4)),
                      child: SelectableText(detail, style: mono),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 560),
          title: Text(change.title),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (bytes != null && bytes > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text('Frees about ${formatBytes(bytes)}.', style: theme.typography.bodyLarge),
                  ),
                for (final d in change.downloads)
                  step(WindowsIcons.download, 'Download ${d.label} and check it', '${d.url}${d.extractTo == null ? '' : '\n→ ${d.extractTo}'}'),
                for (final e in change.edits) step(WindowsIcons.edit, 'Edit a file', '${e.path}\n${(e.summary ?? e.content).trim()}'),
                for (final r in change.recycle) step(WindowsIcons.delete, permanent ? 'Delete permanently' : 'Move to the ${Sys.trashName}', r),
                for (final c in change.commands)
                  step(
                    WindowsIcons.command_prompt,
                    c.title + (c.needsAdmin ? ' (asks for admin)' : ''),
                    (c.workingDirectory != null ? 'cd ${c.workingDirectory}\n' : '') + c.display,
                  ),
                if (change.env.isNotEmpty)
                  step(
                    WindowsIcons.settings,
                    Sys.isWindows
                        ? (change.envForEveryone ? 'Environment variables for everyone (asks for admin)' : 'Your environment variables')
                        : 'Your shell profile (~/.zprofile)',
                    change.env.map((e) => e.describe).join('\n'),
                  ),
                if (change.warning != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: InfoBar(title: const Text('Before you continue'), content: Text(change.warning!), severity: InfoBarSeverity.warning, isLong: true),
                  ),
                if (change.learnMoreUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: HyperlinkButton(onPressed: () => launchUrl(Uri.parse(change.learnMoreUrl!)), child: const Text('Open the upgrade guide')),
                  ),
                if (offerPermanent)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    // Fluent's checkbox label can't wrap, so the text sits beside it (and toggles it too).
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(checked: permanent, onChanged: (v) => setDialogState(() => permanent = v ?? false)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setDialogState(() => permanent = !permanent),
                            child: const Text('Delete permanently instead. Faster, frees the space right away, but it can\'t be undone.'),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context, false)),
            FilledButton(
              style: destructive ? ButtonStyle(backgroundColor: WidgetStatePropertyAll(theme.resources.systemFillColorCritical)) : null,
              autofocus: true,
              child: Text(
                !destructive
                    ? 'Run'
                    : permanent
                    ? 'Delete permanently'
                    : change.recycle.isEmpty
                    ? 'Uninstall'
                    : 'Move to ${Sys.trashName}',
              ),
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) return null;
  return permanent ? change.deletingPermanently() : change;
}

/// Lets you pick a version to install from upstream releases.
Future<String?> pickVersion(
  BuildContext context,
  TechEntry tech, {
  String title = 'Install a version',
  String action = 'Install',
  Iterable<String> installed = const [],
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _VersionPicker(tech: tech, title: title, action: action, installed: installed.toSet()),
  );
}

class _VersionPicker extends StatefulWidget {
  const _VersionPicker({required this.tech, required this.title, required this.action, required this.installed});
  final TechEntry tech;
  final String title;
  final String action;
  final Set<String> installed;

  @override
  State<_VersionPicker> createState() => _VersionPickerState();
}

class _VersionPickerState extends State<_VersionPicker> {
  late final Future<List<VersionOption>> _future = widget.tech.adapter.availableVersions();
  String _query = '';
  bool _stableOnly = true;
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextBox(
                  placeholder: 'Search versions',
                  prefix: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(WindowsIcons.search, size: 12)),
                  onChanged: (v) => setState(() => _query = v.trim()),
                  autofocus: true,
                ),
              ),
              const SizedBox(width: 12),
              ToggleSwitch(checked: _stableOnly, onChanged: (v) => setState(() => _stableOnly = v), content: const Text('Stable only')),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 380,
            child: FutureBuilder<List<VersionOption>>(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(child: Text('Couldn\'t load versions. Check your connection and try again.'));
                }
                if (!snap.hasData) return const Center(child: ProgressRing());
                final list = snap.data!
                    .where((v) {
                      if (_stableOnly && (v.channel == 'beta' || (Ver.tryParse(v.version)?.isPrerelease ?? false))) {
                        return false;
                      }
                      return _query.isEmpty || v.version.contains(_query);
                    })
                    .take(200)
                    .toList();
                if (list.isEmpty) return const Center(child: Text('No versions match.'));
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final v = list[i];
                    final isInstalled = widget.installed.contains(v.version);
                    return Appear(
                      index: i,
                      offset: const Offset(0, 6),
                      child: ListTile.selectable(
                        selected: _selected == v.version,
                        onSelectionChange: (_) => setState(() => _selected = v.version),
                        title: Row(
                          children: [
                            Text(v.version, style: theme.typography.bodyStrong),
                            const SizedBox(width: 8),
                            if (v.isLatest) Pill(label: 'Latest', color: theme.accentColor.defaultBrushFor(theme.brightness)),
                            if (v.isLts && !v.isLatest) Pill(label: 'LTS', color: theme.resources.systemFillColorSuccess),
                            if (v.channel == 'beta') Pill(label: 'Beta', color: theme.resources.systemFillColorCaution),
                            if (isInstalled) ...[const SizedBox(width: 6), Pill(label: 'Installed', color: theme.resources.textFillColorSecondary)],
                          ],
                        ),
                        subtitle: Text(
                          [
                            if (v.date != null) '${v.date!.year}-${v.date!.month.toString().padLeft(2, '0')}-${v.date!.day.toString().padLeft(2, '0')}',
                            if (v.note != null) v.note!,
                          ].join(' · '),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      actions: [
        Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context)),
        FilledButton(onPressed: _selected == null ? null : () => Navigator.pop(context, _selected), child: Text(widget.action)),
      ],
    );
  }
}
