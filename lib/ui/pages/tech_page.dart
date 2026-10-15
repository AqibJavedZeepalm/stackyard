import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/market/installed.dart';
import '../../core/models.dart';
import '../../core/sys.dart';
import '../../state/app_state.dart';
import '../../state/jobs.dart';
import '../dialogs.dart';
import '../motion.dart';
import '../widgets.dart';

/// Filters only earn their space on long lists.
const _filterThreshold = 6;

class TechPage extends StatefulWidget {
  const TechPage({super.key, required this.techId});
  final String techId;

  @override
  State<TechPage> createState() => _TechPageState();
}

class _TechPageState extends State<TechPage> {
  ItemStatus? _filter;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tech = state.tech(widget.techId);
    if (tech == null) {
      return const ScaffoldPage(content: Center(child: Text('This tech is no longer on your machine.')));
    }
    final theme = FluentTheme.of(context);
    final snap = tech.snapshot;
    final visible = snap.items.where((i) => !state.removedIds.contains(i.id)).toList();
    final nameWord = tech.info.name.split(' ').first;
    final installing = [
      for (final job in context.watch<JobQueue>().active)
        if (job.change.recycle.isEmpty && RegExp(r'^(Install|Update|Switch)\b').hasMatch(job.title) && job.title.contains(nameWord)) job,
    ];
    final counts = <ItemStatus, int>{};
    for (final i in visible) {
      counts[i.status] = (counts[i.status] ?? 0) + 1;
    }
    final showFilters = visible.length >= _filterThreshold && counts.length > 1;
    final filter = showFilters && counts.containsKey(_filter) ? _filter : null;
    final groups = <String, List<InstalledItem>>{};
    for (final i in visible.where((i) => filter == null || i.status == filter)) {
      groups.putIfAbsent(i.group, () => []).add(i);
    }

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        title: Row(
          children: [
            TechBadge(tech.info, size: 28),
            const SizedBox(width: 14),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tech.info.name, style: theme.typography.title),
                  Muted(_summary(tech), maxLines: 1),
                ],
              ),
            ),
          ],
        ),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            if (tech.adapter.canInstall)
              CommandBarButton(icon: const Icon(WindowsIcons.add), label: const Text('Install version'), onPressed: () => _install(context, tech)),
            CommandBarButton(icon: const Icon(WindowsIcons.refresh), label: const Text('Rescan'), onPressed: state.scanning ? null : () => state.scan()),
          ],
        ),
      ),
      children: [
        if (tech.updateAvailable || snap.notes.isNotEmpty || snap.info.isNotEmpty || installing.isNotEmpty)
          Appear(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                children: [
                  // Installs have no row yet: show them here while they run.
                  for (final job in installing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Callout(
                        icon: WindowsIcons.download,
                        color: theme.accentColor.defaultBrushFor(theme.brightness),
                        text: job.title,
                        action: BusyLabel(job.status == JobStatus.running ? 'Working…' : 'Waiting…', muted: true),
                      ),
                    ),
                  if (tech.updateAvailable)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Callout(
                        icon: WindowsIcons.download,
                        color: theme.accentColor.defaultBrushFor(theme.brightness),
                        text: '${tech.info.name} ${snap.latest} is available. You\'re on ${tech.global?.version}.',
                        action: !tech.adapter.canInstall
                            ? null
                            : context.watch<JobQueue>().isBusy(tech.adapter.planInstall(snap.latest!)?.title)
                            ? const BusyLabel('Updating…')
                            : FilledButton(child: const Text('Update'), onPressed: () => _runInstall(context, tech, snap.latest!)),
                      ),
                    ),
                  for (final note in snap.notes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Callout(
                        icon: WindowsIcons.warning,
                        color: theme.resources.systemFillColorCaution,
                        text: note,
                        action: snap.fixes.containsKey(note) ? FixButtons(fixes: snap.fixes[note]!) : null,
                      ),
                    ),
                  for (final line in snap.info)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Callout(icon: WindowsIcons.info, text: line),
                    ),
                ],
              ),
            ),
          ),
        if (showFilters)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _FilterTab(
                  key: const ValueKey('filter-all'),
                  label: 'All ${visible.length}',
                  selected: filter == null,
                  onTap: () => setState(() => _filter = null),
                ),
                for (final s in ItemStatus.values)
                  if (counts[s] != null)
                    _FilterTab(
                      key: ValueKey('filter-${s.name}'),
                      label: '${StatusStyle.of(context, s).label} ${counts[s]}',
                      selected: filter == s,
                      onTap: () => setState(() => _filter = filter == s ? null : s),
                    ),
              ],
            ),
          ),
        SmoothSwitcher(
          child: Column(
            key: ValueKey('${filter?.name}-${groups.length}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (g, entry) in groups.entries.indexed) ...[
                SectionTitle(
                  entry.key,
                  top: g == 0 ? 12 : 24,
                  trailing: Muted(
                    entry.value.any((i) => (i.sizeBytes ?? 0) > 0)
                        ? formatBytes(entry.value.fold<int>(0, (s, i) => s + (i.sizeBytes ?? 0)))
                        : '',
                  ),
                ),
                Appear(
                  index: g,
                  child: GroupCard(
                    children: [for (final item in entry.value) VersionRow(key: ValueKey(item.id), tech: tech, item: item)],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (snap.projects.isNotEmpty) ...[
          SectionTitle('Projects', top: 28, trailing: Muted('${snap.projects.length}')),
          Appear(
            index: groups.length,
            child: GroupCard(
              children: [for (final project in snap.projects) _ProjectRow(tech: tech, project: project)],
            ),
          ),
        ],
      ],
    );
  }

  /// "FVM 3.2.1 · 7 versions · 9.4 GB · 4.7 GB unused" (one line instead of four cards).
  String _summary(TechEntry tech) {
    final snap = tech.snapshot;
    if (tech.info.kind == TechKind.framework) {
      final n = snap.projects.length;
      return [
        '${snap.items.length} version${snap.items.length == 1 ? '' : 's'}',
        '$n project${n == 1 ? '' : 's'}',
        if (snap.latest != null) 'latest ${snap.latest}',
      ].join(' · ');
    }
    final count = snap.items.where((i) => !i.isCache).length;
    return [
      snap.managerLabel,
      '$count installed',
      if (snap.totalBytes > 0) formatBytes(snap.totalBytes),
      if (snap.reclaimableBytes > 0) '${formatBytes(snap.reclaimableBytes)} unused',
    ].join(' · ');
  }

  Future<void> _install(BuildContext context, TechEntry tech) async {
    final v = await pickVersion(context, tech, installed: tech.snapshot.items.map((i) => i.version));
    if (v != null && context.mounted) await _runInstall(context, tech, v);
  }

  Future<void> _runInstall(BuildContext context, TechEntry tech, String version) async {
    final plan = tech.adapter.planInstall(version);
    if (plan == null) return;
    if (await confirmChange(context, plan) && context.mounted) {
      context.read<AppState>().run(plan);
    }
  }
}

/// Text-only filter tab: no dots, no chip borders.
class _FilterTab extends StatefulWidget {
  const _FilterTab({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FilterTab> createState() => _FilterTabState();
}

class _FilterTabState extends State<_FilterTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.fast),
          curve: Motion.move,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: widget.selected
                ? r.subtleFillColorSecondary
                : _hover
                ? r.subtleFillColorTertiary
                : r.subtleFillColorTransparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
              color: widget.selected ? r.textFillColorPrimary : r.textFillColorSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// One installed version. Click to expand details, usage and actions.
class VersionRow extends StatefulWidget {
  const VersionRow({super.key, required this.tech, required this.item});
  final TechEntry tech;
  final InstalledItem item;

  @override
  State<VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<VersionRow> {
  bool _expanded = false;

  /// One sentence that carries the status, so no pill or icon is needed.
  String _subtitle() {
    final item = widget.item;
    final n = item.usedBy.length;
    final what = item.usedBy.firstOrNull?.kind ?? 'project'; // 'project', 'emulator', 'simulator'
    final users = '$n $what${n == 1 ? '' : 's'}';
    return switch (item.status) {
      ItemStatus.global => n == 0 ? 'Global default' : 'Global default · used by $users',
      ItemStatus.inUse => n == 0 ? 'Used ${timeAgo(item.lastUsedAt).toLowerCase()}' : 'Used by $users',
      ItemStatus.stale => n > 0 ? 'Stale · $users, none touched in 6+ months' : 'Stale · last used ${timeAgo(item.lastUsedAt).toLowerCase()}',
      ItemStatus.unused => 'Unused',
      ItemStatus.broken => 'Broken · ${item.details['Problem'] ?? 'can\'t work as installed'}',
      ItemStatus.cache => 'Cache · rebuilt when needed',
      ItemStatus.unknown => 'Usage not tracked',
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final jobs = context.watch<JobQueue>();
    final theme = FluentTheme.of(context);
    final item = widget.item;
    final removed = state.removedIds.contains(item.id);
    final busy = jobs.touches(id: item.id, path: item.path) || jobs.isBusy(_defaultPlan(state)?.title);
    final isLatest = widget.tech.snapshot.latest == item.version;
    final r = theme.resources;

    final row = HoverRow(
      onPressed: () => setState(() => _expanded = !_expanded),
      builder: (context, hovered) => Row(
        children: [
          StatusDot(item.status),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: item.title),
                      if (isLatest)
                        TextSpan(
                          text: '  latest',
                          style: TextStyle(color: theme.accentColor.defaultBrushFor(theme.brightness), fontSize: 12),
                        ),
                    ],
                  ),
                  style: theme.typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Muted(busy ? (jobs.touches(id: item.id, path: item.path) ? 'Removing…' : 'Working on it…') : _subtitle(), maxLines: 1),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Some items know their size without a folder to measure (simulator runtimes).
          if (item.path.isNotEmpty || item.sizeBytes != null || busy)
            SizedBox(
              width: 80,
              child: Align(
                alignment: Alignment.centerRight,
                child: busy || item.sizeBytes == null
                    ? const SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2))
                    // 0 B means we can't see the real files (e.g. Store apps), not an empty SDK.
                    : item.sizeBytes == 0
                    ? Tooltip(message: 'Size not available', child: Muted('—'))
                    : AnimatedBytes(item.sizeBytes!, style: theme.typography.body?.copyWith(color: r.textFillColorSecondary)),
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
          if (_expanded) Appear(offset: const Offset(0, -4), child: _details(context)),
        ],
      ),
    );

    // Removed items fade and fold away before the rescan lands.
    return AnimatedSize(
      duration: Motion.of(context, Motion.slow),
      curve: Motion.move,
      child: AnimatedOpacity(
        opacity: removed ? 0 : 1,
        duration: Motion.of(context, Motion.normal),
        child: removed ? const SizedBox(width: double.infinity) : body,
      ),
    );
  }

  /// "Make default": a marketplace version points the environment at itself;
  /// anything else uses its tech's own switch (fvm global, nvm use…).
  PlannedChange? _defaultPlan(AppState state) {
    final item = widget.item;
    if (MarketInstalls.isMarket(item)) {
      final tool = state.marketTool(item.details[MarketInstalls.toolKey]!);
      return tool == null || item.isGlobal ? null : MarketInstalls.planDefault(item, tool, state.settings.installRoot);
    }
    final adapter = widget.tech.adapter;
    return adapter.canSetGlobal(item) ? adapter.planSetGlobal(item) : null;
  }

  Widget _details(BuildContext context) {
    final theme = FluentTheme.of(context);
    final defaultPlan = _defaultPlan(context.read<AppState>());
    final item = widget.item;
    final adapter = widget.tech.adapter;
    final removePlan = adapter.planRemove(item);
    final r = theme.resources;
    final note = item.details['Note'];

    return Padding(
      padding: const EdgeInsets.fromLTRB(38, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.path.isNotEmpty) Muted(item.path, maxLines: 2),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Muted(note)),
          if (item.details.keys.any((k) => k != 'Note' && k != 'Problem' && !k.startsWith('_'))) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 18,
              runSpacing: 2,
              children: [
                for (final e in item.details.entries)
                  if (e.key != 'Note' && e.key != 'Problem' && e.key != 'Registry' && !e.key.startsWith('_'))
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${e.key}  ',
                            style: TextStyle(color: r.textFillColorSecondary),
                          ),
                          TextSpan(text: e.value),
                        ],
                      ),
                      style: theme.typography.caption,
                    ),
              ],
            ),
          ],
          if (item.usedBy.isNotEmpty) ...[const SizedBox(height: 10), for (final u in item.usedBy) _UsageLine(usage: u)],
          const SizedBox(height: 10),
          // While a job works on this item, its actions wait.
          if (context.watch<JobQueue>().touches(id: item.id, path: item.path) || context.watch<JobQueue>().isBusy(defaultPlan?.title))
            const BusyLabel('Working on it…', muted: true)
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (defaultPlan != null)
                  Button(
                    child: Text(MarketInstalls.isMarket(item) ? 'Make default' : 'Make global'),
                    onPressed: () async {
                      if (await confirmChange(context, defaultPlan) && context.mounted) context.read<AppState>().run(defaultPlan);
                    },
                  ),
                if (item.path.isNotEmpty) Button(child: Text('Show in ${Sys.fileManager}'), onPressed: () => Sys.reveal(item.path)),
                if (removePlan != null)
                  Button(
                    style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(r.systemFillColorCritical)),
                    child: const Text('Remove'),
                    onPressed: () => _remove(context, removePlan),
                  )
                else if (item.removeHint != null) ...[
                  Muted(item.removeHint!),
                  if (Sys.isWindows && item.removeHint!.contains('Settings'))
                    HyperlinkButton(child: const Text('Open Apps settings'), onPressed: () => launchUrl(Uri.parse('ms-settings:appsfeatures'))),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _remove(BuildContext context, PlannedChange plan) async {
    final item = widget.item;
    final users = item.usedBy.length;
    final warning = [
      if (item.isGlobal) 'This is your global ${widget.tech.info.name}. Pick another global version first.',
      if (users > 0) '$users ${users == 1 ? 'thing uses' : 'things use'} this and will need it reinstalled.',
      ?plan.warning,
    ];
    final change = PlannedChange(title: plan.title, recycle: plan.recycle, commands: plan.commands, warning: warning.isEmpty ? null : warning.join(' '));
    final confirmed = await confirmRemoval(context, change, bytes: item.sizeBytes);
    if (confirmed != null && context.mounted) {
      context.read<AppState>().run(confirmed, removesItemIds: [item.id]);
    }
  }
}

class _UsageLine extends StatelessWidget {
  const _UsageLine({required this.usage});
  final UsageRef usage;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(usage.kind == 'emulator' ? WindowsIcons.cell_phone : WindowsIcons.folder, size: 12, color: theme.resources.textFillColorSecondary),
          const SizedBox(width: 8),
          Text(usage.name, style: theme.typography.caption),
          if (usage.note != null) ...[const SizedBox(width: 8), Muted(usage.note!)],
          const Spacer(),
          Muted(timeAgo(usage.lastActive)),
          const SizedBox(width: 4),
          Tooltip(
            message: 'Open folder',
            child: IconButton(icon: const Icon(WindowsIcons.open_in_new_window, size: 11), onPressed: () => Sys.openFolder(usage.path)),
          ),
        ],
      ),
    );
  }
}

/// A project that uses this tech. Its actions appear on hover only.
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.tech, required this.project});
  final TechEntry tech;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final version = tech.adapter.projectVersion(project);
    return HoverRow(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      builder: (context, hovered) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: project.name),
                      if (project.isStale)
                        TextSpan(
                          text: '  idle 6+ months',
                          style: TextStyle(color: theme.resources.textFillColorTertiary, fontSize: 12),
                        ),
                    ],
                  ),
                  style: theme.typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Muted(project.path, maxLines: 1),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: Motion.of(context, Motion.fast),
            child: IgnorePointer(
              ignoring: !hovered,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: 'Open folder',
                    child: IconButton(icon: const Icon(WindowsIcons.folder_open, size: 14), onPressed: () => Sys.openFolder(project.path)),
                  ),
                  Tooltip(
                    message: 'Open in VS Code',
                    child: IconButton(icon: const Icon(WindowsIcons.code, size: 14), onPressed: () => Sys.openInVsCode(project.path)),
                  ),
                  Tooltip(
                    message: 'Open terminal here',
                    child: IconButton(icon: const Icon(WindowsIcons.command_prompt, size: 14), onPressed: () => Sys.openTerminal(project.path)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              version ?? '—',
              textAlign: TextAlign.right,
              style: theme.typography.body?.copyWith(color: theme.resources.textFillColorSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
