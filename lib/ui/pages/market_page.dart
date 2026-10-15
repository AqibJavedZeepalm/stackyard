import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/market/catalog.dart';
import '../../core/models.dart';
import '../../core/sys.dart';
import '../../state/app_state.dart';
import '../../state/jobs.dart';
import '../motion.dart';
import '../widgets.dart';

/// Version lists, fetched once per run (they're big and change rarely).
final _versionCache = <String, Future<List<MarketVersion>>>{};

/// Which versions of [tool] this computer has, from the last scan and the marketplace's own records.
Future<Set<String>> installedVersions(AppState state, MarketTool tool) async {
  if (tool.viaNpm) {
    final globals = await state.npmGlobals();
    final pkg = tool is NpmCliMarket ? tool.package : tool.id;
    return {?globals[pkg]};
  }
  final out = <String>{
    for (final r in state.settings.installs)
      if (r['tool'] == tool.id) r['version']!,
  };
  final tech = tool.techId == null || tool.id == 'android-cmdline-tools' ? null : state.tech(tool.techId!);
  for (final i in tech?.snapshot.items ?? const <InstalledItem>[]) {
    if (!i.isCache && !i.isBroken) out.add(i.version);
  }
  return out;
}

/// "17.0.20+101" and "17.0.20" are the same JDK for this purpose.
bool _sameVersion(String a, String b) => a.split('+').first == b.split('+').first;

/// Browse every tool, pick any version, install it where you want.
class MarketPage extends StatefulWidget {
  const MarketPage({super.key});

  @override
  State<MarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends State<MarketPage> {
  String _query = '';
  MarketCategory? _category;
  MarketTool? _open;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (_open != null) {
      return _ToolDetail(key: ValueKey(_open!.id), tool: _open!, onBack: () => setState(() => _open = null), onOpen: (t) => setState(() => _open = t));
    }
    final q = _query.toLowerCase();
    final tools = [
      for (final t in state.catalog)
        if ((_category == null || t.category == _category) &&
            (q.isEmpty || t.name.toLowerCase().contains(q) || t.description.toLowerCase().contains(q) || t.id.contains(q)))
          t,
    ];

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        title: const Text('Get tools'),
        commandBar: SizedBox(
          width: 260,
          child: TextBox(
            placeholder: 'Search tools',
            prefix: const Padding(padding: EdgeInsets.only(left: 10), child: Icon(WindowsIcons.search, size: 12)),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      ),
      children: [
        Muted(
          'Official downloads, every version, checked against the publisher\'s hash. Installed to ${state.settings.installRoot} unless you choose another folder.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Chip(label: 'All', selected: _category == null, onTap: () => setState(() => _category = null)),
            for (final c in MarketCategory.values)
              if (state.catalog.any((t) => t.category == c)) _Chip(label: c.label, selected: _category == c, onTap: () => setState(() => _category = c)),
          ],
        ),
        const SizedBox(height: 16),
        if (tools.isEmpty)
          const Callout(icon: WindowsIcons.search, text: 'No tool matches that search.')
        else
          LayoutBuilder(
            builder: (context, c) {
              const gap = 12.0;
              final cols = (c.maxWidth / 280).floor().clamp(1, 5);
              final width = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final (i, t) in tools.indexed)
                    Appear(
                      index: i ~/ cols,
                      child: SizedBox(
                        width: width,
                        child: _ToolCard(tool: t, onTap: () => setState(() => _open = t)),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    return HoverButton(
      onPressed: onTap,
      builder: (context, states) => AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? theme.accentColor.defaultBrushFor(theme.brightness)
              : states.isHovered
              ? r.subtleFillColorSecondary
              : r.subtleFillColorTransparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? Colors.transparent : r.controlStrokeColorDefault),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, color: selected ? (theme.brightness == Brightness.dark ? Colors.black : Colors.white) : r.textFillColorPrimary),
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool, required this.onTap});
  final MarketTool tool;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final state = context.watch<AppState>();
    return SurfaceCard(
      onPressed: onTap,
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        height: 116,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TechBadge(tool.look, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tool.name, style: theme.typography.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Muted(tool.category.label, maxLines: 1),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: Muted(tool.description, maxLines: 2)),
            FutureBuilder(
              future: installedVersions(state, tool),
              builder: (context, snap) {
                final versions = snap.data ?? const <String>{};
                if (versions.isEmpty) return Muted(tool.viaNpm ? 'Installs with npm' : 'Not installed');
                final sorted = versions.toList()..sort();
                return Row(
                  children: [
                    Icon(WindowsIcons.completed, size: 12, color: theme.resources.systemFillColorSuccess),
                    const SizedBox(width: 6),
                    Expanded(child: Muted('Installed · ${sorted.length > 2 ? '${sorted.length} versions' : sorted.join(', ')}', maxLines: 1)),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolDetail extends StatefulWidget {
  const _ToolDetail({super.key, required this.tool, required this.onBack, required this.onOpen});
  final MarketTool tool;
  final VoidCallback onBack;
  final ValueChanged<MarketTool> onOpen;

  @override
  State<_ToolDetail> createState() => _ToolDetailState();
}

class _ToolDetailState extends State<_ToolDetail> {
  String _filter = '';
  bool _previews = false;
  int _shown = 60;

  Future<List<MarketVersion>> get _versions => _versionCache[widget.tool.id] ??= widget.tool.versions();

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final state = context.watch<AppState>();
    final jobs = context.watch<JobQueue>();
    final tool = widget.tool;
    final needsNode = tool.viaNpm && Sys.which('npm') == null;

    return ScaffoldPage.scrollable(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 36),
      header: PageHeader(
        padding: 36,
        leading: Padding(
          padding: const EdgeInsets.only(left: 24, right: 8),
          child: IconButton(icon: const Icon(WindowsIcons.back, size: 14), onPressed: widget.onBack),
        ),
        title: Row(
          children: [
            TechBadge(tool.look, size: 30),
            const SizedBox(width: 14),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tool.name, style: theme.typography.title),
                  Muted(tool.description, maxLines: 2),
                ],
              ),
            ),
          ],
        ),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(WindowsIcons.open_in_new_window),
              label: const Text('Website'),
              onPressed: () => launchUrl(Uri.parse(tool.homepage)),
            ),
          ],
        ),
      ),
      children: [
        if (needsNode)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Callout(
              icon: WindowsIcons.warning,
              color: theme.resources.systemFillColorCaution,
              text: '${tool.name} installs with npm, which comes with Node.js. Install Node.js first.',
              action: FilledButton(onPressed: () => widget.onOpen(state.marketTool('node')!), child: const Text('Get Node.js')),
            ),
          ),
        Row(
          children: [
            SizedBox(
              width: 240,
              child: TextBox(placeholder: 'Filter versions', onChanged: (v) => setState(() => _filter = v)),
            ),
            const SizedBox(width: 16),
            ToggleSwitch(checked: _previews, onChanged: (v) => setState(() => _previews = v), content: const Text('Include previews')),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder(
          future: Future.wait([_versions, installedVersions(state, tool)]),
          builder: (context, snap) {
            if (snap.hasError) {
              return Callout(
                icon: WindowsIcons.error,
                color: theme.resources.systemFillColorCritical,
                text: 'Couldn\'t load the versions. Check your internet connection.',
                action: Button(onPressed: () => setState(() => _versionCache.remove(tool.id)), child: const Text('Try again')),
              );
            }
            if (!snap.hasData) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: BusyLabel('Loading versions from ${Uri.parse(tool.homepage).host}…', muted: true),
              );
            }
            final all = snap.data![0] as List<MarketVersion>;
            final installed = snap.data![1] as Set<String>;
            final list = [
              for (final v in all)
                if ((_previews || v.stable) && (_filter.isEmpty || v.version.contains(_filter))) v,
            ];
            if (list.isEmpty) return const Callout(icon: WindowsIcons.search, text: 'No version matches.');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionTitle('Versions', top: 0, trailing: Muted('${list.length}')),
                GroupCard(
                  children: [
                    for (final v in list.take(_shown))
                      _VersionLine(
                        tool: tool,
                        version: v,
                        installed: installed.any((i) => _sameVersion(i, v.version)),
                        busy: jobs.isBusy('Install ${tool.name} ${v.version}'),
                        enabled: !needsNode,
                      ),
                  ],
                ),
                if (list.length > _shown)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: HyperlinkButton(onPressed: () => setState(() => _shown = list.length), child: Text('Show all ${list.length}')),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _VersionLine extends StatelessWidget {
  const _VersionLine({required this.tool, required this.version, required this.installed, required this.busy, required this.enabled});
  final MarketTool tool;
  final MarketVersion version;
  final bool installed;
  final bool busy;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final r = theme.resources;
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final d = version.date;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          SizedBox(
            width: 170,
            child: Text(version.version, style: theme.typography.body, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (version.lts) ...[Pill(label: 'LTS', color: accent), const SizedBox(width: 8)],
          if (version.channel != null && version.channel!.isNotEmpty && version.channel != 'LTS' && !version.channel!.startsWith('LTS '))
            Muted(version.channel!)
          else if (version.channel?.startsWith('LTS ') ?? false)
            Muted(version.channel!.substring(4)),
          const Spacer(),
          if (d != null) Muted('${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'),
          const SizedBox(width: 16),
          SizedBox(
            width: 110,
            child: Align(
              alignment: Alignment.centerRight,
              child: installed
                  ? Pill(label: 'Installed', color: r.systemFillColorSuccess)
                  : busy
                  ? const BusyLabel('Installing…', muted: true)
                  : Button(
                      onPressed: enabled
                          ? () => showDialog<void>(
                              context: context,
                              builder: (_) => MarketInstallDialog(tool: tool, version: version),
                            )
                          : null,
                      child: const Text('Install'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks where to install and which environment variables to set, then installs.
class MarketInstallDialog extends StatefulWidget {
  const MarketInstallDialog({super.key, required this.tool, required this.version});
  final MarketTool tool;
  final MarketVersion version;

  @override
  State<MarketInstallDialog> createState() => _MarketInstallDialogState();
}

class _MarketInstallDialogState extends State<MarketInstallDialog> {
  late final AppState _state = context.read<AppState>();
  late final String _root = p.join(_state.settings.installRoot, widget.tool.id);
  late final TextEditingController _dest = TextEditingController(
    text: widget.tool is AndroidToolsMarket ? (widget.tool as AndroidToolsMarket).destFor(widget.version) : p.join(_root, widget.version.version),
  );
  late Future<MarketPlan?> _plan = widget.tool.plan(widget.version, _dest.text);
  final _off = <int>{};
  bool _forEveryone = false;
  bool _starting = false;

  /// Folders in the machine-wide PATH that already hold this tool's program.
  late final Future<String?> _systemConflict = () async {
    final binary = widget.tool.binary;
    if (!Sys.isWindows || binary == null) return null;
    final out = await Sys.run('reg.exe', ['query', r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', '/v', 'Path']) ?? '';
    final value = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.*)').firstMatch(out)?[1] ?? '';
    for (final entry in value.split(';')) {
      final dir = entry.trim().replaceAllMapped(RegExp(r'%([^%]+)%'), (m) => Sys.env[m[1]!] ?? m[0]!);
      if (dir.isEmpty) continue;
      for (final ext in ['.exe', '.cmd', '.bat']) {
        if (Sys.fileExists(p.join(dir, '$binary$ext'))) return dir;
      }
    }
    return null;
  }();

  @override
  void dispose() {
    _dest.dispose();
    super.dispose();
  }

  String? get _destProblem {
    final dest = _dest.text.trim();
    if (dest.isEmpty) return 'Pick a folder.';
    if (!p.isAbsolute(dest)) return 'Use a full path, like ${p.join(Sys.home, 'sdks')}.';
    try {
      if (Directory(dest).existsSync() && Directory(dest).listSync().isNotEmpty) return 'That folder isn\'t empty. Pick a new or empty folder.';
    } catch (_) {
      return 'Stackyard can\'t write to that folder.';
    }
    return null;
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath(
      initialDirectory: Directory(_state.settings.installRoot).existsSync() ? _state.settings.installRoot : null,
      confirmButtonText: 'Install here',
    );
    if (dir == null) return;
    // A folder that already has things in it gets a subfolder for this version.
    final pick = Directory(dir).listSync().isEmpty ? dir : p.join(dir, '${widget.tool.id}-${widget.version.version}');
    setState(() {
      _dest.text = pick;
      _plan = widget.tool.plan(widget.version, pick);
    });
  }

  Future<void> _install() async {
    setState(() => _starting = true);
    final dest = _dest.text.trim();
    final plan = await widget.tool.plan(widget.version, dest);
    if (plan == null || !mounted) return;
    final env = widget.tool.env(plan.fixedLocation ?? dest, _root);
    final chosen = [
      for (final (i, e) in env.indexed)
        if (!_off.contains(i)) e,
    ];
    final change = PlannedChange(
      title: 'Install ${widget.tool.name} ${widget.version.version}',
      downloads: [?plan.download],
      commands: plan.commands,
      env: chosen,
      envForEveryone: _forEveryone,
      envBlock: widget.tool.id,
      record: widget.tool.viaNpm
          ? null
          : {'tool': widget.tool.id, 'version': widget.version.version, 'dest': plan.fixedLocation ?? dest, 'scope': _forEveryone ? 'machine' : 'user'},
      warning: plan.note,
    );
    _state.run(change);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final tool = widget.tool;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 600),
      title: Text('Install ${tool.name} ${widget.version.version}'),
      content: FutureBuilder(
        future: _plan,
        builder: (context, snap) {
          if (!snap.hasData && snap.connectionState != ConnectionState.done) return const BusyLabel('Getting the download ready…', muted: true);
          final plan = snap.data;
          if (plan == null) {
            return Text(
              tool.viaNpm
                  ? '${tool.name} installs with npm, which isn\'t on this computer. Install Node.js first.'
                  : 'This version isn\'t available for this computer.',
            );
          }
          final env = tool.env(plan.fixedLocation ?? _dest.text.trim(), _root);
          final d = plan.download;
          final verified = d != null && (d.sha256 != null || d.sha512 != null || d.sha1 != null || d.checksumUrl != null);
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (d != null)
                  Muted(
                    'Downloads from ${Uri.parse(d.url).host}${d.size == null ? '' : ' (${formatBytes(d.size!)})'}'
                    '${verified ? ', checked against the publisher\'s hash before it\'s installed.' : '.'}',
                  )
                else
                  Muted(plan.commands.map((c) => c.display).join('\n')),
                if (!tool.viaNpm) ...[
                  const SizedBox(height: 16),
                  Text('Install to', style: theme.typography.bodyStrong),
                  const SizedBox(height: 6),
                  if (plan.fixedLocation != null)
                    Muted(plan.fixedLocation!)
                  else
                    Row(
                      children: [
                        Expanded(
                          child: TextBox(controller: _dest, onChanged: (_) => setState(() {})),
                        ),
                        const SizedBox(width: 8),
                        Button(onPressed: _browse, child: const Text('Browse…')),
                      ],
                    ),
                  if (plan.fixedLocation == null && _destProblem != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_destProblem!, style: TextStyle(color: theme.resources.systemFillColorCritical)),
                    ),
                ],
                if (env.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text('Environment variables', style: theme.typography.bodyStrong),
                  const SizedBox(height: 2),
                  Muted(
                    Sys.isWindows
                        ? 'So terminals and editors find this version. Untick anything you\'d rather set yourself.'
                        : 'Saved in ~/.zprofile (and ~/.bash_profile if you use bash). Open a new terminal afterwards.',
                  ),
                  const SizedBox(height: 8),
                  for (final (i, e) in env.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(checked: !_off.contains(i), onChanged: (v) => setState(() => v == true ? _off.remove(i) : _off.add(i))),
                          const SizedBox(width: 10),
                          Expanded(child: Text(e.describe)),
                        ],
                      ),
                    ),
                  if (Sys.isWindows) ...[
                    const SizedBox(height: 8),
                    RadioGroup<bool>(
                      groupValue: _forEveryone,
                      onChanged: (v) => setState(() => _forEveryone = v ?? _forEveryone),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RadioButton<bool>(value: false, content: Text('Just for me')),
                          SizedBox(height: 6),
                          RadioButton<bool>(value: true, content: Text('Everyone on this PC (asks for admin)')),
                        ],
                      ),
                    ),
                    FutureBuilder(
                      future: _systemConflict,
                      builder: (context, c) => c.data == null || _forEveryone
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: InfoBar(
                                title: const Text('Another version comes first'),
                                content: Text(
                                  'Windows reads the system PATH before yours, and it already has ${tool.binary} in ${c.data}. '
                                  'Choose "Everyone on this PC" so this version is the one that runs.',
                                ),
                                severity: InfoBarSeverity.warning,
                                isLong: true,
                              ),
                            ),
                    ),
                  ],
                ],
                if (plan.note != null) ...[const SizedBox(height: 12), Muted(plan.note!)],
              ],
            ),
          );
        },
      ),
      actions: [
        Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(context)),
        FutureBuilder(
          future: _plan,
          builder: (context, snap) {
            final ok = snap.data != null && (snap.data!.fixedLocation != null || tool.viaNpm || _destProblem == null) && !_starting;
            return FilledButton(onPressed: ok ? _install : null, child: Text(_starting ? 'Starting…' : 'Install'));
          },
        ),
      ],
    );
  }
}
