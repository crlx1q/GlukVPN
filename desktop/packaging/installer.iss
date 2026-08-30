; GlukVPN Desktop installer (Inno Setup 6)
;
; Build with:
;   iscc /DAppVersion=1.0.0 /DStageDir=..\..\dist\stage installer.iss
;
; build-all.ps1 passes both defines automatically.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#ifndef StageDir
  #define StageDir "..\..\dist\stage"
#endif

#define AppName        "GlukVPN"
#define AppPublisher   "GlukVPN"
#define AppUrl         "https://vpn.gluk.tech"
#define AppExeName     "glukvpn.exe"
#define ServiceExeName "GlukVpnTunnelService.exe"

[Setup]
AppId={{7C4E1B92-3A5D-4F18-9E27-GLUKVPN0001}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion={#AppVersion}

DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=no
AllowNoIcons=yes

; The tunnel service must be registered with the SCM, which needs admin.
; This is the only elevation the user ever sees.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763

OutputDir=..\..\dist
 OutputBaseFilename=GlukVPN-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\flutter-client\assets\app.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName} {#AppVersion}
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
english.AutoStartTask=Start GlukVPN when Windows starts
russian.AutoStartTask=Запускать GlukVPN при входе в Windows

english.ServiceInstalling=Registering the GlukVPN tunnel service...
russian.ServiceInstalling=Регистрация службы туннеля GlukVPN...

english.StillRunning=GlukVPN is still running. Please exit it from the system tray and run Setup again.
russian.StillRunning=GlukVPN ещё запущен. Закройте его из системного трея и запустите установку снова.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "{cm:AutoStartTask}"; \
    GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Flutter application: exe, flutter_windows.dll, plugin DLLs and data\.
Source: "{#StageDir}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs; \
    Excludes: "service\*"

; Privileged tunnel service and the WireGuard DLLs it loads.
Source: "{#StageDir}\service\*"; DestDir: "{app}\service"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; \
    Tasks: desktopicon

[Registry]
; Autostart is a per-user HKCU Run entry, so it survives app updates and can
; be toggled from Settings without touching the installer.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "GlukVPN"; \
    ValueData: """{app}\{#AppExeName}"" --hidden"; \
    Flags: uninsdeletevalue; Tasks: autostart

[Run]
; Register and start the tunnel service. waituntilterminated so a failure is
; reported before Setup claims success.
Filename: "{app}\service\{#ServiceExeName}"; Parameters: "--install"; \
    StatusMsg: "{cm:ServiceInstalling}"; \
    Flags: runhidden waituntilterminated

Filename: "{app}\{#AppExeName}"; \
    Description: "{cm:LaunchProgram,{#AppName}}"; \
    Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the tunnel and remove the service before the files disappear.
Filename: "{app}\service\{#ServiceExeName}"; Parameters: "--uninstall"; \
    Flags: runhidden waituntilterminated; RunOnceId: "RemoveGlukService"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\GlukVPN\run"
Type: filesandordirs; Name: "{commonappdata}\GlukVPN\logs"

[Code]
// GlukVPN keeps running in the tray after the window is closed, so the
// installer has to check for a live process rather than a visible window.
function IsAppRunning(const FileName: string): Boolean;
var
  Locator, Service, Items, Item: Variant;
  Enum: IUnknown;
  Value: Cardinal;
begin
  Result := False;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('', 'root\CIMV2');
    Items := Service.ExecQuery(
      Format('SELECT Name FROM Win32_Process WHERE Name = "%s"', [FileName]));
    Result := Items.Count > 0;
  except
    // WMI can be disabled on hardened systems. Do not block the install.
    Result := False;
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if IsAppRunning('{#AppExeName}') then
  begin
    MsgBox(ExpandConstant('{cm:StillRunning}'), mbError, MB_OK);
    Result := False;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  if IsAppRunning('{#AppExeName}') then
  begin
    MsgBox(ExpandConstant('{cm:StillRunning}'), mbError, MB_OK);
    Result := False;
  end;
end;
