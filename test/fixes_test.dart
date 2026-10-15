import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/installed_apps.dart';
import 'package:stackyard/core/models.dart';

void main() {
  const hklm = r'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\x';
  const hkcu = r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\x';

  test('an MSI is removed with msiexec, quietly, as admin', () {
    final cmd = InstalledApps.uninstall({'DisplayName': 'Node.js', 'Key': hklm, 'UninstallString': 'MsiExec.exe /I{A56DECD3-5312-4F1D-B185-9A47DE16BCEC}'})!;
    expect(cmd.executable, 'msiexec.exe');
    expect(cmd.arguments, ['/x', '{A56DECD3-5312-4F1D-B185-9A47DE16BCEC}', '/passive', '/norestart']);
    expect(cmd.needsAdmin, isTrue);
  });

  test('Inno Setup uninstallers run without their questions', () {
    final cmd = InstalledApps.uninstall({
      'DisplayName': 'NVM for Windows 1.1.12',
      'Key': hklm,
      'UninstallString': r'"C:\Users\me\AppData\Roaming\nvm\unins000.exe"',
    })!;
    expect(cmd.executable, r'C:\Users\me\AppData\Roaming\nvm\unins000.exe');
    expect(cmd.arguments, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART']);
    // Even when it registers a /SILENT "quiet" string, which can still show message boxes.
    final quiet = InstalledApps.uninstall({
      'DisplayName': 'NVM for Windows 1.1.12',
      'Key': hklm,
      'UninstallString': r'"C:\nvm\unins000.exe"',
      'QuietUninstallString': r'"C:\nvm\unins000.exe" /SILENT',
    })!;
    expect(quiet.arguments, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART']);
  });

  test('WiX bundles (python.org, .NET) keep /uninstall and go quiet', () {
    final cmd = InstalledApps.uninstall({
      'DisplayName': 'Microsoft .NET SDK 8.0.403 (x64)',
      'Key': hklm,
      'UninstallString': r'"C:\ProgramData\Package Cache\{x}\dotnet-sdk-8.0.403-win-x64.exe"  /uninstall',
    })!;
    expect(cmd.arguments, ['/uninstall', '/quiet', '/norestart']);
  });

  test('a quiet uninstall string is used as is; per-user entries need no admin', () {
    final cmd = InstalledApps.uninstall({
      'DisplayName': 'Tool',
      'Key': hkcu,
      'UninstallString': r'"C:\Tool\uninstall.exe"',
      'QuietUninstallString': r'"C:\Tool\uninstall.exe" /S',
    })!;
    expect(cmd.executable, r'C:\Tool\uninstall.exe');
    expect(cmd.arguments, ['/S']);
    expect(cmd.needsAdmin, isFalse);
  });

  test('unquoted paths with spaces are split at the .exe', () {
    final cmd = InstalledApps.uninstall({'DisplayName': 'Tool', 'Key': hkcu, 'UninstallString': r'C:\Program Files\Tool\un ins.exe /x'})!;
    expect(cmd.executable, r'C:\Program Files\Tool\un ins.exe');
    expect(cmd.arguments, ['/x']);
  });

  test('a problem keeps its fixes, keyed by its text', () {
    final snap = TechSnapshot(managerLabel: 'x', items: []);
    const fix = NoteFix('Fix it', PlannedChange(title: 'Fix'), recommended: true);
    snap.problem('Something is wrong.', [fix]);
    snap.problem('Something else, with no fix.');
    expect(snap.notes, ['Something is wrong.', 'Something else, with no fix.']);
    expect(snap.fixes['Something is wrong.'], [fix]);
    expect(snap.fixes.containsKey('Something else, with no fix.'), isFalse);
  });
}
