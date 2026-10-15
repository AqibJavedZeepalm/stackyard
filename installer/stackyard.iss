; Builds Stackyard-Setup-<version>.exe from the Windows release build.
;   iscc /DAppVersion=1.0.0 installer\stackyard.iss
; Installs for the current user (no administrator prompt) into
; %LOCALAPPDATA%\Programs\Stackyard, the same place tool\install.ps1 uses.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6E1F4C2A-5B7D-4E8A-9C3F-2D1B0A9E8F71}
AppName=Stackyard
AppVersion={#AppVersion}
AppVerName=Stackyard {#AppVersion}
AppPublisher=Stackyard contributors
AppPublisherURL=https://github.com/AqibJavedZeepalm/stackyard
AppSupportURL=https://github.com/AqibJavedZeepalm/stackyard/issues
DefaultDirName={localappdata}\Programs\Stackyard
DisableDirPage=yes
DisableProgramGroupPage=yes
DefaultGroupName=Stackyard
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=Stackyard-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\stackyard.exe
UninstallDisplayName=Stackyard
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
LicenseFile=..\LICENSE

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Stackyard"; Filename: "{app}\stackyard.exe"; Comment: "See and manage every SDK and toolchain version on your machine."
Name: "{userdesktop}\Stackyard"; Filename: "{app}\stackyard.exe"; Tasks: desktopicon

[Registry]
; "Start with Windows" (set from Stackyard's Settings) goes away with the app.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Stackyard"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\stackyard.exe"; Description: "{cm:LaunchProgram,Stackyard}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM stackyard.exe /F"; Flags: runhidden; RunOnceId: "StopStackyard"
