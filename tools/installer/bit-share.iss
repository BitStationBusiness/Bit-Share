; Bit-Share Windows installer — release v1.0.1
; Build after `flutter build windows --release` from the Flutter app directory.

#define MyAppName "Bit-Share"
#define MyAppVersion "1.0.1"
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
OutputDir=..\\..\\artifacts\\release\\v1.0.1
OutputBaseFilename=Bit-Share-Setup-1.0.1
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
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
