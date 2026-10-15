import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';
import '../state/jobs.dart';
import 'motion.dart';
import 'pages/activity_page.dart';
import 'pages/emulators_page.dart';
import 'pages/market_page.dart';
import 'pages/overview_page.dart';
import 'pages/projects_page.dart';
import 'pages/settings_page.dart';
import 'pages/tech_page.dart';
import 'widgets.dart';

/// Main window: Windows 11 title bar, navigation pane, and pages.
class Shell extends StatefulWidget {
  const Shell({super.key, this.autoScan = true, this.nativeChrome = true});

  /// Scan the machine when the window opens.
  final bool autoScan;

  /// Draw window caption buttons (off in tests, where there's no window).
  final bool nativeChrome;

  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  String _selected = 'overview';

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    state.onJobNotification = _notify;
    if (widget.autoScan) WidgetsBinding.instance.addPostFrameCallback((_) => state.scan());
  }

  void _notify(Job job) {
    if (!mounted) return;
    final ok = job.status == JobStatus.done;
    displayInfoBar(
      context,
      alignment: Alignment.bottomRight,
      duration: const Duration(seconds: 5),
      builder: (context, close) => InfoBar(
        title: Text(ok ? 'Done' : 'Didn\'t finish'),
        content: Text(ok ? job.title : '${job.title}: ${job.error ?? 'failed'}'),
        severity: ok ? InfoBarSeverity.success : InfoBarSeverity.error,
        action: ok
            ? null
            : Button(
                child: const Text('Details'),
                onPressed: () {
                  close();
                  setState(() => _selected = 'activity');
                },
              ),
        onClose: close,
      ),
    );
  }

  /// Shows a page by id: 'overview', a tech id, 'activity' or 'settings'.
  void open(String id) => setState(() => _selected = id);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final jobs = context.watch<JobQueue>();
    final theme = FluentTheme.of(context);

    PaneItem techItem(TechEntry t) => PaneItem(
      key: ValueKey(t.id),
      // 16 px like Fluent icons, so the pane never overflows while it animates.
      icon: Appear(onceKey: 'nav-icon-${t.id}', offset: const Offset(-10, 0), child: TechBadge(t.info, size: 16)),
      // The update dot lives in the title (which shrinks safely), not in
      // infoBadge, which fluent_ui shows before the pane finishes widening.
      title: Appear(
        onceKey: 'nav-title-${t.id}',
        offset: const Offset(-10, 0),
        child: _PaneTitle(
          t.info.name,
          trailing: t.updateAvailable
              ? Tooltip(
                  message: 'Update available',
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: theme.accentColor.defaultBrushFor(theme.brightness), shape: BoxShape.circle),
                  ),
                )
              : null,
        ),
      ),
      body: TechPage(key: ValueKey('page-${t.id}'), techId: t.id),
    );

    final toolchains = state.toolchains;
    final frameworks = state.frameworks;
    final emulatorCount = state.tech('android')?.snapshot.items.where((i) => i.group == 'Emulators').length ?? 0;
    final keys = [
      'overview',
      'market',
      'projects',
      if (emulatorCount > 0) 'emulators',
      ...toolchains.map((t) => t.id),
      ...frameworks.map((t) => t.id),
      'activity',
      'settings',
    ];
    if (!keys.contains(_selected)) _selected = 'overview';

    return NavigationView(
      titleBar: TitleBar(
        isBackButtonVisible: false,
        // Leaves room for the macOS traffic-light buttons.
        icon: Padding(padding: EdgeInsets.only(left: Platform.isMacOS ? 64 : 0), child: const _AppIcon()),
        title: const Text('Stackyard'),
        endHeader: _ScanStatus(state: state, jobs: jobs, onOpenActivity: () => open('activity')),
        captionControls: widget.nativeChrome && Platform.isWindows
            ? SizedBox(
                width: 138,
                height: 48,
                child: WindowCaption(brightness: theme.brightness, backgroundColor: Colors.transparent),
              )
            : null,
        onDragStarted: widget.nativeChrome ? windowManager.startDragging : null,
        onDoubleTap: !widget.nativeChrome
            ? null
            : () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
      ),
      pane: NavigationPane(
        selected: keys.indexOf(_selected),
        onChanged: (i) => setState(() => _selected = keys[i]),
        displayMode: PaneDisplayMode.auto,
        size: const NavigationPaneSize(openWidth: 260),
        items: [
          PaneItem(
            key: const ValueKey('overview'),
            icon: const Icon(WindowsIcons.home),
            title: const Text('Overview'),
            body: OverviewPage(onOpenTech: open),
          ),
          PaneItem(key: const ValueKey('market'), icon: const Icon(WindowsIcons.shop), title: const Text('Get tools'), body: const MarketPage()),
          PaneItem(
            key: const ValueKey('projects'),
            icon: const Icon(WindowsIcons.folder),
            title: _PaneTitle('Projects', trailing: state.buildFolderBytes > 0 ? Muted(formatBytes(state.buildFolderBytes)) : null),
            body: const ProjectsPage(),
          ),
          if (emulatorCount > 0)
            PaneItem(
              key: const ValueKey('emulators'),
              icon: const Icon(WindowsIcons.cell_phone),
              title: _PaneTitle('Emulators', trailing: Muted('$emulatorCount')),
              body: const EmulatorsPage(),
            ),
          if (toolchains.isNotEmpty) _header('Toolchains'),
          ...toolchains.map(techItem),
          if (frameworks.isNotEmpty) _header('Frameworks'),
          ...frameworks.map(techItem),
        ],
        footerItems: [
          PaneItemSeparator(),
          PaneItem(
            key: const ValueKey('activity'),
            icon: const Icon(WindowsIcons.history),
            title: _PaneTitle('Activity', trailing: jobs.activeCount > 0 ? InfoBadge(source: Text('${jobs.activeCount}')) : null),
            body: const ActivityPage(),
          ),
          PaneItem(key: const ValueKey('settings'), icon: const Icon(WindowsIcons.settings), title: const Text('Settings'), body: const SettingsPage()),
        ],
      ),
    );
  }
}

/// Sidebar section header. fluent_ui 4.16 draws PaneItemHeader as an empty box
/// in the open pane, so this renders its own, hidden when the pane is icons-only.
NavigationPaneItem _header(String text) => PaneItemWidgetAdapter(
  key: ValueKey('header-$text'),
  applyPadding: false,
  child: Builder(
    builder: (context) {
      final mode = NavigationViewContext.of(context).displayMode;
      if (mode == PaneDisplayMode.compact || mode == PaneDisplayMode.top) return const SizedBox.shrink();
      final theme = FluentTheme.of(context);
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 12, 4),
        child: Text(
          text,
          maxLines: 1,
          style: theme.typography.caption?.copyWith(color: theme.resources.textFillColorSecondary, fontWeight: FontWeight.w600),
        ),
      );
    },
  ),
);

/// Pane item title with an optional trailing badge; ellipsizes when narrow.
class _PaneTitle extends StatelessWidget {
  const _PaneTitle(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.fade);
    if (trailing == null) return label;
    // While the pane animates it can be very narrow: drop the badge then.
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 80) return label;
        return Row(
          children: [
            Flexible(child: label),
            const Spacer(),
            Padding(padding: const EdgeInsetsDirectional.only(start: 6, end: 12), child: trailing),
          ],
        );
      },
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon();

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    // fluent_ui puts the title-bar icon flush against the window edge; inset it
    // so it lines up with the pane icons below, like native Windows 11 apps.
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 16),
      child: SizedBox(
        width: 16,
        height: 16,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (i, w) in [10.0, 14.0, 16.0].indexed)
              Container(
                width: w,
                height: 3.5,
                margin: EdgeInsets.only(top: i == 0 ? 0 : 1.5),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.55 + i * 0.2),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small status in the title bar: what the scanner is doing right now.
class _ScanStatus extends StatelessWidget {
  const _ScanStatus({required this.state, required this.jobs, required this.onOpenActivity});
  final AppState state;
  final JobQueue jobs;
  final VoidCallback onOpenActivity;

  @override
  Widget build(BuildContext context) {
    // Work you started comes first: "Cleaning up 3 items · step 2 of 6 · 1 more waiting".
    final job = jobs.current;
    if (job != null) {
      final waiting = jobs.activeCount - 1;
      final label = [
        job.title,
        if (job.totalSteps > 1) 'step ${job.step.clamp(1, job.totalSteps)} of ${job.totalSteps}',
        if (waiting > 0) '$waiting more waiting',
      ].join(' · ');
      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: HoverButton(
          onPressed: onOpenActivity,
          builder: (context, states) => Row(
            key: ValueKey('job-${job.id}'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: ProgressRing(strokeWidth: 2, value: job.totalSteps > 1 ? 100 * (job.step - 1).clamp(0, job.totalSteps) / job.totalSteps : null),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Muted(label, maxLines: 1)),
            ],
          ),
        ),
      );
    }
    final label = switch (state.phase) {
      ScanPhase.projects => 'Finding projects…',
      ScanPhase.techs => 'Detecting SDKs…',
      ScanPhase.sizes => state.measureTotal == 0 ? 'Checking sizes…' : 'Measuring sizes · ${state.measureDone} of ${state.measureTotal}',
      ScanPhase.idle => state.lastScan == null ? '' : 'Scanned ${timeAgo(state.lastScan).toLowerCase()}',
    };
    final busy = state.phase != ScanPhase.idle;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SmoothSwitcher(
        alignment: Alignment.centerRight,
        child: Row(
          key: ValueKey(label),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              SizedBox(
                width: 12,
                height: 12,
                // Fills up while sizes are measured; spins while scanning.
                child: ProgressRing(
                  strokeWidth: 2,
                  value: state.phase == ScanPhase.sizes && state.measureTotal > 0 ? 100 * state.measureDone / state.measureTotal : null,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Muted(label),
          ],
        ),
      ),
    );
  }
}
