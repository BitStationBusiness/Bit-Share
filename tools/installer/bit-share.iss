; Bit-Share Windows installer.
; Build after `flutter build windows --release` from the Flutter app directory.
;
; AppVersion is normally passed in by tools/build_release.ps1
; (/DAppVersion=<pubspec version>), which is the single source of truth for
; the version — the #ifndef fallback below only matters when ISCC is run
; by hand without that flag.
;
; The app's own auto-updater downloads this same installer from the GitHub
; release and runs it with
;     /SILENT /SP- /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS
; (see lib/features/update/update_installer.dart). The second [Run] entry
; below is what makes Bit-Share reopen itself after that silent install.

#ifndef AppVersion
  #define AppVersion "1.0.4"
#endif

#define MyAppName "Bit-Share"
#define MyAppVersion AppVersion
#define MyAppPublisher "BitStation"
#define MyAppURL "https://github.com/BitStationBusiness/Bit-Share"
#define MyAppExeName "bit_share.exe"
#define SourceDir "..\\..\\apps\\bit_share_flutter\\build\\windows\\x64\\runner\\Release"

[Setup]
AppId={{B80E041C-7793-4A48-8A86-20859DA4FCEA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName=C:\Bit-Share
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\\..\\artifacts\\release\\v{#MyAppVersion}
OutputBaseFilename=Bit-Share-Setup-{#MyAppVersion}
SetupIconFile=..\\..\\apps\\bit_share_flutter\\windows\\runner\\resources\\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Interactive install: the usual "launch when done" checkbox.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent runasoriginaluser
; Auto-update (silent install): reopen Bit-Share on its own. runasoriginaluser
; keeps it running as the signed-in user rather than elevated.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait runasoriginaluser; Check: LaunchAfterSilentInstall

[Code]
function LaunchAfterSilentInstall: Boolean;
begin
  Result := WizardSilent;
end;
