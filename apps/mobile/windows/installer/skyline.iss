; Skyline for Windows: the installer (Phase 13). Built by the release workflow
; with Inno Setup 6:  iscc /DAppVersion=1.2.3 windows\installer\skyline.iss
; then signed (the installer and skyline.exe) with the organization's code-
; signing certificate.
;
; Installs for the current person only, with no administrator rights. Updating
; replaces the program files only: the encrypted vault (messages, keys) lives in
; %APPDATA%\com.skyline\skyline and is never touched, not even by uninstalling,
; so a reinstall on the same account finds everything where it was.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define BuildDir "..\..\build\windows\x64\runner\Release"
; Microsoft's C++ runtime, placed next to skyline.exe (app-local deployment),
; so a fresh Windows needs no separate "Visual C++ Redistributable".
#ifndef VCRuntimeDir
  ; Sysnative: the 64-bit System32 as the 32-bit compiler sees it (System32
  ; itself would be redirected to the 32-bit DLLs).
  #define VCRuntimeDir "C:\Windows\Sysnative"
#endif

[Setup]
; Never change AppId: it is how Windows knows a new version replaces the old.
AppId={{28cf60c5-985a-4efd-823d-eb7571c85a0b}
AppName=Skyline
AppVersion={#AppVersion}
AppVerName=Skyline {#AppVersion}
AppPublisher=Skyline
DefaultDirName={localappdata}\Programs\Skyline
DefaultGroupName=Skyline
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\..\build\installer
OutputBaseFilename=skyline-setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\skyline.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; An update while Skyline is running: close it, replace, reopen.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Excludes: "*.lib,*.exp"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRuntimeDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VCRuntimeDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VCRuntimeDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Skyline"; Filename: "{app}\skyline.exe"
Name: "{userdesktop}\Skyline"; Filename: "{app}\skyline.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\skyline.exe"; Description: "Open Skyline"; Flags: nowait postinstall skipifsilent

; Board 49: Skyline can start with Windows (a per-person Run entry it writes
; itself) and keeps running by the clock. Uninstalling stops it and removes
; that entry; nothing is created here at install time.
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Skyline"; Flags: uninsdeletevalue dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "Skyline"; Flags: uninsdeletevalue dontcreatekey

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/im skyline.exe /f"; Flags: runhidden; RunOnceId: "StopSkyline"
