import 'dart:ui' show Color;

import 'sys.dart';

/// Where a tech lives: on the machine, or only inside projects.
enum TechKind { toolchain, framework }

/// How an installed item relates to the user's work.
enum ItemStatus {
  /// The machine-wide default (global FVM version, active Node, ...).
  global,

  /// At least one project or emulator depends on it.
  inUse,

  /// Only used by projects that haven't been touched in a long time.
  stale,

  /// Nothing we know of depends on it.
  unused,

  /// It's on disk but can't work (e.g. an emulator whose system image is gone).
  broken,

  /// A cache that rebuilds itself when needed.
  cache,

  /// We can't tell who uses it.
  unknown,
}

/// Something that depends on an installed item.
class UsageRef {
  const UsageRef({required this.name, required this.path, required this.kind, this.lastActive, this.note});

  final String name;
  final String path;

  /// 'project', 'emulator', ...
  final String kind;
  final DateTime? lastActive;

  /// Short explanation, e.g. "no pin, uses global".
  final String? note;
}

/// One installed version, SDK component, emulator or cache.
class InstalledItem {
  InstalledItem({
    required this.id,
    required this.version,
    required this.path,
    this.label,
    this.group = 'Versions',
    this.isGlobal = false,
    this.isBroken = false,
    this.isCache = false,
    this.usageTracked = true,
    bool removable = true,
    String? removeHint,
    this.installedAt,
    this.lastUsedAt,
    this.details = const {},
    this.extraPaths = const [],
  }) : _removable = removable,
       _removeHint = removeHint;

  /// Other paths that belong to this item and go with it on removal.
  final List<String> extraPaths;

  final String id;
  final String version;
  final String path;
  final String? label;

  /// Section inside a tech page ("Versions", "Build tools", "Emulators").
  final String group;
  final bool isGlobal;
  final bool isBroken;
  final bool isCache;

  /// False when we have no reliable way to know who uses this item.
  final bool usageTracked;

  /// False for things installed by an MSI/system installer, and for anything
  /// that lives in a folder other programs share (Homebrew, system folders…).
  bool get removable => _removable && !_shared;
  final bool _removable;
  bool get _shared => path.isNotEmpty && Sys.isSharedFolder(path);

  String? get removeHint => _removeHint ?? (_removable && _shared ? 'It lives in $path, which other programs share, so Stackyard won\'t remove it.' : null);
  final String? _removeHint;
  final DateTime? installedAt;
  final DateTime? lastUsedAt;
  final Map<String, String> details;

  int? sizeBytes;
  final List<UsageRef> usedBy = [];

  String get title => label ?? version;

  static const staleAfter = Duration(days: 180);

  ItemStatus get status {
    if (isBroken) return ItemStatus.broken;
    if (isCache) return ItemStatus.cache;
    if (isGlobal) return ItemStatus.global;
    if (usedBy.isNotEmpty) {
      final now = DateTime.now();
      final allStale = usedBy.every((u) => u.lastActive != null && now.difference(u.lastActive!) > staleAfter);
      return allStale ? ItemStatus.stale : ItemStatus.inUse;
    }
    if (lastUsedAt != null) {
      return DateTime.now().difference(lastUsedAt!) > staleAfter ? ItemStatus.stale : ItemStatus.inUse;
    }
    if (!usageTracked) return ItemStatus.unknown;
    return ItemStatus.unused;
  }

  /// Counted in "reclaimable" only when we're confident it's safe.
  bool get reclaimable => removable && (status == ItemStatus.unused || status == ItemStatus.broken);
}

/// A version pin found in a project file.
class Pin {
  const Pin({required this.raw, required this.source, this.exact = true});

  final String raw;

  /// File the pin came from, relative to the project root.
  final String source;

  /// False for ranges like ">=18" or "^3.4.0".
  final bool exact;
}

/// A dependency declared by a project (react, react-native, ...).
class DepVersion {
  const DepVersion({required this.declared, this.installed});
  final String declared;
  final String? installed;
  String get effective => installed ?? declared;
}

class Project {
  Project({required this.path, required this.name, required this.lastModified});

  final String path;
  final String name;
  final DateTime lastModified;

  /// 'flutter', 'node', 'android', 'python', 'dotnet', 'java'
  final Set<String> types = {};

  /// techId -> pin
  final Map<String, Pin> pins = {};

  /// npm package -> version
  final Map<String, DepVersion> deps = {};

  /// Values read from build files: compileSdk, ndkVersion, gradle.
  final Map<String, String> buildInfo = {};

  /// 'npm', 'yarn', 'pnpm', 'bun'
  String? packageManager;

  bool get isStale => DateTime.now().difference(lastModified) > InstalledItem.staleAfter;

  UsageRef toUsage({String? note}) => UsageRef(name: name, path: path, kind: 'project', lastActive: lastModified, note: note);
}

/// A version you could install or switch to.
class VersionOption {
  const VersionOption({required this.version, this.channel, this.date, this.isLts = false, this.isLatest = false, this.note});

  final String version;
  final String? channel;
  final DateTime? date;
  final bool isLts;
  final bool isLatest;
  final String? note;
}

/// A shell command the app will run, shown to the user before it runs.
class CommandSpec {
  const CommandSpec({
    required this.title,
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.runInShell = false,
    this.needsAdmin = false,
    this.warning,
    this.environment = const {},
    this.watchPath,
    this.terminal = false,
  });

  /// macOS: run inside a pseudo-terminal. Some tools (git, inside fvm) print
  /// their progress only to a terminal.
  final bool terminal;

  /// A folder the command fills. For tools that print no progress (FVM cloning
  /// Flutter), its growing size is shown while the command runs.
  final String? watchPath;

  final String title;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final bool runInShell;
  final bool needsAdmin;
  final String? warning;

  /// Extra environment variables for this command only.
  final Map<String, String> environment;

  String get display {
    String q(String s) => s.contains(' ') ? '"$s"' : s;
    return [q(executable), ...arguments.map(q)].join(' ');
  }
}

/// A file to download (and usually unpack), checked against its published hash.
class DownloadStep {
  const DownloadStep({required this.url, required this.label, this.sha256, this.sha512, this.sha1, this.checksumUrl, this.size, this.extractTo, this.saveAs});

  final String url;
  final String label;

  /// Expected hashes (hex). [checksumUrl] points to a file that lists it instead
  /// (a bare hash, or "hash  filename" lines).
  final String? sha256;
  final String? sha512;
  final String? sha1;
  final String? checksumUrl;
  final int? size;

  /// Unpack into this folder (a single top folder in the archive is flattened).
  final String? extractTo;

  /// Or keep the file here, for a later command to run (an installer).
  final String? saveAs;
}

enum EnvOp { set, remove, prependPath, dropPathUnder, removeIfUnder }

/// One change to the user's environment variables.
class EnvChange {
  const EnvChange.set(this.name, String this.value) : op = EnvOp.set, replacePrefix = null;
  const EnvChange.remove(this.name) : op = EnvOp.remove, value = null, replacePrefix = null;

  /// Puts [dir] first on PATH, dropping older entries under [replacePrefix] (other
  /// versions of the same tool) so only one is ever active.
  const EnvChange.prependPath(String dir, {this.replacePrefix}) : name = 'PATH', value = dir, op = EnvOp.prependPath;

  /// Takes every PATH entry inside [dir] off PATH (after uninstalling).
  const EnvChange.dropPathUnder(String dir) : name = 'PATH', value = dir, op = EnvOp.dropPathUnder, replacePrefix = null;

  /// Removes [name] if it points inside [dir] (after uninstalling).
  const EnvChange.removeIfUnder(this.name, String dir) : value = dir, op = EnvOp.removeIfUnder, replacePrefix = null;

  final EnvOp op;
  final String name;
  final String? value;
  final String? replacePrefix;

  String get describe => switch (op) {
    EnvOp.set => 'Set $name to $value',
    EnvOp.remove => 'Remove $name',
    EnvOp.prependPath => 'Add $value to PATH (first, so this version is the one that runs)',
    EnvOp.dropPathUnder => 'Take $value off PATH',
    EnvOp.removeIfUnder => 'Remove $name if it points into $value',
  };
}

/// A file the app will write, shown to the user before it's written.
class FileEdit {
  const FileEdit({required this.path, required this.content, this.summary});
  final String path;
  final String content;

  /// Short description of the edit for the confirm dialog (else the content).
  final String? summary;
}

/// Everything one user action will do, previewed in a confirmation dialog.
class PlannedChange {
  const PlannedChange({
    required this.title,
    this.commands = const [],
    this.edits = const [],
    this.recycle = const [],
    this.permanent = false,
    this.downloads = const [],
    this.env = const [],
    this.envForEveryone = false,
    this.envBlock,
    this.record,
    this.warning,
    this.learnMoreUrl,
    this.confirmLabel,
  });

  final String title;
  final List<CommandSpec> commands;
  final List<FileEdit> edits;

  /// Run first: files to download and unpack.
  final List<DownloadStep> downloads;

  /// Run last: environment variable changes (user scope / shell profile).
  final List<EnvChange> env;

  /// Windows: write [env] for everyone on the PC (asks for admin) instead of just this user.
  final bool envForEveryone;

  /// macOS: the name of this tool's block in the shell profile ("java", "node").
  final String? envBlock;

  /// For marketplace installs: what to remember once it succeeds (tool, version, dest).
  final Map<String, String>? record;

  /// Paths moved to the Recycle Bin / Trash (or deleted, when [permanent]).
  final List<String> recycle;

  /// The user chose to skip the Recycle Bin / Trash.
  final bool permanent;

  PlannedChange deletingPermanently() => PlannedChange(
    title: title,
    commands: commands,
    edits: edits,
    recycle: recycle,
    permanent: true,
    downloads: downloads,
    env: env,
    envForEveryone: envForEveryone,
    envBlock: envBlock,
    record: record,
    warning: warning,
    learnMoreUrl: learnMoreUrl,
    confirmLabel: confirmLabel,
  );
  final String? warning;
  final String? learnMoreUrl;

  /// The confirm button for a removal that runs commands ("Erase", "Delete"); "Uninstall" when unset.
  final String? confirmLabel;

  bool get isEmpty => commands.isEmpty && edits.isEmpty && recycle.isEmpty && downloads.isEmpty && env.isEmpty;
}

/// A button next to a problem that fixes it by running [change] as a job.
class NoteFix {
  const NoteFix(this.label, this.change, {this.recommended = false});
  final String label;
  final PlannedChange change;

  /// Shown as the primary button when a problem has several fixes.
  final bool recommended;
}

/// Result of detecting one tech on the machine.
class TechSnapshot {
  TechSnapshot({required this.managerLabel, required this.items, this.latest, List<String>? notes}) : notes = notes ?? [], info = [];

  /// "FVM 3.2.1", "nvm-windows 1.1.12", "Android SDK at F:\androidSDK"
  final String managerLabel;
  final List<InstalledItem> items;

  /// Newest stable version available upstream, if known.
  String? latest;

  /// Problems worth surfacing on the Overview (missing SDKs, broken tools).
  final List<String> notes;

  /// One-click fixes for a note, keyed by the note's text.
  final Map<String, List<NoteFix>> fixes = {};

  /// Records a problem and the buttons that fix it.
  void problem(String text, [List<NoteFix> fixesForIt = const []]) {
    notes.add(text);
    if (fixesForIt.isNotEmpty) fixes[text] = fixesForIt;
  }

  /// Plain facts shown only on the tech's own page (e.g. a Gradle download
  /// that will happen on the next build).
  final List<String> info;

  /// Projects that use this tech (filled in after linking).
  final List<Project> projects = [];

  int get totalBytes => items.fold(0, (sum, i) => sum + (i.sizeBytes ?? 0));
  int get reclaimableBytes => items.where((i) => i.reclaimable).fold(0, (sum, i) => sum + (i.sizeBytes ?? 0));
  int get cacheBytes => items.where((i) => i.isCache).fold(0, (sum, i) => sum + (i.sizeBytes ?? 0));
  bool get sizesPending => items.any((i) => i.path.isNotEmpty && i.sizeBytes == null);
}

class TechInfo {
  const TechInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.color,
    required this.monogram,
    this.logo,
    this.logoTint = LogoTint.none,
  });

  final String id;
  final String name;
  final TechKind kind;
  final Color color;

  /// One or two letters shown when there is no logo.
  final String monogram;

  /// Official logo, an SVG under assets/tech/.
  final String? logo;

  /// How the logo is colored (single-color logos are tinted).
  final LogoTint logoTint;
}

enum LogoTint {
  /// The logo keeps its own colors.
  none,

  /// A single-color logo painted in the tech's brand color.
  brand,

  /// A black logo that turns white in dark mode.
  foreground,
}

/// "Today", "12 days ago", "3 mo ago", "1 yr ago".
String agoText(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inDays >= 365) return '${(d.inDays / 365).floor()} yr ago';
  if (d.inDays >= 30) return '${(d.inDays / 30).floor()} mo ago';
  if (d.inDays >= 1) return '${d.inDays} days ago';
  return 'Today';
}
