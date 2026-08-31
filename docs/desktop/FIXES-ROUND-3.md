# Round 3 fixes

Everything reported on 2026-08-31 (six screenshots plus a diagnostics dump),
with the reasoning behind each change. Branch: `desktop/beta`.

---

## 1. Connect did nothing: `nodes total=1 visible=0`

**Report.** `auto why: no_available_nodes`, banner *"All 1 servers were filtered
out as internal"*, two connect attempts both ending in
`serverUnavailable [no_available_nodes]`.

**Cause.** Requirement 8 says internal handles (`beta-01`, `test-01`, ...) must
never be shown. Round 1 implemented that as a hard filter. The production fleet
currently contains exactly one node whose handle matches an internal marker, so
the filter removed 100 % of the fleet and the client had nothing to connect to.
The safeguard was strictly worse than the thing it protected against.

**Fix.** Privacy is now a *labelling* rule, not a *visibility* rule:

| Function | Behaviour |
| --- | --- |
| `visibleNodes()` | unchanged strict filter, still used by tests |
| `selectableNodes()` | same filter, but returns the raw fleet if filtering would leave zero nodes |
| `fleetIsInternalOnly()` | true when every node would be hidden |
| `publicNodeTitle()` | country / city / region, never the handle; falls back to the caller's label |
| `publicNodeSubtitle()` | city / region / country, `null` when it would repeat the title |

`DesktopVpnController.userVisibleNodes` uses `selectableNodes`, and
`pickBestNode` is called with `internalBuild: AppConfig.internalBuild ||
fleetLooksInternal` so Auto scores the node normally instead of reporting
`no_available_nodes`. Every place that used to print `displayTitle` /
`displaySubtitle` (home server pill, server list rows, server search, servers
screen auto row, tray tooltip and tray menu) now goes through
`publicNodeTitle` / `publicNodeSubtitle`.

**Net effect:** the node connects, and its internal handle still never reaches
the screen, the tray, or a log line the user can read.

`nodesError` is now only set when the API genuinely returns an empty list, and
it is localised (the old English-only banner sat in a Russian UI).

---

## 2. Installer: `CreateProcess failed; code 740`

Error 740 is "the requested operation requires elevation". Setup runs elevated
and launches the client with `runasoriginaluser`, which goes through
`CreateProcessAsUser` - a call that *cannot* elevate. Windows thought
`glukvpn.exe` needed administrator rights, so the launch failed on the last
page of the installer.

Three changes, all needed:

1. `windows/runner/runner.exe.manifest` now declares
   `requestedExecutionLevel level="asInvoker" uiAccess="false"`. The Flutter
   template omits `trustInfo` entirely, which leaves the decision to Windows
   installer detection heuristics.
2. `installer.iss` adds `shellexec` to the launch flags, so the shell performs
   the launch and honours that manifest.
3. `installer.iss` deletes any stale `AppCompatFlags\Layers` value for
   `{app}\glukvpn.exe` in both HKCU and HKLM - a `RUNASADMIN` layer recorded by
   an earlier build would re-create the same failure on every launch.

The client never needs elevation: all privileged work lives in the
`GlukVpnTunnel` service.

---

## 3. Tray icon was a power glyph, not the logo

Round 2 made `make-icons.ps1` skip existing files unless `-Force` was passed,
to avoid overwriting hand-made icons - and `build-all.ps1` calls it *without*
`-Force`. So the placeholder icons generated once, long ago, survived every
rebuild.

Inverted: regenerating is now the default, and `-KeepExisting` opts out. The
logo is also drawn larger inside the tray frame (`0.70` -> `0.78` of the frame)
and the state dot smaller (`0.34` -> `0.28`), so at 16 px the icon reads as the
GlukVPN logo with a coloured glow rather than as a coloured blob.

---

## 4. Tray context menu was light on a dark desktop

The Win32 menu is drawn by the OS, so it cannot be themed from Flutter. It is
now themed through uxtheme:

- `WindowFx.systemPrefersDark()` reads
  `HKCU\...\Themes\Personalize\AppsUseLightTheme`;
- `SetPreferredAppMode` (undocumented uxtheme ordinal 135) + `FlushMenuThemes`
  (136) are called with `ForceDark` or `ForceLight` to match;
- `TrayController` refreshes the theme on every right-click, so switching the
  Windows theme takes effect without a restart.

Every call is wrapped in try/catch: on a build where those ordinals are absent
the menu simply stays the system default.

---

## 5. Mini panel: glowing side edges, dead space, small button

- **Edges.** The panel drew its own `ClipRRect` + border while DWM also rounded
  the window, so two rounded shapes were offset by a pixel or two - which reads
  as a glowing edge down each side. The panel is now a flat `ColoredBox`, and
  the rounding comes only from DWM (`DWMWA_WINDOW_CORNER_PREFERENCE`), with
  `DWMWA_BORDER_COLOR = DWMWA_COLOR_NONE` so no border is painted at all.
- **Dead space.** The connect button now sits in an `Expanded` + `Center`, so it
  absorbs whatever height is left over instead of leaving a gap at the bottom.
- **Size.** Button 108 -> 134 px, panel 316x352 -> 320x356.

---

## 6. Main window: square, bigger button, bigger map, smaller banner buttons

| | before | after |
| --- | --- | --- |
| default window | 1180 x 740 | **1160 x 1000** |
| minimum window | 960 x 660 | **1000 x 780** |
| connect button | 186 | **232** |
| banner button padding | 14 / 9 | 11 / 6 |
| banner button text | 12.5 | 11.5 |

The map card keeps filling the stage height, so +260 px of window height goes
almost entirely to the globe. Nothing is cropped: the world is fitted by width.

`settings.json` gained `"version": 2`; a v1 file has its stored window geometry
dropped exactly once, otherwise everyone who already ran the old build would
keep the old narrow window forever.

---

## 7. Advanced settings, ported from the browser extension

The extension exposes `settings.advanced` ("Channel, protocol and exclusions
for direct connections") and `settings.bypass` ("Always direct"). The desktop
client now has the same block:

- **Always direct** - hosts / IPs / CIDRs that never enter the tunnel. Stored as
  `bypassRoutes` and passed to the service as `TunnelUpOptions.bypassRoutes`.
- **MTU** - now visible in every build (was internal-only), 1280-1500.
- **Protocol** - `WireGuard - NT`, read-only.
- **Network adapter** - read-only.
- **Channel** - read-only. There is deliberately still no API URL field.
- **Test the server** - measures latency to the selected node.

**Diagnostics** also moved out of internal-only builds: service state, number of
available servers, *Copy* for the full report, and *Repair the service* when the
SCM says it is not running. The report contains no keys and no passwords.

---

## 8. Animations: one switch instead of two

"Animations" and "Reduce motion" did almost the same thing. Now:

- **Animations** - on/off.
- **Save power: no animations on battery** - default on. `PowerMonitor`
  (`battery_plus`) watches for discharging + Windows battery saver, and
  `DesktopSettings.motionDisabled(onBattery:)` folds that into one answer.

`reduceMotion` is still read and written so existing `settings.json` files keep
working. The VPN lifecycle is never affected by power state - only animation.

---

## 9. Quick start is now the first thing in Settings

A highlighted card at the top: *Start with Windows*, *Start minimized to tray*,
*Connect on launch*. "Start minimized" is no longer greyed out behind "Start
with Windows", because launching hidden is useful on its own. With all three on,
the client comes up invisible, brings the tunnel up in the background, and the
first thing the user sees is an already-connected window.

---

## 10. Account panel

Was: username, ID, plan, Logout. Now: avatar, username, active/free badge,
public ID, e-mail with a verified marker, origin country, member-since,
subscription and expiry, concurrent-session limit, and the real device list from
`GET /api/devices` - platform icon, "this device" marker, connected state, last
seen, `n / max` counter, and per-device removal (never for the current device).
Removing a device does not delete its traffic history.

---

## 11. Nunito on Android

`theme/app_theme.dart` switched from `GoogleFonts.poppinsTextTheme` to
`GoogleFonts.nunitoTextTheme`. Weights and sizes are untouched, so the mobile
layout does not shift; only the family changes, matching the desktop client.

Future improvement: bundle the Nunito TTFs in `assets/fonts/` so the first
launch does not need the network.

---

## Files touched

```
flutter-client/windows/runner/runner.exe.manifest
flutter-client/lib/config.dart
flutter-client/lib/main_windows.dart
flutter-client/lib/theme/app_theme.dart
flutter-client/lib/desktop/logic/node_selector.dart
flutter-client/lib/desktop/services/window_fx.dart          (new)
flutter-client/lib/desktop/services/power_monitor.dart      (new)
flutter-client/lib/desktop/state/desktop_settings.dart
flutter-client/lib/desktop/state/desktop_vpn_controller.dart
flutter-client/lib/desktop/state/window_controller.dart
flutter-client/lib/desktop/state/tray_controller.dart
flutter-client/lib/desktop/screens/desktop_shell.dart
flutter-client/lib/desktop/screens/desktop_home_screen.dart
flutter-client/lib/desktop/screens/desktop_servers_screen.dart
flutter-client/lib/desktop/screens/desktop_settings_screen.dart
flutter-client/lib/desktop/screens/mini_panel.dart
flutter-client/lib/desktop/widgets/secure_banner.dart
flutter-client/lib/desktop/widgets/server_row.dart
flutter-client/test/desktop/node_privacy_test.dart
flutter-client/test/desktop/settings_roundtrip_test.dart
desktop/packaging/installer.iss
desktop/packaging/make-icons.ps1
```

## Rebuild

```powershell
powershell -ExecutionPolicy Bypass -File desktop\packaging\build-all.ps1 -Channel prod -Installer -MakeIcons
```

`-MakeIcons` now really regenerates the tray and app icons from
`flutter-client/assets/logo.png`.
