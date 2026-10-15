import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/project_junk.dart';
import '../../core/sys.dart';
import '../../state/app_state.dart';
import '../../state/jobs.dart';
import '../dialogs.dart';
import '../motion.dart';
import '../widgets.dart';

/// Build folders inside your projects (node_modules, build, .gradle…): how much
/// space they take and a one-click clean. They come back on the next build.
class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final jobs = context.watch<JobQueue>();
    final theme = FluentTheme.of(context);
    final visible = [
      for (final c in state.cleanups)
        if (c.folders.any((f) => !state.removedIds.contains(f.id))) c,
    ]..sort((a, b) => b.bytes.compareTo(a.bytes));
    final idle = visible.where((c) => c.isIdle && c.bytes > 0).toList();
    final idleBytes = idle.fold<int>(0, (s, c) => s + c.bytes);
    final total = visible.fold<int>(0, (s, c) => s + c.bytes);
    final measuring = visible.any((c) => !c.measured);
    final withNothing = state.projects.length - visible.length;

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        title: const Text('Projects'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(icon: const Icon(WindowsIcons.refresh), label: const Text('Rescan'), onPressed: state.scanning ? null : () => state.scan()),
          ],
        ),
      ),
      children: [
        Appear(
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Muted('Build folders in your projects'),
                      AnimatedBytes(
                        total,
                        style: theme.typography.display?.copyWith(
                          color: theme.accentColor.defaultBrushFor(theme.brightness),
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Muted(
                        measuring
                            ? 'Still measuring…'
                            : 'node_modules, build outputs and caches across ${visible.length} project${visible.length == 1 ? '' : 's'}. '
                                  'They come back by themselves the next time you build.',
                      ),
                    ],
                  ),
                ),
                if (idle.any((c) => c.folders.any((f) => jobs.touches(id: f.id)))) ...[
                  const SizedBox(width: 16),
                  const BusyLabel('Cleaning…'),
                ] else if (idle.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  FilledButton(
                    onPressed: () => _clean(context, idle, title: 'Clean ${idle.length} idle project${idle.length == 1 ? '' : 's'}'),
                    child: Text('Clean idle projects · ${formatBytes(idleBytes)}'),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Callout(icon: WindowsIcons.completed, text: 'Nothing to clean. Your projects have no build folders right now.'),
          )
        else ...[
          SectionTitle('Projects', trailing: Muted(idle.isEmpty ? '${visible.length}' : '${idle.length} idle 3+ months')),
          Appear(
            index: 1,
            child: GroupCard(
              children: [for (final c in visible) _CleanupRow(key: ValueKey(c.project.path), cleanup: c)],
            ),
          ),
          if (withNothing > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 4),
              child: Muted('$withNothing other project${withNothing == 1 ? ' has' : 's have'} nothing to clean.'),
            ),
        ],
      ],
    );
  }
}

/// Confirms, then moves every build folder of [cleanups] to the Recycle Bin.
Future<void> _clean(BuildContext context, List<ProjectCleanup> cleanups, {required String title}) async {
  final state = context.read<AppState>();
  final folders = [
    for (final c in cleanups)
      for (final f in c.folders)
        if (!state.removedIds.contains(f.id)) f,
  ];
  final recent = cleanups.where((c) => DateTime.now().difference(c.project.lastModified) < const Duration(days: 14)).toList();
  final change = PlannedChange(
    title: title,
    recycle: [for (final f in folders) f.path],
    warning: [
      'Only build output and installed packages are removed. Your code is never touched.',
      if (recent.isNotEmpty)
        '${recent.map((c) => c.project.name).join(', ')} ${recent.length == 1 ? 'was' : 'were'} worked on recently, so the next build takes longer.',
    ].join(' '),
  );
  final bytes = folders.fold<int>(0, (s, f) => s + (f.sizeBytes ?? 0));
  final confirmed = await confirmRemoval(context, change, bytes: bytes);
  if (confirmed != null && context.mounted) {
    state.run(confirmed, removesItemIds: [for (final f in folders) f.id]);
  }
}

class _CleanupRow extends StatefulWidget {
  const _CleanupRow({super.key, required this.cleanup});
  final ProjectCleanup cleanup;

  @override
  State<_CleanupRow> createState() => _CleanupRowState();
}

class _CleanupRowState extends State<_CleanupRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    final c = widget.cleanup;
    final folders = c.folders.where((f) => !state.removedIds.contains(f.id)).toList();
    final gone = folders.isEmpty;
    final busy = folders.any((f) => context.watch<JobQueue>().touches(id: f.id));

    final row = HoverRow(
      onPressed: () => setState(() => _expanded = !_expanded),
      builder: (context, hovered) => Row(
        children: [
          Icon(WindowsIcons.folder, size: 16, color: r.textFillColorSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: c.project.name),
                      TextSpan(
                        text: '  ${c.isIdle ? 'idle · ' : ''}${timeAgo(c.project.lastModified).toLowerCase()}',
                        style: TextStyle(color: r.textFillColorTertiary, fontSize: 12),
                      ),
                    ],
                  ),
                  style: theme.typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Muted(busy ? 'Cleaning…' : folders.map((f) => f.title).join(' · '), maxLines: 1),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AnimatedOpacity(
            opacity: hovered && !busy ? 1 : 0,
            duration: Motion.of(context, Motion.fast),
            child: IgnorePointer(
              ignoring: !hovered || busy,
              child: Button(
                onPressed: () => _clean(context, [c], title: 'Clean ${c.project.name}'),
                child: const Text('Clean'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: Align(
              alignment: Alignment.centerRight,
              child: busy || !c.measured
                  ? const SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2))
                  : AnimatedBytes(c.bytes, style: theme.typography.body?.copyWith(color: r.textFillColorSecondary)),
            ),
          ),
          const SizedBox(width: 10),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: Motion.of(context, Motion.normal),
            curve: Motion.move,
            child: Icon(WindowsIcons.chevron_down, size: 9, color: r.textFillColorSecondary),
          ),
        ],
      ),
    );

    final body = AnimatedSize(
      duration: Motion.of(context, Motion.normal),
      curve: Motion.move,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          if (_expanded)
            Appear(
              offset: const Offset(0, -4),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(46, 0, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Muted(c.project.path, maxLines: 2),
                    const SizedBox(height: 8),
                    for (final f in folders)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            SizedBox(width: 150, child: Text(f.title, style: theme.typography.body)),
                            Expanded(child: Muted('Comes back with ${f.details['Comes back with']}', maxLines: 1)),
                            Text(
                              f.sizeBytes == null ? '…' : formatBytes(f.sizeBytes!),
                              style: theme.typography.body?.copyWith(color: r.textFillColorSecondary),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (busy)
                          const BusyLabel('Cleaning…', muted: true)
                        else
                          FilledButton(
                            onPressed: () => _clean(context, [c], title: 'Clean ${c.project.name}'),
                            child: const Text('Clean this project'),
                          ),
                        Button(onPressed: () => Sys.openFolder(c.project.path), child: Text('Open in ${Sys.fileManager}')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    // Cleaned projects fold away before the rescan lands.
    return AnimatedSize(
      duration: Motion.of(context, Motion.slow),
      curve: Motion.move,
      child: AnimatedOpacity(
        opacity: gone ? 0 : 1,
        duration: Motion.of(context, Motion.normal),
        child: gone ? const SizedBox(width: double.infinity) : body,
      ),
    );
  }
}
