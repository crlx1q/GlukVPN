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
;
; PrivilegesRequiredOverridesAllowed is deliberately EMPTY. With "dialog" Inno
; Setup shows the "Install for all users / Install for me only" page, which is
; the odd choice reported after the first release. GlukVPN cannot be installed
; per-user anyway - it registers a system service - so Setup now simply asks
; for administrator rights once and installs machine-wide.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=
UsePreviousPrivileges=no

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

; Privileged tunnel service plus the two files it needs at runtime:
; glukvpn-wg.exe (our userspace wireguard-go data plane) and the WHQL-signed
; wintun.dll. No kernel driver is installed at any point - that is the whole
; point of round 7, and it is why the tunnel now comes up with Core Isolation
; enabled.
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

; Clear any "always run as administrator" compatibility flag left behind by an
; earlier build. Windows records those per-exe under AppCompatFlags\Layers, and
; a stale RUNASADMIN entry makes every launch of glukvpn.exe demand elevation -
; which is what turned the installer's own "run now" step into
; "CreateProcess failed; code 740".
Root: HKCU; Subkey: "Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; \
    ValueType: none; ValueName: "{app}\{#AppExeName}"; \
    Flags: deletevalue noerror
Root: HKLM; Subkey: "Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; \
    ValueType: none; ValueName: "{app}\{#AppExeName}"; \
    Flags: deletevalue noerror

[Run]
; Register and start the tunnel service. waituntilterminated so a failure is
; reported before Setup claims success.
Filename: "{app}\service\{#ServiceExeName}"; Parameters: "--install"; \
    StatusMsg: "{cm:ServiceInstalling}"; \
    Flags: runhidden waituntilterminated

; Launch the client as the *logged-in user*, not as the elevated installer.
;
; Without runasoriginaluser the app inherits Setup's administrator token. It
; then writes its settings into the administrator profile and Windows refuses
; parts of the shell integration. The client itself never needs elevation: the
; privileged work lives in the service.
;
; runasoriginaluser on its own was not enough. It goes through
; CreateProcessAsUser, which cannot elevate and fails with
;   "CreateProcess failed; code 740 - the requested operation requires
;    elevation"
; whenever Windows believes glukvpn.exe needs administrator rights. Three
; changes make sure it does not:
;   * the exe manifest now declares requestedExecutionLevel asInvoker
;     (flutter-client\windows\runner\runner.exe.manifest),
;   * shellexec hands the launch to the shell, which honours that manifest
;     instead of failing the call, and
;   * the [Registry] section above clears any stale RUNASADMIN layer.
Filename: "{app}\{#AppExeName}"; \
    Description: "{cm:LaunchProgram,{#AppName}}"; \
    Flags: nowait postinstall skipifsilent runasoriginaluser shellexec

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
  Locator, Service, Items: Variant;
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
