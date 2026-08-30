# GlukVPN Desktop — what stands between MVP and production

The MVP is complete and coherent. It is not yet a public release. Four things
block that, and none of them can be solved by writing more client code.

## Blockers

### 1. The Free 30-minute limit does not exist

The client already has a `limitReached` phase and shows it correctly. But there
is no such limit on the server: `control-server/src/routes/vpn.ts` never expires
a free session.

Enforcing it in the client is pointless. The tunnel is plain WireGuard — anyone
can copy the config into the official WireGuard client and stay connected
forever. A client-side timer inconveniences honest users and stops nobody.

**Where it belongs:** `control-server` schedules a session expiry; when it
fires, the node agent receives a `REMOVE_PEER` command and the peer is dropped.
The client then sees `peerReady == false` and moves to `limitReached` on its
own — no client change needed.

### 2. Authenticode code signing

Unsigned, the following happens:

- SmartScreen warns on every download and install;
- some antivirus products quarantine a program that installs a service and
  programs WFP;
- `PipeServer::VerifyClient` can only check the image path, not a publisher.

**What to do:** buy an OV or EV certificate (EV gets instant SmartScreen
reputation), then sign `glukvpn.exe`, `GlukVpnTunnelService.exe` and the
installer:

```powershell
.\build-all.ps1 -Channel prod -Installer -Sign <thumbprint>
```

Once signed, replace the path check in `pipe_server.cpp` with `WinVerifyTrust`
plus a publisher-name comparison. That upgrade is the difference between "an
attacker must write to Program Files" and "an attacker must steal your signing
key".

### 3. Decide what per-app split tunnelling actually means

Today the engine is `wfp-guard`: WFP can **permit or deny** an application's
traffic, but it cannot **redirect** it. So "only these apps use the VPN" is
approximated rather than implemented.

| Option | Effort | Cost |
| --- | --- | --- |
| Ship as-is | none | Honest permit/deny; "only selected" is not truly selective |
| Bundle WinDivert (`-DGLUK_WITH_WINDIVERT=ON`) | days | LGPLv3/GPLv2 licence, and its driver is itself flagged by some AV |
| Own WFP callout driver at `ALE_BIND_REDIRECT_V4` / `ALE_CONNECT_REDIRECT_V4` | months | EV cert, WHQL attestation signing, real kernel risk |

My recommendation: ship as-is for 1.0, label it clearly in Settings, and
revisit only if users actually ask. Destination-based exclusion already works
properly and covers most real cases.

### 4. No auto-update

`GET /api/version` already exists. The minimum viable step is a banner in
Settings linking to `vpn.gluk.tech` when a newer version is published.

A real updater must update **both** binaries — replacing `glukvpn.exe` while an
old `GlukVpnTunnelService.exe` keeps running produces `protocol_mismatch`. The
protocol version field exists precisely so that this failure is loud rather
than mysterious.

## Not blocking, but worth doing

- IPv6 handling in the split-tunnelling modes (v4 is complete; v6 currently
  rides the default route).
- Light and dark tray icon variants — the current ones carry a halo so they
  read on both, but native pairs look better.
- Installer languages beyond RU and EN.
- Crash telemetry, opt-in.
- Server-side statistics, so the numbers survive a reinstall.

## Known MVP limitations — state these honestly

**1. There is no true single-file exe.**
Flutter Windows always emits `glukvpn.exe` plus `flutter_windows.dll` and a
`data\` folder. `-SingleFile` produces a 7-Zip self-extracting archive: the user
double-clicks one file, it unpacks to `%LOCALAPPDATA%\GlukVPN\app` and runs. The
part of your requirement that matters — user data in `%APPDATA%` — is met
regardless.

**2. A real VPN needs a driver, so there is exactly one UAC prompt.**
At installation. Never again. No product that creates a network adapter can do
better, including the official WireGuard client.

**3. Windows Settings → VPN will not list GlukVPN.**
That page only shows RAS/IKEv2/L2TP connections. WireGuard tunnels never appear
there — the official client behaves identically. The connection **is** visible
in Network Connections as the `GlukVPN` adapter, in `ipconfig /all`, in
`Get-NetAdapter`, and in our tray icon. This is a Windows limitation, not a
shortcut in our implementation.

**4. `Down()` is best-effort.**
If the service is killed mid-teardown, the adapter can briefly linger. The WFP
session is dynamic, so filters always disappear with the process — a killed
service can never leave the machine without internet.

**5. `AppInventory` does not see every application.**
It scans `%PROGRAMFILES%`, `%PROGRAMFILES(X86)%`, `%LOCALAPPDATA%\Programs` two
levels deep, plus running processes. Portable apps elsewhere need to be added
by browsing to the exe.

**6. Crossing the "all apps" boundary requires a reconnect.**
`Table = off` is decided when the adapter is created. Switching between "all
apps" and a split mode therefore returns `reconnect_required`; the preference is
saved and applied on the next connect. The UI says so rather than silently
doing nothing.

## Pre-flight, in order

1. `flutter test` green, including all six desktop files.
2. `flutter build apk --debug` succeeds — Android untouched.
3. Vendor DLLs present and their versions recorded.
4. Everything signed, timestamped, SmartScreen clean.
5. Rows 1–7 of `TESTING.md` pass on a clean VM.
6. Kill switch verified with the service force-killed.
7. Device shows as `Windows · Desktop` and takes one slot.
8. Uninstall leaves no service and no `%PROGRAMDATA%\GlukVPN\run`.
9. Free-tier limit implemented server-side, or explicitly deferred in writing.
10. Merge `desktop/beta` → `beta` first. **Never straight to production.**
