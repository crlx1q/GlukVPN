# Building GlukVPN Desktop on Windows

Everything here runs on your machine. Nothing in this repository was compiled
for you — there is no Windows toolchain in the environment the code was written
in, so treat the first build as the first real verification.

## 1. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Windows | 10 1809+ / 11, x64 | `MinVersion=10.0.17763` in the installer |
| Flutter SDK | 3.19 or newer | `flutter doctor` must be clean for Windows |
| Visual Studio 2022 | any edition | Workload: **Desktop development with C++** |
| CMake | 3.21+ | Ships with the VS C++ workload |
| Inno Setup 6 | optional | Only needed for the installer |
| 7-Zip | optional | Only needed for `-SingleFile` |

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
```

## 2. Drop in the WireGuard DLLs

They are intentionally not committed. See
`native/glukvpn-tunnel-service/vendor/amd64/README.md`.

| File | Source |
| --- | --- |
| `tunnel.dll` | <https://download.wireguard.com/windows-client/> → `embeddable-dll-service/amd64/` |
| `wireguard.dll` | <https://download.wireguard.com/wireguard-nt/> → `bin/amd64/` |

Put both in `native\glukvpn-tunnel-service\vendor\amd64\`.

Without them the build still succeeds, but every Connect answers
`driver_unavailable`.

## 3. The one-liner

```powershell
cd C:\Users\alish\Downloads\GlukVPN
git checkout desktop/beta

powershell -ExecutionPolicy Bypass -File desktop\packaging\build-all.ps1 `
    -Channel prod -Installer -MakeIcons
```

That produces `dist\GlukVPN-Setup-1.0.0.exe`.

Useful variants:

```powershell
# Internal beta build against beta-api.gluk.tech
.\build-all.ps1 -Channel beta -Internal -Installer

# Portable ZIP plus a single self-extracting exe
.\build-all.ps1 -Channel prod -Portable -SingleFile

# Signed release
.\build-all.ps1 -Channel prod -Installer -Sign <certificate-thumbprint>
```

## 4. Doing it by hand

If you would rather see each step, or the script fails and you want to know
where:

### 4.1 Native service

```powershell
cmake -S native\glukvpn-tunnel-service -B native\glukvpn-tunnel-service\build `
      -G "Visual Studio 17 2022" -A x64
cmake --build native\glukvpn-tunnel-service\build --config Release
```

→ `native\glukvpn-tunnel-service\build\Release\GlukVpnTunnelService.exe`

### 4.2 Flutter app

The desktop build needs extra packages, so swap the pubspec first. **Swap it
back afterwards**, or your next Android build will pull in `window_manager`.

```powershell
cd flutter-client
copy pubspec.yaml pubspec.android.bak
copy pubspec.desktop.yaml pubspec.yaml

flutter pub get
flutter build windows --release --target lib\main_windows.dart `
    --dart-define=GLUK_CHANNEL=prod `
    --dart-define=GLUK_INTERNAL=false `
    --dart-define=ALLOW_BETA_CHANNEL=false

copy pubspec.android.bak pubspec.yaml
del pubspec.android.bak
```

→ `flutter-client\build\windows\x64\runner\Release\`

`build-all.ps1` does the same swap inside a `try/finally`, so it restores the
Android pubspec even if you hit Ctrl+C.

### 4.3 Icons

```powershell
powershell -ExecutionPolicy Bypass -File desktop\packaging\make-icons.ps1
```

Generates `assets\tray\{off,connecting,on,error}.ico` and `assets\app.ico`.
Run this **before** the Flutter build the first time, otherwise the tray icon
will be missing at runtime.

### 4.4 Installer

```powershell
iscc /DAppVersion=1.0.0 /DStageDir=..\..\dist\stage desktop\packaging\installer.iss
```

## 5. Windows runner configuration

If `flutter build windows` has never been run in this repo, Flutter generates
`flutter-client\windows\` on the first invocation. Two things are worth setting
afterwards, in `windows\runner\main.cpp` and `Runner.rc`:

- window title `GlukVPN` (the custom title bar draws over it anyway);
- `IDI_APP_ICON` pointing at `assets\app.ico`.

Neither is required for a working build.

## 6. First run

1. Run `dist\GlukVPN-Setup-1.0.0.exe`. Approve the single UAC prompt.
2. The installer registers and starts `GlukVpnTunnel`.
3. GlukVPN launches, shows a ~620 ms logo animation, then the login screen.
4. Sign in with your existing account — username or email.
5. Press Connect.

Verify it is a real system VPN, not a proxy:

```powershell
ipconfig /all | Select-String -Context 0,12 "GlukVPN"
Get-NetAdapter -Name GlukVPN
curl https://api.ipify.org
```

The adapter must exist and the IP must be the node's.

## 7. Running the tests

```powershell
cd flutter-client
flutter test
```

This runs the existing Android tests **and** `test\desktop\`. The desktop tests
are pure Dart, so they pass on any platform.

Android must keep working:

```powershell
flutter build apk --debug
```

## 8. When it goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `driver_unavailable` on Connect | Missing `tunnel.dll` / `wireguard.dll` | Step 2, then rebuild |
| `service_unavailable` | Service not running | `sc query GlukVpnTunnel`, then `GlukVpnTunnelService.exe --start` |
| `client_rejected` | UI running from outside the install directory | Expected during development — use `--console --allow-any-client` |
| `protocol_mismatch` | Service and app built from different revisions | Rebuild both |
| Tray icon missing | Icons not generated | Run `make-icons.ps1`, rebuild |
| `flutter build windows` cannot find the C++ toolchain | VS workload missing | Install **Desktop development with C++** |
| Android build suddenly wants `window_manager` | `pubspec.yaml` left swapped | `git checkout flutter-client/pubspec.yaml` |

Service log: `%PROGRAMDATA%\GlukVPN\logs\service.log`
UI log: `%APPDATA%\GlukVPN\logs\ui.log`

Private and preshared keys are redacted before anything is written, so these
files are safe to attach to a bug report.
