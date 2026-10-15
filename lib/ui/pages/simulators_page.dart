import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/sys.dart';
import '../../core/techs/xcode_tech.dart';
import '../../state/app_state.dart';
import '../../state/jobs.dart';
import '../dialogs.dart';
import '../motion.dart';
import '../widgets.dart';

/// Xcode's simulators (macOS): what each one is, how big, when it last ran,
/// and the everyday actions (start, shut down, erase, delete).
class SimulatorsPage extends StatefulWidget {
  const SimulatorsPage({super.key});

  @override
  State<SimulatorsPage> createState() => _SimulatorsPageState();
}

class _SimulatorsPageState extends State<SimulatorsPage> {
  // Simulators start and stop outside Stackyard: re-check which are running.
  Set<String> _booted = const {};
  late final Timer _tick = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());

  Future<void> _refresh() async {
    final booted = await XcodeTech.booted();
    if (mounted) setState(() => _booted = booted);
  }

  @override
  void initState() {
    super.initState();
    _tick;
    _refresh();
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final xcode = state.tech('xcode');
    final sims = [
      for (final i in xcode?.snapshot.items ?? const <InstalledItem>[])
        if (i.group == XcodeTech.simulatorsGroup && !state.removedIds.contains(i.id)) i,
    ]..sort((a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(a.lastUsedAt ?? DateTime(0)));
    final total = sims.fold<int>(0, (s, e) => s + (e.sizeBytes ?? 0));
    final broken = sims.where((s) => s.isBroken).length;

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        title: const Text('Simulators'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(icon: const Icon(WindowsIcons.refresh), label: const Text('Rescan'), onPressed: state.scanning ? null : () => state.scan()),
          ],
        ),
      ),
      children: [
        Muted(sims.isEmpty ? 'No simulators on this Mac.' : '${sims.length} simulator${sims.length == 1 ? '' : 's'} · ${formatBytes(total)}'),
        if (broken > 0) ...[
          const SizedBox(height: 12),
          Callout(
            icon: WindowsIcons.warning,
            color: FluentTheme.of(context).resources.systemFillColorCaution,
            text: '$broken simulator${broken == 1 ? '' : 's'} can\'t start because ${broken == 1 ? 'its runtime is' : 'their runtimes are'} gone.',
            action: Button(
              onPressed: () async {
                final chosen = await confirmRemoval(context, XcodeTech.planDeleteUnavailable());
                if (chosen != null && context.mounted) {
                  context.read<AppState>().run(chosen, removesItemIds: [for (final s in sims) if (s.isBroken) s.id]);
                }
              },
              child: const Text('Delete them'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final (i, sim) in sims.indexed)
          Appear(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SimulatorCard(
                key: ValueKey(sim.id),
                sim: sim,
                running: _booted.contains(XcodeTech.udid(sim)),
                onChanged: _refresh,
              ),
            ),
          ),
      ],
    );
  }
}

class _SimulatorCard extends StatefulWidget {
  const _SimulatorCard({super.key, required this.sim, required this.running, required this.onChanged});
  final InstalledItem sim;
  final bool running;
  final VoidCallback onChanged;

  @override
  State<_SimulatorCard> createState() => _SimulatorCardState();
}

class _SimulatorCardState extends State<_SimulatorCard> {
  /// Booting or shutting down takes a few seconds.
  bool _switching = false;

  Future<void> _switch(Future<void> Function() action) async {
    setState(() => _switching = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _switching = false);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    final sim = widget.sim;
    final running = widget.running;
    // A job (erase, delete…) is working on this simulator right now.
    final working = context.watch<JobQueue>().touches(id: sim.id, path: sim.path);
    final blocked = running || working || _switching;
    final busyReason = running
        ? 'Shut it down first'
        : working || _switching
        ? 'Busy, wait a moment'
        : null;

    Future<void> run(PlannedChange? plan, {bool remove = false}) async {
      if (plan == null) return;
      final chosen = await confirmRemoval(context, plan);
      if (chosen != null && context.mounted) {
        context.read<AppState>().run(chosen, removesItemIds: remove ? [sim.id] : const []);
      }
    }

    final facts = [sim.details['Device'], sim.details['OS']].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(WindowsIcons.cell_phone, size: 22, color: sim.isBroken ? r.systemFillColorCritical : r.textFillColorSecondary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(sim.title, style: theme.typography.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (running) ...[const SizedBox(width: 8), Pill(label: 'Running', color: r.systemFillColorSuccess)],
                        if (working || _switching) ...[const SizedBox(width: 10), const BusyLabel('Working…', muted: true)],
                      ],
                    ),
                    Muted(facts, maxLines: 1),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(sim.sizeBytes == null ? '…' : formatBytes(sim.sizeBytes!), style: theme.typography.body),
                  Muted('Started ${sim.details['Last started']?.toLowerCase() ?? 'never'}'),
                ],
              ),
            ],
          ),
          if (sim.details['Problem'] case final problem?) ...[
            const SizedBox(height: 10),
            Callout(icon: WindowsIcons.warning, color: r.systemFillColorCaution, text: problem),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (running)
                FilledButton(onPressed: _switching ? null : () => _switch(() => XcodeTech.shutDown(sim)), child: const Text('Shut down'))
              else
                FilledButton(
                  onPressed: sim.isBroken || working || _switching ? null : () => _switch(() => XcodeTech.start(sim)),
                  child: const Text('Start'),
                ),
              Tooltip(
                message: busyReason ?? 'Erase apps and data; it starts like new',
                child: Button(onPressed: blocked || sim.isBroken ? null : () => run(XcodeTech.planErase(sim)), child: const Text('Erase')),
              ),
              Tooltip(
                message: busyReason ?? 'Delete the simulator and everything in it',
                child: Button(
                  style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(blocked ? null : r.systemFillColorCritical)),
                  onPressed: blocked ? null : () => run(context.read<AppState>().tech('xcode')!.adapter.planRemove(sim), remove: true),
                  child: const Text('Delete'),
                ),
              ),
              if (Sys.dirExists(sim.path))
                Button(onPressed: () => Sys.reveal(sim.path), child: Text('Show in ${Sys.fileManager}')),
            ],
          ),
        ],
      ),
    );
  }
}
