import 'package:path/path.dart' as p;

import '../models.dart';
import '../sys.dart';
import '../techs/tech.dart';
import 'catalog.dart';

/// Versions the marketplace installed, shown on their tech's page like any other.
class MarketInstalls {
  /// Hidden details on the item ("_" keys aren't shown).
  static const toolKey = '_tool';
  static const scopeKey = '_env';

  static bool isMarket(InstalledItem i) => i.details.containsKey(toolKey);

  /// Variables that tools point into their folder; cleared when it's removed.
  static const homeVars = ['JAVA_HOME', 'GOROOT', 'DOTNET_ROOT', 'GRADLE_HOME', 'RUSTUP_HOME', 'CARGO_HOME'];

  /// The item for one install record. It's the default when its program is the one PATH finds.
  static InstalledItem item(Map<String, String> record, MarketTool tool) {
    final dest = record['dest']!;
    final found = tool.binary == null ? null : Sys.which(tool.binary!);
    final active = found != null && p.isWithin(p.normalize(dest).toLowerCase(), p.normalize(found).toLowerCase());
    return InstalledItem(
      id: 'market:${p.normalize(dest).toLowerCase()}',
      version: record['version']!,
      path: dest,
      isGlobal: active,
      installedAt: Sys.modified(dest),
      details: {'Source': 'Installed by Stackyard', toolKey: tool.id, scopeKey: record['scope'] ?? 'user'},
    );
  }

  /// Points PATH (and JAVA_HOME etc.) at this version.
  static PlannedChange planDefault(InstalledItem item, MarketTool tool, String installRoot) => PlannedChange(
    title: 'Make ${tool.name} ${item.version} the default',
    env: tool.env(item.path, p.join(installRoot, tool.id)),
    envForEveryone: item.details[scopeKey] == 'machine',
    envBlock: tool.id,
  );

  /// Removes the folder and anything in the environment that points into it.
  static PlannedChange planRemove(InstalledItem item, String name) => PlannedChange(
    title: 'Remove $name ${item.version}',
    recycle: [item.path],
    env: [EnvChange.dropPathUnder(item.path), for (final v in homeVars) EnvChange.removeIfUnder(v, item.path)],
    envForEveryone: item.details[scopeKey] == 'machine',
    envBlock: item.details[toolKey],
  );
}

/// The sidebar page for a tool that only the marketplace knows (Go, Rust, Deno, Bun…).
class MarketOnlyTech extends TechAdapter {
  MarketOnlyTech(this.tool);
  final MarketTool tool;

  @override
  TechInfo get info => tool.look;

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async => null;
}
