import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/sys.dart';
import '../../state/app_state.dart';
import '../../state/jobs.dart';
import '../dialogs.dart';
import '../motion.dart';
import '../widgets.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key, required this.onOpenTech});
  final void Function(String techId) onOpenTech;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  final Set<String> _selected = {};
  bool _allNotes = false;

  /// Beyond this, Needs attention collapses behind "Show all".
  static const _noteLimit = 4;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = FluentTheme.of(context);

    if (state.techs.isEmpty) {
      return ScaffoldPage(
        content: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.scanning) ...[
                const ProgressRing(),
                const SizedBox(height: 16),
                Text('Looking for SDKs and projects…', style: theme.typography.bodyLarge),
              ] else ...[
                Text('Nothing found yet', style: theme.typography.subtitle),
                const SizedBox(height: 8),
                const Muted('Add your project folders in Settings, then rescan.'),
              ],
            ],
          ),
        ),
      );
    }

    final wins = state.quickWins;
    _selected.retainWhere((id) => wins.any((w) => w.$2.id == id));
    final selectedBytes = wins.where((w) => _selected.contains(w.$2.id)).fold<int>(0, (s, w) => s + (w.$2.sizeBytes ?? 0));
    final bySize = [...state.techs.where((t) => t.snapshot.totalBytes > 0)]..sort((a, b) => b.snapshot.totalBytes.compareTo(a.snapshot.totalBytes));
    // Each problem carries the button that fixes it, so most can be fixed right here.
    final attention = <(TechEntry?, IconData, Color, String, List<NoteFix>)>[
      // Machine setup first: these break every tool, not just one.
      for (final issue in state.systemIssues) (null, WindowsIcons.repair, theme.resources.systemFillColorCaution, issue.text, issue.fixes),
      for (final t in state.techs.where((t) => t.updateAvailable))
        (
          t,
          WindowsIcons.download,
          theme.accentColor.defaultBrushFor(theme.brightness),
          '${t.info.name} ${t.snapshot.latest} is available. You\'re on ${t.global?.version}.',
          [
            if (t.adapter.canInstall)
              if (t.adapter.planInstall(t.snapshot.latest!) case final plan?) NoteFix('Update', plan, recommended: true),
          ],
        ),
      for (final (t, note) in state.notes) (t, WindowsIcons.warning, theme.resources.systemFillColorCaution, note, t.snapshot.fixes[note] ?? const <NoteFix>[]),
    ];

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        title: const Text('Overview'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(icon: const Icon(WindowsIcons.refresh), label: const Text('Rescan'), onPressed: state.scanning ? null : () => state.scan()),
          ],
        ),
      ),
      children: [
        // One hero: what you can free, and where the space goes.
        Appear(
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Muted('You can free'),
                AnimatedBytes(
                  state.reclaimableBytes,
                  style: theme.typography.display?.copyWith(
                    color: theme.accentColor.defaultBrushFor(theme.brightness),
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Muted(
                  state.measuring && state.measureTotal > 0
                      ? 'So far · still measuring ${state.measureDone} of ${state.measureTotal} folders'
                      : [
                          '${wins.length} unused or broken item${wins.length == 1 ? '' : 's'}',
                          '${formatBytes(state.totalBytes)} of dev tools on this ${Sys.computer}',
                        ].join(' · '),
                ),
                const SizedBox(height: 18),
                StorageBar(height: 8, segments: [for (final t in bySize.take(8)) (t.id, t.info.color, t.snapshot.totalBytes)]),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [for (final t in bySize) _Legend(tech: t, onTap: () => widget.onOpenTech(t.id))],
                ),
              ],
            ),
          ),
        ),

        // Build folders live in projects, not in SDKs: point to the Projects page.
        if (state.buildFolderBytes > 0)
          Appear(
            index: 1,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SurfaceCard(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Callout(
                  icon: WindowsIcons.folder,
                  text:
                      'Your projects also hold ${formatBytes(state.buildFolderBytes)} of build folders (node_modules, build, .gradle…) that come back on the next build.',
                  action: Button(onPressed: () => widget.onOpenTech('projects'), child: const Text('Review')),
                ),
              ),
            ),
          ),

        if (attention.isNotEmpty) ...[
          SectionTitle(
            'Needs attention',
            trailing: attention.length > _noteLimit
                ? HyperlinkButton(
                    child: Text(_allNotes ? 'Show less' : 'Show all ${attention.length}'),
                    onPressed: () => setState(() => _allNotes = !_allNotes),
                  )
                : null,
          ),
          Appear(
            index: 1,
            child: GroupCard(
              children: [
                for (final (tech, icon, color, text, fixes) in _allNotes ? attention : attention.take(_noteLimit))
                  HoverRow(
                    onPressed: tech == null ? null : () => widget.onOpenTech(tech.id),
                    builder: (context, hovered) => Row(
                      children: [
                        Icon(icon, size: 14, color: color),
                        const SizedBox(width: 12),
                        if (tech != null)
                          TechBadge(tech.info, size: 16)
                        else
                          Icon(WindowsIcons.settings, size: 16, color: theme.resources.textFillColorSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.typography.body),
                        ),
                        const SizedBox(width: 12),
                        if (fixes.isNotEmpty) ...[FixButtons(fixes: fixes, compact: true), const SizedBox(width: 8)],
                        if (tech != null) Icon(WindowsIcons.chevron_right, size: 9, color: theme.resources.textFillColorSecondary),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],

        SectionTitle(
          'Quick wins',
          trailing: wins.isEmpty
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HyperlinkButton(
                      child: Text(_selected.length == wins.length ? 'Select none' : 'Select all'),
                      onPressed: () => setState(() {
                        if (_selected.length == wins.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(wins.map((w) => w.$2.id));
                        }
                      }),
                    ),
                    const SizedBox(width: 8),
                    if (wins.any((w) => context.watch<JobQueue>().touches(id: w.$2.id)))
                      const BusyLabel('Cleaning…')
                    else
                      FilledButton(
                        onPressed: _selected.isEmpty ? null : () => _cleanSelected(context, wins),
                        child: Text(_selected.isEmpty ? 'Clean up' : 'Clean up ${formatBytes(selectedBytes)}'),
                      ),
                  ],
                ),
        ),
        if (wins.isEmpty)
          const Appear(
            child: Callout(icon: WindowsIcons.completed, text: 'Nothing to clean. Everything installed is in use.'),
          )
        else
          Appear(
            index: 2,
            child: GroupCard(
              children: [
                for (final (tech, item) in wins)
                  _WinRow(
                    tech: tech,
                    item: item,
                    selected: _selected.contains(item.id),
                    onChanged: (v) => setState(() => v ? _selected.add(item.id) : _selected.remove(item.id)),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _cleanSelected(BuildContext context, List<(TechEntry, InstalledItem)> wins) async {
    final chosen = wins.where((w) => _selected.contains(w.$2.id)).toList();
    final recycle = <String>[];
    final commands = <CommandSpec>[];
    for (final (tech, item) in chosen) {
      final plan = tech.adapter.planRemove(item);
      recycle.addAll(plan?.recycle ?? const []);
      // Some things are removed with their own uninstaller rather than the Recycle Bin.
      commands.addAll(plan?.commands ?? const []);
    }
    final bytes = chosen.fold<int>(0, (s, w) => s + (w.$2.sizeBytes ?? 0));
    final change = PlannedChange(title: 'Clean up ${chosen.length} item${chosen.length == 1 ? '' : 's'}', recycle: recycle, commands: commands);
    final confirmed = await confirmRemoval(context, change, bytes: bytes);
    if (confirmed != null && context.mounted) {
      context.read<AppState>().run(confirmed, removesItemIds: chosen.map((w) => w.$2.id).toList());
      setState(_selected.clear);
    }
  }
}

/// Legend entry under the storage bar: dot, name, size. Click to open the tech.
class _Legend extends StatelessWidget {
  const _Legend({required this.tech, required this.onTap});
  final TechEntry tech;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: tech.info.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(tech.info.name, style: theme.typography.caption),
            const SizedBox(width: 4),
            Muted(formatBytes(tech.snapshot.totalBytes)),
          ],
        ),
      ),
    );
  }
}

class _WinRow extends StatelessWidget {
  const _WinRow({required this.tech, required this.item, required this.selected, required this.onChanged});

  final TechEntry tech;
  final InstalledItem item;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final busy = context.watch<JobQueue>().touches(id: item.id, path: item.path);
    final why = busy
        ? 'Removing…'
        : item.status == ItemStatus.broken
        ? (item.details['Problem'] ?? 'Broken')
        : item.group == 'Versions'
        ? 'Unused version'
        : 'Unused · ${item.group}';
    // Some titles already name the tech ("Android SDK at …"); don't say it twice.
    final title = item.title.startsWith(tech.info.name) ? item.title : '${tech.info.name} ${item.title}';
    return HoverRow(
      onPressed: busy ? null : () => onChanged(!selected),
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      builder: (context, hovered) => Row(
        children: [
          Checkbox(checked: selected && !busy, onChanged: busy ? null : (v) => onChanged(v ?? false)),
          const SizedBox(width: 12),
          TechBadge(tech.info, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.typography.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                Muted(why, maxLines: 1),
              ],
            ),
          ),
          busy || item.sizeBytes == null
              ? const SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2))
              : AnimatedBytes(item.sizeBytes!, style: theme.typography.body),
        ],
      ),
    );
  }
}
