# GlukVPN Desktop — file inventory

Branch `desktop/beta`. 71 new files, 3 modified. Nothing was deleted, and no
existing behaviour was replaced.

## Modified — 3 files, all additive

| File | Change | Android impact |
| --- | --- | --- |
| `flutter-client/lib/config.dart` | +70 lines: `activeChannel`, `activeBaseUrl`, `internalBuild`, and the desktop constant block (pipe name, service name, adapter name, timeouts, window sizes). | None. New members only; existing ones untouched. |
| `flutter-client/lib/services/secure_store.dart` | +17 / −2: `ensureDeviceName()` now branches on platform. Windows → `Windows · Desktop`. | None. The Android branch produces the identical `android-<suffix>` string it always did. |
| `flutter-client/lib/state/auth_controller.dart` | +5: passes `platform: devicePlatformTag` to `registerDevice`. | None. `registerDevice` already had `String platform = 'android'` and already sent the field; Android now passes the same value explicitly. |

These are applied as real commits on `desktop/beta`, not as `.patch` files you
have to run `git apply` on.

`ApiClient` needed no change at all — `registerDevice` already accepted and
transmitted `platform`, and `control-server` already validated it
(`platform: z.string().trim().max(32).optional()`).

## New — Dart, 32 files

### `lib/platform/` — the Android/Windows seam

| File | Lines | Purpose |
| --- | --- | --- |
| `platform_target.dart` | 44 | Platform detection, device tag, device label. |
| `tunnel_backend.dart` | 246 | `TunnelBackend` interface, `TunnelSnapshot`, `TunnelUpOptions`, `TunnelResult`, `SplitMode`. |

### `lib/desktop/logic/` — pure logic, fully unit-tested

| File | Lines | Purpose |
| --- | --- | --- |
| `connection_phase.dart` | 310 | Ten phases, `TunnelVerifier`, `phaseForApiError`. |
| `node_selector.dart` | 166 | Internal-node filtering, Auto scoring, Free/paid gating. |

### `lib/desktop/services/` — Windows integration

| File | Lines | Purpose |
| --- | --- | --- |
| `tunnel_ipc.dart` | 268 | Named-pipe client, off the UI isolate. |
| `tunnel_client.dart` | 269 | `WindowsTunnelClient implements TunnelBackend`. |
| `app_paths.dart` | 84 | Every filesystem path in one place. |
| `service_bootstrap.dart` | 173 | Service detection and one-time elevation. |
| `autostart_service.dart` | 160 | `HKCU\...\Run` management. |
| `app_inventory.dart` | 246 | Installed/running app enumeration for split tunnelling. |

### `lib/desktop/state/`

| File | Lines | Purpose |
| --- | --- | --- |
| `desktop_vpn_controller.dart` | 702 | The orchestrator: phases, timers, reconnect, split, usage. |
| `desktop_settings.dart` | 273 | `DesktopSettings` + atomic `SettingsStore`. |
| `usage_store.dart` | 315 | Traffic history with 400-day retention. |
| `window_controller.dart` | 212 | Main/mini modes; close means hide, not disconnect. |
| `tray_controller.dart` | 193 | Four-state icon, throttled menu rebuild. |

### `lib/desktop/i18n/`

| File | Lines | Purpose |
| --- | --- | --- |
| `desktop_strings.dart` | 338 | Full RU + EN. Cyrillic locales resolve to Russian. |

### `lib/desktop/widgets/`

| File | Lines | Purpose |
| --- | --- | --- |
| `world_stage.dart` | 230 | Desktop-scale dotted globe, route, node pulses. |
| `desktop_connect_button.dart` | 93 | The existing blob/morph button at desktop scale. |
| `metric_cell.dart` | 108 | IP / ping / duration / traffic cells. |
| `side_nav.dart` | 136 | 84 px vertical navigation rail. |
| `server_row.dart` | 190 | Flag, city, signal bars, ping, load, lock. |
| `window_title_bar.dart` | 155 | Custom 44 px draggable title bar. |
| `desktop_splash.dart` | 127 | ~620 ms logo animation. |

### `lib/desktop/screens/`

| File | Lines | Purpose |
| --- | --- | --- |
| `desktop_shell.dart` | 246 | Navigation host, mini/main switching. |
| `desktop_login_screen.dart` | 273 | Username or email, persistent session. |
| `desktop_home_screen.dart` | 394 | Globe, connect button, live metrics. |
| `desktop_servers_screen.dart` | 264 | Server list with Free/paid gating. |
| `desktop_settings_screen.dart` | 759 | General, VPN, Split tunneling, Account. |
| `desktop_stats_screen.dart` | 258 | Today, month, all time, 14-day chart. |
| `mini_panel.dart` | 231 | 340×420 tray quick panel. |

### Entry point and manifest

| File | Lines | Purpose |
| --- | --- | --- |
| `lib/main_windows.dart` | 248 | Windows entry point and DI chain. |
| `pubspec.desktop.yaml` | 60 | Desktop dependency set; swapped in at build time. |

`lib/main.dart` is untouched — Android still builds from it.

## New — native service, 20 files

`native/glukvpn-tunnel-service/`

| File | Bytes | Purpose |
| --- | --- | --- |
| `CMakeLists.txt` | 4 544 | C++20, static CRT, hardened flags, vendor DLL staging. |
| `src/main.cpp` | 3 213 | `wWinMain`, verb parsing. |
| `src/service.h` / `.cpp` | 1 890 / 10 244 | SCM registration, restart policy, lifecycle. |
| `src/pipe_server.h` / `.cpp` | 2 140 / 14 376 | Pipe DACL, JSON dispatch, client verification. |
| `src/tunnel.h` / `.cpp` | 3 953 / 14 073 | Config, lifecycle, state machine. |
| `src/wireguard_nt.h` / `.cpp` | 1 740 / 7 219 | WireGuardNT binding: handshake and counters. |
| `src/wfp.h` / `.cpp` | 2 607 / 15 757 | Kill switch and per-app filters. |
| `src/split_tunnel.h` / `.cpp` | 3 126 / 8 234 | Modes, bypass routes, default-route discovery. |
| `src/appdata.h` / `.cpp` | 2 086 / 8 894 | ACLs, DPAPI, secure deletion. |
| `src/json.h` / `.cpp` | 4 211 / 11 336 | Dependency-free bounded JSON. |
| `src/log.h` / `.cpp` | 1 024 / 3 992 | Rotating log with key scrubbing. |
| `README.md` | — | Protocol reference and error codes. |
| `vendor/amd64/README.md` | — | Where to get `tunnel.dll` and `wireguard.dll`. |

No third-party source is vendored. The only external binaries are the two
official WireGuard DLLs, which you download yourself.

## New — packaging, 4 files

| File | Lines | Purpose |
| --- | --- | --- |
| `desktop/packaging/build-all.ps1` | 287 | One command: native + Flutter + icons + installer + portable + signing. |
| `desktop/packaging/installer.iss` | 164 | Inno Setup 6, RU + EN, service install/uninstall, autostart task. |
| `desktop/packaging/make-icons.ps1` | 209 | Generates the four tray icons and `app.ico`. |
| `desktop/packaging/portable.ps1` | 195 | Portable ZIP and optional 7-Zip SFX. |

## New — tests, 6 files

`flutter-client/test/desktop/`

| File | Purpose |
| --- | --- |
| `tunnel_verifier_test.dart` | The CONNECTED gate, including the 179 s / 181 s boundary. |
| `connection_phase_test.dart` | Phase behaviour and the API-error mapping table. |
| `node_privacy_test.dart` | Internal nodes never leak. |
| `auto_node_test.dart` | Auto scoring and subscription gating. |
| `settings_roundtrip_test.dart` | Persistence and hostile input. |
| `usage_store_test.dart` | Traffic accounting. |

Existing tests in `flutter-client/test/` are untouched and still run.

## New — documentation, 6 files

`docs/desktop/`

| File | Purpose |
| --- | --- |
| `DESKTOP-README.md` | Start here. How to turn this into an exe. |
| `ARCHITECTURE.md` | Design and the reasoning behind it. |
| `BUILD-WINDOWS.md` | Prerequisites, build commands, troubleshooting. |
| `TESTING.md` | The requirement-22 matrix, honestly annotated. |
| `RELEASE-CHECKLIST.md` | What blocks a public release. |
| `FILES.md` | This file. |

## Untouched, deliberately

- `flutter-client/lib/main.dart`, `app.dart`, all `screens/`, `widgets/`,
  `theme/`, `utils/`, `models/`, and the rest of `services/` and `state/`.
- `control-server/` — no server change was needed.
- `node-agent/`, `glukvpn-extension-1.5.0/`, `site/`.
- `master`, `beta`, and production.
