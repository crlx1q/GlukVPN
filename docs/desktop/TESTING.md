# GlukVPN Desktop — test matrix

**Read this first.** The desktop client was written without access to a Windows
machine, the WireGuard driver, or a Flutter Windows toolchain. Nothing marked
🔹 below has been executed. Do not treat this document as a passing test report;
treat it as the checklist you run before calling the build good.

| Legend | Meaning |
| --- | --- |
| ✅ | Covered by an automated test in `flutter-client/test/desktop/`, runs anywhere |
| 🔹 | Requires a real Windows machine — yours to verify |
| ⚠️ | Known limitation, see `RELEASE-CHECKLIST.md` |

## 1. Requirement 22 matrix

| # | Scenario | Status | How to verify |
| --- | --- | --- | --- |
| 1 | Clean install on a fresh Windows | 🔹 | Run `GlukVPN-Setup-1.0.0.exe` on a VM. One UAC prompt, no errors. |
| 2 | First launch is fast | 🔹 | Splash ≤ 620 ms, then the login screen. Session, servers and subscription load behind it. |
| 3 | Login with username | 🔹 | Existing account, no separate desktop registration. |
| 4 | Login with email | 🔹 | Same field accepts both — the API takes `identifier`. |
| 5 | Persistent login | 🔹 | Close, reopen. No re-login. Refresh token is DPAPI-protected in `%APPDATA%\GlukVPN\secure\`. |
| 6 | Connect creates a real system VPN | 🔹 | `Get-NetAdapter -Name GlukVPN` must exist; `curl https://api.ipify.org` must return the node's IP. |
| 7 | Disconnect really stops it | 🔹 | The adapter disappears from `ipconfig /all`; the UI follows the service, not the other way round. |
| 8 | Close window ≠ disconnect | ✅ + 🔹 | `WindowController.onWindowClose` only hides. Confirm the tunnel survives and the tray icon stays green. |
| 9 | Tray menu | 🔹 | Right click: Connect / Disconnect / server / ping / traffic / Open / Settings / Exit. Left click opens the mini panel. |
| 10 | Reopen from tray | 🔹 | `adopt()` re-attaches to the live tunnel; duration and traffic continue, they do not reset. |
| 11 | Windows reboot | 🔹 | With autostart on, the app returns to the tray. |
| 12 | VPN state after reboot follows settings | 🔹 | Auto connect on → reconnects. Off → stays disconnected. |
| 13 | Internet routing | 🔹 | `tracert 8.8.8.8` first hop is the tunnel gateway. |
| 14 | DNS | 🔹 | `nslookup example.com` uses the pushed resolver; check dnsleaktest.com. |
| 15 | Kill switch | 🔹 | With it on, `taskkill /F /IM GlukVpnTunnelService.exe`. Because the WFP session is **dynamic**, filters vanish with the process, so the machine regains internet rather than being bricked. That is intentional. |
| 16 | Server switching | 🔹 | Switch while connected: old tunnel down, new one up, no leak window with the kill switch armed. |
| 17 | Offline / network change | 🔹 | Pull the cable. Phase → `tunnelLost`, one silent auto-retry, then a visible error. |
| 18 | API unavailable | ✅ | `tunnel_verifier_test.dart` proves a healthy tunnel stays **connected** when `serverStatus == null`. The control plane going down must not disconnect you. |
| 19 | Tunnel lost | ✅ + 🔹 | 179 s handshake → connected, 181 s → `tunnelLost`. Both boundaries are asserted. |
| 20 | Session expired | ✅ | `phaseForApiError(statusCode: 401, refreshFailed: true)` → `sessionExpired`. |
| 21 | Free 30-minute limit | ⚠️ | **Nothing to test.** No such limit exists in `control-server/src/routes/vpn.ts`. See the release checklist — this belongs on the server. |
| 22 | Subscription limit | ✅ | 403 `SUBSCRIPTION_REQUIRED` / `SUBSCRIPTION_EXPIRED`, 409, 429 → `limitReached`. |
| 23 | Split tunnelling | ⚠️ + 🔹 | "All apps" and destination-exclude work through routes and WFP. Per-app is engine `wfp-guard` — permit/deny only, not redirect. |
| 24 | Device registration | 🔹 | The devices list shows `Windows · Desktop` and it occupies exactly one slot alongside the phone and the extension. |
| 25 | Statistics | ✅ + 🔹 | Buckets, counter resets, retention and idle time are unit-tested. Confirm the numbers match Task Manager. |
| 26 | Uninstall | 🔹 | Removes files, unregisters `GlukVpnTunnel`, deletes `%PROGRAMDATA%\GlukVPN\{run,logs}`. `%APPDATA%\GlukVPN` is deliberately kept. |
| 27 | **Android still works** | ✅ + 🔹 | Three additive edits only. Run `flutter test` and `flutter build apk --debug`. |

## 2. Automated tests

```powershell
cd flutter-client
flutter test
```

| File | What it locks down |
| --- | --- |
| `test/desktop/tunnel_verifier_test.dart` | **The most important one.** CONNECTED requires all four conditions. Reproduces and prevents the Android premature-CONNECTED bug. |
| `test/desktop/connection_phase_test.dart` | The ten phases, tray-icon mapping, and the full API-error → phase table. |
| `test/desktop/node_privacy_test.dart` | `beta-01` and `test-01` never reach a user; `betamax-01` is not misfiltered. |
| `test/desktop/auto_node_test.dart` | Auto scoring, offline exclusion, Free = Auto only. |
| `test/desktop/settings_roundtrip_test.dart` | Settings survive a restart; corrupt JSON never blocks startup. |
| `test/desktop/usage_store_test.dart` | Day/month/all-time buckets, counter resets, idle time, retention. |

All six are pure Dart — no Flutter bindings, no IO, no network. They run on
Linux CI as happily as on Windows.

## 3. Poking the service by hand

Start it in the foreground so it accepts an arbitrary client:

```powershell
.\GlukVpnTunnelService.exe --console --allow-any-client
```

Then, from another PowerShell window:

```powershell
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
    '.', 'GlukVPN.tunnel', [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(3000)

$writer = New-Object System.IO.StreamWriter($pipe)
$reader = New-Object System.IO.StreamReader($pipe)
$writer.AutoFlush = $true

$writer.WriteLine('{"op":"hello","v":1}')
$reader.ReadLine()

$writer.WriteLine('{"op":"status","v":1}')
$reader.ReadLine()

$pipe.Dispose()
```

Expected from `hello`:

```json
{"ok":true,"serviceVersion":"1.0.0","protocolVersion":1,
 "driver":"WireGuardNT 0.10","driverReady":true,
 "splitEngine":"wfp-guard","perAppRedirect":false,"state":"down", ...}
```

Without `--allow-any-client` the same script gets
`{"ok":false,"error":{"code":"client_rejected", ...}}`. That is the security
check doing its job, not a bug.

## 4. Logs

| Path | Contents |
| --- | --- |
| `%PROGRAMDATA%\GlukVPN\logs\service.log` | Tunnel lifecycle, WFP, split tunnelling. Rotates at 2 MiB. |
| `%APPDATA%\GlukVPN\logs\ui.log` | UI-side events. |

Private and preshared keys are scrubbed by two regexes before anything reaches
disk, so both files are safe to attach to a bug report. Please spot-check that
once on your first real run — it is the kind of guarantee worth verifying
rather than trusting.

## 5. Suggested order for the first session

1. `flutter test` — all six desktop files green.
2. `flutter build apk --debug` — Android not broken.
3. Build the installer, install on a throwaway VM.
4. Rows 1–7 above: install, launch, login, connect, verify the real adapter,
   disconnect.
5. Rows 8–12: window, tray, reboot.
6. Rows 13–17: routing, DNS, kill switch, switching, offline.
7. Rows 23–26: split tunnelling, devices, statistics, uninstall.

If rows 1–7 pass, the architecture is sound and everything after that is
polish.
