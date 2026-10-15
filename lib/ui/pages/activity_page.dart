import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../state/jobs.dart';
import '../motion.dart';
import '../widgets.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<JobQueue>();
    final theme = FluentTheme.of(context);
    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 36),
      header: PageHeader(
        padding: 36,
        title: const Text('Activity'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(WindowsIcons.clear),
              label: const Text('Clear finished'),
              onPressed: queue.jobs.any((j) => j.status == JobStatus.done || j.status == JobStatus.failed) ? queue.clearFinished : null,
            ),
          ],
        ),
      ),
      children: [
        if (queue.jobs.isEmpty)
          Appear(
            child: Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Column(
                children: [
                  Icon(WindowsIcons.history, size: 32, color: theme.resources.textFillColorTertiary),
                  const SizedBox(height: 12),
                  Text('No activity yet', style: theme.typography.subtitle),
                  const SizedBox(height: 4),
                  const Muted('Installs, switches and cleanups show up here with their full output.'),
                ],
              ),
            ),
          ),
        for (final (i, job) in queue.jobs.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Appear(
              key: ValueKey(job.id),
              index: i,
              child: _JobCard(job: job),
            ),
          ),
      ],
    );
  }
}

class _JobCard extends StatefulWidget {
  const _JobCard({required this.job});
  final Job job;

  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool? _open;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Keep the elapsed time moving while the job runs, even with no output.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.job.status == JobStatus.running) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    final job = widget.job;
    final open = _open ?? (job.status == JobStatus.running || job.status == JobStatus.failed);
    final (Widget icon, String status) = switch (job.status) {
      JobStatus.queued => (Icon(WindowsIcons.history, size: 16, color: r.textFillColorSecondary), 'Waiting'),
      JobStatus.running => (
        const SizedBox(width: 16, height: 16, child: ProgressRing(strokeWidth: 2.5)),
        'Step ${job.step} of ${job.totalSteps}${_quietFor(job)}',
      ),
      JobStatus.done => (Icon(WindowsIcons.completed, size: 16, color: r.systemFillColorSuccess), 'Done'),
      JobStatus.failed => (Icon(WindowsIcons.error, size: 16, color: r.systemFillColorCritical), job.error ?? 'Failed'),
    };
    final elapsed = job.startedAt == null ? null : (job.finishedAt ?? DateTime.now()).difference(job.startedAt!);

    return SurfaceCard(
      padding: EdgeInsets.zero,
      onPressed: () => setState(() => _open = !open),
      child: AnimatedSize(
        duration: Motion.of(context, Motion.normal),
        curve: Motion.move,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  SmoothSwitcher(
                    alignment: Alignment.center,
                    child: KeyedSubtree(key: ValueKey(job.status), child: icon),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(job.title, style: theme.typography.bodyStrong),
                        Muted(status, maxLines: 2),
                      ],
                    ),
                  ),
                  if (job.status == JobStatus.running || job.status == JobStatus.queued) ...[
                    Button(child: const Text('Cancel'), onPressed: () => context.read<JobQueue>().cancel(job)),
                    const SizedBox(width: 12),
                  ],
                  if (elapsed != null) Muted(_elapsed(elapsed)),
                  const SizedBox(width: 12),
                  AnimatedRotation(turns: open ? 0.5 : 0, duration: Motion.of(context, Motion.normal), child: const Icon(WindowsIcons.chevron_down, size: 10)),
                ],
              ),
            ),
            if (job.status == JobStatus.running)
              ProgressBar(value: job.totalSteps <= 1 ? null : 100 * (job.step - 1).clamp(0, job.totalSteps) / job.totalSteps),
            if (open && job.log.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: r.subtleFillColorSecondary, borderRadius: BorderRadius.circular(4)),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    job.log.join('\n'),
                    style: TextStyle(fontFamily: 'Cascadia Mono', fontFamilyFallback: const ['Consolas'], fontSize: 12, color: r.textFillColorPrimary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _elapsed(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';

/// " · no output for 3 min" when a running job has gone quiet.
String _quietFor(Job job) {
  final since = job.lastOutputAt ?? job.startedAt;
  if (since == null) return '';
  final quiet = DateTime.now().difference(since);
  return quiet.inSeconds >= 60 ? ' · no output for ${quiet.inMinutes} min' : '';
}
