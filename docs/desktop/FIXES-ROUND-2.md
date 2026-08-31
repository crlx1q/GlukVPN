# GlukVPN Desktop — round 2 fixes

Everything below is on branch `desktop/beta`. Android and the browser extension
are untouched: no shared file changed behaviour for them, and the only edit
outside `lib/desktop/` is one new constant value in `lib/config.dart`.

---

## 1. "The VPN does not connect and does not even see a server"

Three separate bugs stacked on top of each other.

### 1a. The authenticated transition was lost (root cause of the empty list)

`main_windows.dart` used to do:

```dart
await _auth.bootstrap();          // session restored HERE
...
_auth.addListener(_onAuthChanged); // listener attached only afterwards
```

With a saved session the `unauthenticated -> authenticated` notification fired
while nobody was listening, so `DesktopVpnController.bootstrap()` was never
re-run and `GET /api/nodes` was never called again. The list stayed empty until
the app was reinstalled. The listener is now attached **before**
`_auth.bootstrap()`.

### 1b. Node loading was chained behind the tunnel-service probe

```dart
ServiceBootstrap(...).ensureInstalledAndRunning().then((_) => _vpn.bootstrap());
```

If the elevation prompt was dismissed, or the named-pipe probe timed out, or the
future threw, `bootstrap()` never ran at all — no servers, no public IP. That
also explains the surprise UAC prompt at launch.

Now: `bootstrap()` runs the node fetch and the service probe **concurrently**,
each wrapped in its own `try/catch`, and the service is only *probed* at
startup. Elevation happens only when the user presses **Connect** or
**Install service**.

### 1c. Every failure was swallowed

`refreshNodes()` ended in `catch (_) { }`. "Servers failed to load" was
indistinguishable from "there are no servers". Now every path records a reason:

| Situation | What you will see |
| --- | --- |
| HTTP error | `Request failed (HTTP 401 · TOKEN_EXPIRED)` |
| Network error | `... (cannot reach https://api.gluk.tech)` |
| Empty response | `The control plane returned an empty server list.` |
| All nodes filtered as internal | `All 2 servers were filtered out as internal.` |
| Tunnel service down | the exact pipe/SCM message |

Also added:

- **Retry with backoff** (3 s, 8 s, 20 s, 45 s) instead of one silent attempt.
- **Graded Auto selection.** `pickBestNode` only returns nodes that are both
  `online` **and** `connectable`; with a small fleet or a stale heartbeat that
  returns nothing, which is why the server row printed
  `Авто · Лучший сервер` twice and Connect had no target. It now degrades:
  best -> any online -> any visible, and records the reason
  (`fallback_online_not_connectable`, `fallback_offline_node`, …).
- **A rolling log** at `%APPDATA%\GlukVPN\logs\ui.log` plus an in-memory ring
  buffer. Secrets (keys, tokens) are scrubbed before writing.
- **Copy log** button on the home strip. It copies the full state dump plus the
  log; if the VPN still refuses to connect, paste that and the cause will be
  visible immediately.

### If it still fails, the log now names the culprit

```
... INFO [service] SCM reports ServiceInstallState.notInstalled
... FAIL [nodes]   GET /api/nodes failed :: 401 TOKEN_EXPIRED ...
... FAIL [connect] tunnel up rejected :: driver_unavailable ...
```

`driver_unavailable` means `tunnel.dll` / `wireguard.dll` are missing from
`C:\Program Files\GlukVPN\service\` — see `BUILD-WINDOWS.md`, the vendor DLLs
are deliberately not committed.

---

## 2. "Strange highlighting and underlines, and Nunito is missing"

**Root cause of the yellow double underlines.** The desktop shell's root was a
`ColoredBox`, so nothing in the tree had a `Material` ancestor. In that case
`MaterialApp` leaves its *error* `DefaultTextStyle` in place, which carries
`decoration: TextDecoration.underline` with a yellow decoration colour. Every
`Text` that set its own colour and size but no `decoration` merged that
underline in — which is exactly why labels inside `TextField`s and dropdowns
(which do have a `Material`) looked fine while every other label did not.

Fixed in three layers, so it cannot come back:

1. `MaterialApp(builder: DesktopTheme.appBuilder)` wraps the whole tree in
   `Material(type: MaterialType.transparency)` plus a real `DefaultTextStyle`.
2. Every style in the desktop text theme sets `decoration: TextDecoration.none`.
3. Text scaling is clamped to 1.0–1.15 so a Windows display setting cannot
   break the fixed layout.

**Font.** Mobile uses Poppins; you asked for Nunito. The desktop client now
builds its type scale on `GoogleFonts.nunitoTextTheme` with the same size and
weight rhythm as mobile, and `fontFamilyFallback` of
`Segoe UI Variable Text -> Segoe UI -> Poppins -> Arial` for the first launch on
a machine that has not cached the font yet. New file:
`lib/desktop/theme/desktop_theme.dart`.

---

## 3. Interface rebuilt to match the reference mock-up

| Before | Now |
| --- | --- |
| 84 px icon rail | 236 px sidebar: logo tile + wordmark, tall nav pills, account card with avatar and `ID …` |
| Oversized empty map on the left, controls stacked in a narrow column | One map card holding the state pill, the location line, the power button and the server row |
| Four small metric tiles + a traffic panel | Right rail: **CONNECTION** (public IP, VPN IP, duration, ping) and **TRAFFIC** (downloaded, uploaded) with hairline separators |
| Nothing at the bottom | Full-width strip: "Your connection is secure" when up, and the problem + action + **Copy log** when not |
| Logo and title in the caption bar | Caption bar is now just the three window buttons; branding lives in the sidebar |
| Server row could print its own title twice | Subtitle is suppressed when it would duplicate the title |

New widgets: `desktop_sidebar.dart`, `info_panel.dart`, `status_pill.dart`,
`server_pill.dart`, `secure_banner.dart`. The globe, the connect button and all
colour/motion tokens are still the shared mobile ones.

---

## 4. Tray and mini window

Exactly the mapping you described (JBL Quantum style):

| Input | Result |
| --- | --- |
| Right click | the context menu, unchanged |
| **Single left click** | the small panel, pinned just above the notification area |
| **Double left click** | the full window |
| Click elsewhere | the panel dismisses itself on focus loss |

Windows sends one `mouseDown` per physical click with no double-click event, so
the two are separated by a 280 ms debounce in `TrayController`.

The panel used to be placed by nudging the window +16/+16 from wherever it
happened to be, which dropped it in the middle of the screen.
`lib/desktop/services/work_area.dart` now asks Win32 `SPI_GETWORKAREA` for the
usable desktop rectangle (screen minus taskbar) and pins the panel to the
corner, DPI-corrected. It is also `skipTaskbar` + always-on-top while in panel
mode, like a native panel.

Size dropped from 340×420 to **316×352**, and the content is now only: header,
state pill, connect button, server + ping, download + upload.

**Tray icon.** `make-icons.ps1` was rewritten to build all four state icons
*from `assets/logo.png`* — the real logo with a state-coloured halo (violet
idle, amber connecting, green connected, red error) and a small status dot in
the corner, since a halo alone is unreadable at 16 px. It embeds PNG frames at
16/20/24/32/40/48 px. Existing files are kept unless you pass `-Force`, so the
icons you already made with the other agent are not overwritten by accident:

```powershell
powershell -ExecutionPolicy Bypass -File desktop\packaging\make-icons.ps1 -Force
```

---

## 5. Installer

| Problem | Fix in `desktop/packaging/installer.iss` |
| --- | --- |
| "Install for all users / for me only" page | `PrivilegesRequiredOverridesAllowed=` (empty) — that setting was `dialog`, which is what produced the page. Plus `UsePreviousPrivileges=no`. Setup now just asks for admin once. |
| "Administrator rights are required" on the last page | The `[Run]` entry launched `glukvpn.exe` from the elevated installer, so the app inherited the admin token. Added `runasoriginaluser`: the service is registered elevated, the client starts as you. |
| Stray leading space on `OutputBaseFilename` | Removed. |
| Unused `[Code]` variables | Removed. |

---

## Build

```powershell
powershell -ExecutionPolicy Bypass -File desktop\packaging\build-all.ps1 `
  -Channel prod -Installer -MakeIcons
```

No new package dependencies: the work-area probe uses `dart:ffi` against
`user32.dll` directly, so `pubspec.desktop.yaml` is unchanged.

## What to check after installing

1. No "all users / just me" page, and no admin error at the end.
2. Login screen: no yellow underlines anywhere, Nunito everywhere.
3. Home: sidebar, map card, CONNECTION/TRAFFIC rail, bottom strip.
4. If the server list is empty the bottom strip states **why** — send me that
   text, or press **Copy log** and paste it.
5. Tray: 1 click -> small panel above the clock, 2 clicks -> full window,
   right click -> menu.
6. Close the window: the tunnel keeps running, tray icon stays coloured.

## Not done in this round

- The Settings screen keeps its current structure; it inherits the font and the
  underline fix but was not re-composed.
- Nunito is still fetched by `google_fonts` at runtime. To make it fully
  offline, drop the TTFs into `flutter-client/assets/fonts/` and declare a
  `fonts:` block in `pubspec.desktop.yaml`.
- Nothing here was compiled or run: there is no Flutter/MSVC toolchain on my
  side, so the build check is still yours.
