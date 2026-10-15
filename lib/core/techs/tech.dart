import '../market/installed.dart';
import '../models.dart';
import '../stack_file.dart';

/// Shared state for one scan, passed to every adapter in order.
class ScanContext {
  ScanContext(this.projects);

  final List<Project> projects;

  /// Flutter SDK folder each Flutter project resolves to (project path -> sdk).
  final Map<String, String> flutterSdkForProject = {};
}

/// Knows how to find, link and manage one tech.
///
/// To add a tech: subclass this, then register it in `registry.dart`.
abstract class TechAdapter {
  TechInfo get info;
  String get id => info.id;

  /// Techs whose detect() must finish first (they fill the shared ScanContext).
  /// Everything else is detected in parallel.
  List<String> get dependsOn => const [];

  /// Returns null when the tech isn't on this machine (no sidebar tile).
  Future<TechSnapshot?> detect(ScanContext ctx);

  /// Which version a project uses, for the projects table.
  String? projectVersion(Project project) => project.pins[id]?.raw;

  /// Newest stable version upstream. Network; called after the scan.
  Future<String?> latestVersion() async => null;

  /// Versions you can install. Network.
  Future<List<VersionOption>> availableVersions() async => [];

  bool get canInstall => false;
  PlannedChange? planInstall(String version) => null;

  /// Installs one item from an imported stack file; null when this machine can't.
  PlannedChange? planInstallFromStack(StackItem item) => item.kind == 'version' && canInstall ? planInstall(item.version) : null;

  /// Why [planInstallFromStack] can't install here, in a few words.
  String get stackInstallHint => 'Stackyard can\'t install ${info.name} on this computer yet.';

  bool canSetGlobal(InstalledItem item) => false;
  PlannedChange? planSetGlobal(InstalledItem item) => null;

  /// Default removal moves the item's folders to the Recycle Bin.
  PlannedChange? planRemove(InstalledItem item) {
    if (!item.removable) return null;
    // Installed by the marketplace: also clear the variables that point into it.
    if (MarketInstalls.isMarket(item)) return MarketInstalls.planRemove(item, info.name);
    return PlannedChange(title: 'Remove ${info.name} ${item.title}', recycle: [item.path, ...item.extraPaths]);
  }
}
