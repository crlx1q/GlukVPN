# GlukVPN Desktop — architecture

Windows client, branch `desktop/beta`. One Flutter codebase serves Android and
Windows; only the VPN implementation is platform-specific.

## 1. The shape of it

```
              +-------------------------------------------+
              |            shared Dart code               |
              |  models, ApiClient, AuthController,       |
              |  SecureStore, WgKeys, theme, widgets      |
              +----------------+--------------------------+
                               |
            +------------------+------------------+
            |                                     |
   +--------v---------+                 +---------v----------+
   |   lib/ (android) |                 |  lib/desktop/      |
   |  VpnService      |                 |  DesktopVpnCtrl    |
   |  wireguard_flutter|                |  WindowsTunnelClient|
   +--------+---------+                 +---------+----------+
            |                                     |
     Android VpnService                  \\.\pipe\GlukVPN.tunnel
                                                  |
                                    +-------------v--------------+
                                    | GlukVpnTunnelService.exe   |
                                    | (LocalSystem, C++20)       |
                                    |  tunnel.dll  -> WireGuard  |
                                    |  wintun.dll   -> WHQL      |
                                    |  UAPI pipe    -> stats     |
                                    |  WFP -> kill switch, apps  |
                                    |  iphlpapi -> routes        |
                                    +----------------------------+
```

The hard rule from requirement 20: **Android never imports desktop code, and
desktop code never reaches into Android's VPN layer.** They meet only at
`TunnelBackend`, an abstract interface in `lib/platform/`.

## 2. Why a separate privileged service

Creating a network adapter, installing routes and programming WFP all require
administrator rights. Three options were on the table:

| Option | Verdict |
| --- | --- |
| Run the whole UI elevated | Rejected. A GUI running as admin all day is a poor security posture, and Windows would prompt on every launch. |
| Elevate on demand per action | Rejected. A UAC prompt on every Connect is exactly the friction requirement 2 forbids. |
| **Split: unelevated UI + privileged service** | **Chosen.** One UAC prompt during installation, none afterwards. This is what WireGuard, Mullvad and Tailscale all do. |

A consequence worth stating plainly: the VPN keeps running when the UI exits,
which is precisely what requirements 11 and 12 ask for.

## 3. Layer by layer

### 3.1 `lib/platform/` — the seam

| File | Purpose |
| --- | --- |
| `platform_target.dart` | `currentPlatformTarget`, `devicePlatformTag` (`android` / `windows`), `suggestedDeviceLabel`. |
| `tunnel_backend.dart` | `abstract class TunnelBackend` plus `TunnelSnapshot`, `TunnelUpOptions`, `TunnelResult`, `TunnelState`, `SplitMode`. |

`TunnelBackend` has five methods: `isAvailable`, `up`, `down`, `status`,
`setSplit`. Android could implement the same interface later; nothing in the
design prevents it.

### 3.2 `lib/desktop/logic/` — pure, testable decisions

No IO, no Flutter, no platform channels. This is where the behaviour that
matters most lives, so it can be unit-tested on any machine.

**`connection_phase.dart`** defines the ten states from requirement 6 and
`TunnelVerifier`, the gate that fixes the Android premature-CONNECTED bug. All
four conditions must hold:

1. the service reports `state == connected`;
2. the WireGuard handshake is younger than 180 s;
3. `GET /api/vpn/status` returns `peerReady == true`;
4. bytes have actually moved, or a gateway ping succeeded.

One asymmetry is deliberate: a **missing** server status never invalidates a
healthy tunnel. If the control plane goes down while you are connected, you
stay connected. The tunnel is the source of truth; the API is a second opinion.

**`node_selector.dart`** enforces requirement 8. `isInternalNode` filters out
anything matching `beta`, `test`, `staging`, `dev`, `internal`, `canary`,
`lab`, `tmp` as a whole word, so `de-01` survives and `beta-01` never reaches a
normal user. `pickBestNode` scores candidates:

```
score = 0.55 * pingGrade + 0.30 * loadGrade + 0.15 * headroom
```

Free accounts get Auto only; `manualSelectionAllowed(subscription)` is the
single place that decides this.

### 3.3 `lib/desktop/services/` — talking to Windows

| File | Purpose |
| --- | --- |
| `tunnel_ipc.dart` | Named-pipe transport. Runs in `Isolate.run` so a slow pipe never janks the UI. |
| `tunnel_client.dart` | `WindowsTunnelClient implements TunnelBackend`. Handshake, protocol-version check, status parsing. |
| `app_paths.dart` | Every path in one place: `%APPDATA%\GlukVPN\...`, `%PROGRAMDATA%\GlukVPN\...`. |
| `service_bootstrap.dart` | Detects whether the service is installed/running and elevates once to fix it. |
| `autostart_service.dart` | `HKCU\...\Run`, value `GlukVPN`, optional `--hidden`. |
| `app_inventory.dart` | Enumerates installed and running executables for the split-tunnelling picker. |

### 3.4 `lib/desktop/state/`

`DesktopVpnController` is the orchestrator: it owns the phase, drives three
timers (service status 2 s, server status 10 s, ping 3 s), arms a 25 s connect
deadline, and performs exactly one silent auto-reconnect when a tunnel is lost.

`WindowController` implements requirement 11's headline rule: **closing the
window is not disconnecting.** `windowManager.setPreventClose(true)` turns the
close button into "save geometry, hide to tray".

`SettingsStore` and `UsageStore` both write atomically (`.tmp` then rename), so
a crash mid-write cannot corrupt them.

### 3.5 The native service

| File | Purpose |
| --- | --- |
| `service.cpp` | SCM registration, auto-restart on crash, `BFE` dependency. |
| `pipe_server.cpp` | Pipe DACL, JSON dispatch, client verification. |
| `tunnel.cpp` | Config preparation, lifecycle, the `down/starting/connected/lost/error` state machine. |
| `wireguard_nt.cpp` | Reads live handshake time and byte counters. |
| `wfp.cpp` | Kill switch and per-app filters, in a **dynamic** WFP session. |
| `split_tunnel.cpp` | Modes, bypass routes, physical-default-route discovery. |
| `appdata.cpp` | Restrictive ACLs, DPAPI, zero-overwrite deletion. |

The dynamic WFP session deserves a note: every filter is destroyed when the
process exits. `taskkill /F` on the service therefore **cannot** leave a machine
without internet. That is the opposite trade-off from a "hard" kill switch, and
it is the right one for a consumer product.

## 4. Connect, end to end

1. `DesktopVpnController.connect()` → `POST /api/vpn/connect` → `{session, node, tunnel}`.
2. Private key is read from `SecureStore` and a `wg-quick` config is assembled
   **in memory**. It is never written by the UI.
3. `up` over the pipe. The service writes the config to
   `%PROGRAMDATA%\GlukVPN\run\GlukVPN.conf` (SYSTEM + Administrators only),
   arms the kill switch, then calls `WireGuardTunnelService`.
4. UI enters `connecting`. Every 2 s it polls `status`.
5. `TunnelVerifier` returns `connected` only when all four conditions hold.
6. On `down`: WFP cleared, split rules removed, stop event signalled, config
   overwritten with zeros and deleted.

## 5. Data and secrets

| Path | Contents | Protection |
| --- | --- | --- |
| `%APPDATA%\GlukVPN\secure\` | Refresh token, WireGuard private key | DPAPI, user scope |
| `%APPDATA%\GlukVPN\settings.json` | Settings | Per-user ACL |
| `%APPDATA%\GlukVPN\usage.json` | Statistics, keyed by account public id | Per-user ACL |
| `%PROGRAMDATA%\GlukVPN\run\` | Live tunnel config | `D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)` |
| `%PROGRAMDATA%\GlukVPN\logs\` | Service log | Keys redacted before writing |

Statistics are keyed by account public id rather than device id, so requirement
18 holds: history survives "Remove device".

## 6. What is shared with Android and the extension

One account, one device list, one subscription. The desktop registers itself
via the existing `POST /api/devices/register` with `platform: "windows"` — a
field the control server already accepted before this work started — and
occupies exactly one device slot, alongside `Android phone` and
`Chrome · Windows`.

Three small edits to shared files, all additive and all defaulted so Android
behaviour is byte-for-byte unchanged:

| File | Change |
| --- | --- |
| `lib/config.dart` | Added `activeChannel`, `internalBuild` and the desktop constant block. |
| `lib/services/secure_store.dart` | `ensureDeviceName()` returns `Windows · Desktop` on Windows; the Android branch is untouched. |
| `lib/state/auth_controller.dart` | Passes `platform: devicePlatformTag` to `registerDevice`, which already defaulted to `'android'`. |

## 7. Deliberate non-goals

- **No API URL field.** Requirement 16. The channel is a build-time constant.
- **No user-visible node identifiers.** Requirement 8.
- **No PowerShell, node, or scripts at runtime.** Requirement 2.
- **No Android rewrite.** Requirement 1 and 23.
