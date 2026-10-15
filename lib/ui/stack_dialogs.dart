import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/stack_file.dart';
import '../core/techs/tech.dart';
import '../state/app_state.dart';
import 'widgets.dart';

const _types = [
  XTypeGroup(label: 'Stackyard stack', extensions: ['json']),
];

void _toast(BuildContext context, String title, String text, {bool error = false}) => displayInfoBar(
  context,
  alignment: Alignment.bottomRight,
  builder: (context, close) =>
      InfoBar(title: Text(title), content: Text(text), severity: error ? InfoBarSeverity.error : InfoBarSeverity.success, onClose: close),
);

/// Saves the toolchains on this machine to a file you can import elsewhere.
Future<void> exportStack(BuildContext context) async {
  final state = context.read<AppState>();
  final stack = StackFile.fromMachine({
    for (final t in state.techs)
      if (t.info.kind == TechKind.toolchain) t.id: t.snapshot,
  });
  final where = await getSaveLocation(suggestedName: 'my-stack.stackyard.json', acceptedTypeGroups: _types);
  if (where == null) return;
  try {
    await File(where.path).writeAsString(stack.encode());
    if (context.mounted) _toast(context, 'Stack saved', '${stack.items.length} items saved to ${where.path}.');
  } catch (e) {
    if (context.mounted) _toast(context, 'Couldn\'t save', '$e', error: true);
  }
}

/// Reads a stack file and offers to install whatever this machine is missing.
Future<void> importStack(BuildContext context) async {
  final file = await openFile(acceptedTypeGroups: _types);
  if (file == null || !context.mounted) return;
  final StackFile stack;
  try {
    stack = StackFile.decode(await file.readAsString());
  } on FormatException catch (e) {
    if (context.mounted) _toast(context, 'Couldn\'t open ${file.name}', e.message, error: true);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => ImportStackDialog(stack: stack),
  );
}

/// What an imported stack means for this machine, item by item.
class ImportStackDialog extends StatefulWidget {
  const ImportStackDialog({super.key, required this.stack});
  final StackFile stack;

  @override
  State<ImportStackDialog> createState() => _ImportStackDialogState();
}

class _Row {
  _Row(this.item, this.adapter, this.installed, this.plan);
  final StackItem item;
  final TechAdapter? adapter;
  final bool installed;
  final PlannedChange? plan;
  bool selected = true;
}

class _ImportStackDialogState extends State<ImportStackDialog> {
  late final List<_Row> _rows = () {
    final state = context.read<AppState>();
    return [
      for (final item in widget.stack.items)
        () {
          final adapter = state.adapters.where((a) => a.id == item.tech).firstOrNull;
          final installed = StackFile.isInstalled(item, state.tech(item.tech)?.snapshot);
          return _Row(item, adapter, installed, installed ? null : adapter?.planInstallFromStack(item));
        }(),
    ];
  }();

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final toInstall = _rows.where((r) => r.plan != null && r.selected).toList();
    final missing = _rows.where((r) => !r.installed).length;
    final byTech = <String, List<_Row>>{};
    for (final r in _rows) {
      byTech.putIfAbsent(r.adapter?.info.name ?? r.item.tech, () => []).add(r);
    }

    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
      title: const Text('Set up from a stack'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Muted(
            'From ${widget.stack.from}, saved ${timeAgo(widget.stack.exportedAt).toLowerCase()}. '
            '${missing == 0 ? 'Everything in it is already on this computer.' : '$missing of ${_rows.length} items aren\'t on this computer yet.'} '
            'Your current default versions stay as they are.',
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final MapEntry(key: tech, value: rows) in byTech.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 4),
                      child: Text(tech, style: theme.typography.bodyStrong),
                    ),
                    for (final r in rows) _line(context, r),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context)),
        FilledButton(
          onPressed: toInstall.isEmpty
              ? null
              : () {
                  final state = context.read<AppState>();
                  // One job each, so one failure doesn't stop the rest.
                  for (final r in toInstall) {
                    state.run(r.plan!);
                  }
                  Navigator.pop(context);
                },
          child: Text(toInstall.isEmpty ? 'Nothing to install' : 'Install ${toInstall.length}'),
        ),
      ],
    );
  }

  Widget _line(BuildContext context, _Row r) {
    final theme = FluentTheme.of(context);
    final r2 = theme.resources;
    final (status, color) = r.installed
        ? ('Already here', r2.systemFillColorSuccess)
        : r.plan != null
        ? ('Will install', theme.accentColor.defaultBrushFor(theme.brightness))
        : (r.adapter?.stackInstallHint ?? 'Not supported by this version of Stackyard.', r2.textFillColorSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: r.plan == null
                ? Icon(r.installed ? WindowsIcons.check_mark : WindowsIcons.blocked, size: 12, color: color)
                : Checkbox(checked: r.selected, onChanged: (v) => setState(() => r.selected = v ?? false)),
          ),
          Expanded(
            child: Text(
              r.item.global ? '${r.item.label}  (default there)' : r.item.label,
              style: theme.typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              status,
              textAlign: TextAlign.right,
              style: theme.typography.caption?.copyWith(color: color),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}
