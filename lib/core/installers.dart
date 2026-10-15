import 'models.dart';
import 'sys.dart';

/// Installs toolchains that have no version manager of their own, with the
/// platform's package manager: winget on Windows, Homebrew on macOS.
/// Each returns null when this machine can't do it.
class Installers {
  static const _wingetQuiet = ['--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements'];

  /// A JDK by major version (Microsoft's OpenJDK on Windows, Temurin on macOS).
  static CommandSpec? jdk(int major) {
    if (Sys.isWindows) {
      if (![11, 17, 21, 25].contains(major)) return null;
      return CommandSpec(title: 'Install JDK $major', executable: 'winget', arguments: ['install', '--id', 'Microsoft.OpenJDK.$major', ..._wingetQuiet]);
    }
    final brew = Sys.which('brew');
    if (brew == null) return null;
    return CommandSpec(title: 'Install JDK $major', executable: brew, arguments: ['install', '--cask', 'temurin@$major']);
  }

  /// Python by minor version, e.g. "3.12" (the newest patch of it).
  static CommandSpec? python(String minor) {
    if (Sys.isWindows) {
      return CommandSpec(title: 'Install Python $minor', executable: 'winget', arguments: ['install', '--id', 'Python.Python.$minor', ..._wingetQuiet]);
    }
    final brew = Sys.which('brew');
    if (brew == null) return null;
    return CommandSpec(title: 'Install Python $minor', executable: brew, arguments: ['install', 'python@$minor']);
  }

  /// A .NET SDK, by its feature band (e.g. "8.0" installs the newest 8.0 SDK).
  static CommandSpec? dotnetSdk(String version) {
    final major = version.split('.').first;
    if (Sys.isWindows) {
      return CommandSpec(
        title: 'Install .NET SDK $major',
        executable: 'winget',
        arguments: ['install', '--id', 'Microsoft.DotNet.SDK.$major', ..._wingetQuiet],
      );
    }
    final brew = Sys.which('brew');
    if (brew == null) return null;
    return CommandSpec(title: 'Install .NET SDK $major', executable: brew, arguments: ['install', 'dotnet@$major']);
  }
}
