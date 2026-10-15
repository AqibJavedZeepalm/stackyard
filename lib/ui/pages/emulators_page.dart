import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/sys.dart';
import '../../core/techs/android_tech.dart';
import '../../state/app_state.dart';
import '../../state/jobs.dart';
import '../dialogs.dart';
import '../motion.dart';
import '../widgets.dart';

/// Android emulators: what each one is, how big, when it last ran, and the
/// everyday actions (start, cold boot, wipe, delete snapshots, delete).
class EmulatorsPage extends StatefulWidget {
  const EmulatorsPage({super.key});

  @override
  State<EmulatorsPage> createState() => _EmulatorsPageState();
}

class _EmulatorsPageState extends State<EmulatorsPage> {
  // Emulators start and stop outside Stackyard: re-check which are running.
  late final Timer _tick = Timer.periodic(const Duration(seconds: 3), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final android = state.tech('android');
    final adapter = android?.adapter as AndroidTech?;
    final emulators = [
      for (final i in android?.snapshot.items ?? const <InstalledItem>[])
        if (i.group == 'Emulators' && !state.removedIds.contains(i.id)) i,
    ]..sort((a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(a.lastUsedAt ?? DateTime(0)));
    final total = emulators.fold<int>(0, (s, e) => s + (e.sizeBytes ?? 0));

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        title: const Text('Emulators'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(icon: const Icon(WindowsIcons.refresh), label: const Text('Rescan'), onPressed: state.scanning ? null : () => state.scan()),
          ],
        ),
      ),
      children: [
        Muted(
          emulators.isEmpty
              ? 'No Android emulators on this computer.'
              : '${emulators.length} emulator${emulators.length == 1 ? '' : 's'} · ${formatBytes(total)}'
                    '${adapter?.emulatorExe == null ? ' · the Android Emulator isn\'t installed, so they can\'t be started from here' : ''}',
        ),
        const SizedBox(height: 12),
        for (final (i, avd) in emulators.indexed)
          Appear(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _EmulatorCard(key: ValueKey(avd.id), avd: avd, adapter: adapter!),
            ),
          ),
      ],
    );
  }
}

class _EmulatorCard extends StatefulWidget {
  const _EmulatorCard({super.key, required this.avd, required this.adapter});
  final InstalledItem avd;
  final AndroidTech adapter;

  @override
  State<_EmulatorCard> createState() => _EmulatorCardState();
}

class _EmulatorCardState extends State<_EmulatorCard> {
  /// What's inside, measured once: saved snapshots and user data.
  late final Future<(int, int)> _breakdown = () async {
    final snapshots = await Sys.dirSize(AndroidTech.snapshotsDir(widget.avd));
    var data = 0;
    for (final f in AndroidTech.userDataFiles(widget.avd)) {
      if (f != AndroidTech.snapshotsDir(widget.avd)) data += await Sys.dirSize(f);
    }
    return (snapshots, data);
  }();

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    final avd = widget.avd;
    final adapter = widget.adapter;
    final running = AndroidTech.isRunning(avd);
    // A job (wipe, delete…) is working on this emulator right now.
    final working = context.watch<JobQueue>().touches(id: avd.id, path: avd.path);
    final blocked = running || working;
    final busyReason = running
        ? 'Close the emulator first'
        : working
        ? 'Busy, wait a moment'
        : null;
    final canStart = adapter.emulatorExe != null && !avd.isBroken && !blocked;

    Future<void> run(PlannedChange? plan, {bool remove = false}) async {
      if (plan == null) return;
      final chosen = await confirmRemoval(context, plan);
      if (chosen != null && context.mounted) {
        context.read<AppState>().run(chosen, removesItemIds: remove ? [avd.id] : const []);
      }
    }

    final facts = [avd.details['Device'], avd.details['Android'], avd.details['Image']].whereType<String>().join(' · ');
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(WindowsIcons.cell_phone, size: 22, color: avd.isBroken ? r.systemFillColorCritical : r.textFillColorSecondary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(avd.title, style: theme.typography.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (running) ...[const SizedBox(width: 8), Pill(label: 'Running', color: r.systemFillColorSuccess)],
                        if (working) ...[const SizedBox(width: 10), const BusyLabel('Working…', muted: true)],
                      ],
                    ),
                    Muted(facts.isEmpty ? (avd.details['System image'] ?? '') : facts, maxLines: 1),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(avd.sizeBytes == null ? '…' : formatBytes(avd.sizeBytes!), style: theme.typography.body),
                  Muted('Started ${avd.details['Last started']?.toLowerCase() ?? 'never'}'),
                ],
              ),
            ],
          ),
          if (avd.details['Problem'] case final problem?) ...[
            const SizedBox(height: 10),
            Callout(icon: WindowsIcons.warning, color: r.systemFillColorCaution, text: problem),
          ],
          const SizedBox(height: 10),
          FutureBuilder(
            future: _breakdown,
            builder: (context, snap) => Muted(snap.data == null ? ' ' : 'Snapshots ${formatBytes(snap.data!.$1)} · Data ${formatBytes(snap.data!.$2)}'),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: canStart ? () => adapter.startEmulator(avd) : null, child: const Text('Start')),
              Tooltip(
                message: 'Start without the saved snapshot, like turning a phone off and on',
                child: Button(onPressed: canStart ? () => adapter.startEmulator(avd, cold: true) : null, child: const Text('Cold boot')),
              ),
              Tooltip(
                message: busyReason ?? 'Erase apps and data; it starts like new',
                child: Button(onPressed: blocked ? null : () => run(adapter.planWipe(avd)), child: const Text('Wipe data')),
              ),
              Tooltip(
                message: busyReason ?? 'Free the space used by saved states',
                child: Button(
                  onPressed: blocked || adapter.planDeleteSnapshots(avd) == null ? null : () => run(adapter.planDeleteSnapshots(avd)),
                  child: const Text('Delete snapshots'),
                ),
              ),
              Tooltip(
                message: busyReason ?? 'Move the whole emulator to the ${Sys.trashName}',
                child: Button(
                  style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(blocked ? null : r.systemFillColorCritical)),
                  onPressed: blocked ? null : () => run(adapter.planRemove(avd), remove: true),
                  child: const Text('Delete'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
