# Round 5 fixes

Everything below is on branch `desktop/beta`. PROD is untouched.

---

## 1. The whole PC lost its internet connection

**Report:** "туннел подкл впн не сработал а теперь и на всем пк нету инета"

**Cause.** `Tunnel::Up()` starts the WireGuard worker thread, arms the WFP
kill switch and returns `true`. `Wfp::DisableKillSwitch()` was only ever called
from `Tunnel::Down()`. When the worker exited by itself - which is exactly what
happened, 1.7 s after "tunnel up accepted" - nothing released the block-all
filters. They are session filters on a `FWPM_SESSION_FLAG_DYNAMIC` session tied
to the *service process*, and the service was `SERVICE_AUTO_START` with three
restart actions, so it never died and the filters never lapsed. Result: no
internet for any application until the service was stopped or the PC rebooted.

**Fixed in four places.**

| File | Change |
| --- | --- |
| `native/.../tunnel.cpp` | `WorkerMain` now calls `ReleaseNetworkLocks("worker exited")` the moment the worker returns, before taking the lock. New `Tunnel::ReleaseNetworkLocks()` drops the WFP filters and the split-tunnel routes. `Up()` also clears stale locks if it finds `killSwitchActive` with no worker running, and `Status()` self-heals. |
| `desktop_vpn_controller.dart` | `_fail()` tears the tunnel down on every failure phase, so the client side cannot leave filters behind either. New public `releaseNetworkLocks()`. |
| `desktop_settings_screen.dart` | Settings → Diagnostics → **Восстановить интернет**. Requirement 2 says the user never opens a terminal. |
| `service.cpp` | Third failure action is `SC_ACTION_NONE`, reset period 1 h. A service that respawns forever cannot be stopped. |

**If it happens again before the rebuild:** `net stop GlukVpnTunnel` from an
administrator prompt, or reboot. The filters die with the service process.

---

## 2. Why `GlukVpnTunnelService` was always in the background

It was registered `SERVICE_AUTO_START`: it started with Windows and stayed up
with the app closed, doing nothing.

- `service.cpp` → `SERVICE_DEMAND_START` in both `CreateServiceW` and
  `ChangeServiceConfigW`. The app starts it when it needs a tunnel.
- `service.cpp` → `SetServiceObjectSecurity` with a DACL granting Interactive
  Users `SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS`. Without this the
  app could only ask for elevation, which is why leaving the service running
  was cheaper than stopping it.
- `service_bootstrap.dart` → new `stopService()` (`ControlService`,
  `SERVICE_CONTROL_STOP`), no UAC prompt.
- `desktop_vpn_controller.shutdown()` releases the filters and stops the
  service when it is leaving without an active tunnel.

After the next install: nothing of ours runs at boot, and nothing of ours
survives tray → Exit.

---

## 3. `tunnel_error` - why the VPN still would not connect

The worker started and died in about a second. `WorkerMain` mapped every
`ok == FALSE` to `tunnel_error`, which said nothing.

**Cause: a mismatched DLL pair.** `wireguard.dll` came from
`wireguard-nt-1.1.zip`, while `tunnel.dll` was built from the
`wireguard-windows/embeddable-dll-service` git master. `tunnel.dll` speaks
exactly one `wireguard.dll` ABI, and the two ship together in
`embeddable-dll-service-amd64-<version>.zip` for that reason.

- `desktop/packaging/build-all.ps1` and `.github/workflows/build-desktop.yml`
  now fetch the matched pair first, trying releases `0.5.3`, `0.5.2`, `0.4.9`.
  WireGuardNT and the Go build are fallbacks only.
- `tunnel.cpp` distinguishes `tunnel_start_failed` (worker died within 5 s -
  almost always the pairing) from `tunnel_error`, logs the driver description
  and how long the worker ran.
- `diagnosticsDump()` appends the last 40 lines of the *service* log. The UI
  log alone could never explain a failure that happens inside the service.
- `_humanise()` translates `tunnel_start_failed`, `tunnel_error`,
  `tunnel_lost`, `tunnel_service_unavailable` and `connect_timeout`.

If the rebuilt client still reports `tunnel_start_failed`, the pairing is still
wrong: send `dist\stage\service` and the service log.

---

## 4. Wrong self-location (Kyrgyzstan instead of Kazakhstan)

`countryForUtcOffset` scored countries by longitude. UTC+5 implies 75°E;
Kyrgyzstan sits at 74.8°E and Kazakhstan at 68°E, so Kyrgyzstan won by seven
degrees every single time. Longitude cannot break that tie.

- `utils/geo.dart` → new curated `utcOffsetCountries` table, keyed by offset in
  minutes, consulted before the geometry. UTC+5 → `KZ, UZ, PK, TM, TJ, KG`.
- A locale region inside the same timezone wins over the ranking, so `ru_KZ`
  and `ru_UZ` both resolve correctly.
- `design_test.dart` expectations updated from `KG` to `KZ`. That assertion was
  pinning the bug in place.

---

## 5. Flags, and the bare "кг" on the home screen

Windows does not render regional-indicator emoji, so the flag arrived as the
literal text "кг".

- `widgets/flag_art.dart` → painted `KG`, `UZ`, `TJ`, `TM`, `AZ` (`KZ` and `DE`
  were already there).
- `LocationLine` takes a `countryCode` and draws `FlagArt`, falling back to the
  globe badge. No emoji ever reaches the home screen again.

On caching downloaded flag images for 200+ countries: the painted set now
covers every country we can plausibly place a user in, and a missing one
degrades to a neutral badge rather than raw text. Say the word and I will add
the download-and-cache path in AppData as well.

---

## 6. City, then country - everywhere

New `flutter-client/lib/utils/geo_dictionary.dart`, the Flutter mirror of
`extension/lib/geo.js`: ~85 countries and ~90 cities in RU and EN, plus
coordinates. Same three-step recipe as your note, documented at the top of the
file:

```dart
'NL': LocalizedName('Нидерланды', 'Netherlands'),   // geoCountries
'amsterdam': LocalizedName('Амстердам', 'Amsterdam'), // geoCities
'amsterdam': GeoPoint(52.37, 4.9),                     // cityCoords
```

New `publicNodeLocation(node, {russian})` → `"Frankfurt, Германия"`. Wired into
the desktop home pill, the server list, the server rows, the mini panel, the
tray tooltip and menu, and the phone server list.

`publicNodeTitle` / `publicNodeSubtitle` keep their old contracts - the privacy
tests pin them - so no internal handle can leak through the new label either.

---

## 7. Map animation looped with a jump

`_orbit` runs 0 → 1 and was mapped straight onto -4° → +4° of drift, so every
cycle ended with an eight-degree snap and the whole drift replayed. Folded into
a triangle wave: the drift travels out and back, the ends meet, the loop is
seamless like the phone version.

---

## 8. Window size and the collapsed layout

Photo 6 was not a styling problem, it was a breakpoint problem. The window was
1080 px wide; minus the 236 px sidebar and 36 px padding the content area was
808 px, and the home screen only switched to three columns at 900. So it always
rendered the single-column fallback: map on top, connection block under it,
traffic below, empty bands above and below the map.

- `AppConfig.desktopMinSize` / `desktopDefaultSize` → `1000 x 780`.
- `DesktopTokens.sidebarWidth` 236 → 208, `rightRailWidth` 304 → 272.
- Home breakpoint 900 → 700, so 756 px of content engages the mockup layout.

The window is still fixed and non-resizable.

---

## 9. Tray icon

"побольше сделай и без света ток лампочка" - `make-icons.ps1`: the halo moved
behind a `-WithHalo` switch that is off, and the tray logo scale went 0.74 →
0.98. The coloured status dot stays. The glow was eating about a quarter of a
16 px icon, which is why it looked small.

Regenerate with `-MakeIcons -Force`.

---

## 10. Login screen planet

`globeAnchor` `(0.5, 0.58)` → `(0.33, 0.56)` and `zoom` `1.02` → `1.72`, so it
fills the violet panel and bleeds off its left edge like the Cloudflare
reference. Panel widened slightly, 45 → 48 of the split.

---

## 11. Beta channel: admins only

- `channel_controller.dart` → `canSwitchAs(AuthUser?)` = build allows beta
  **and** `user.isAdmin`.
- Phone `settings_screen.dart` → both the channel panel and the diagnostics
  panel are gated on it.
- Desktop `desktop_settings_screen.dart` → the Channel row only renders for
  admins.
- Extension `popup.html` / `popup.js` → the channel field starts hidden and is
  revealed only when the account reports `isAdmin`.

The server already refuses non-admins on beta; this makes the UI tell the same
story.

---

## 12. Extension parity

- HTTP removed from the protocol list, and a stored `http` value is migrated to
  `https` on load.
- Gateway host placeholder and hint now say `de-01.gluk.tech` - address the node
  by domain, not by digits.
- Device list gained the same three filter buckets as the desktop client
  (Все / Активные / Отозванные).

Note: the extension folder is in `.gitignore`, so these edits are on disk but
not in the commit.

---

## Still open

- **Statistics screen** - you flagged it as a separate task, and it is.
- **Downloaded flag cache** for countries with no painted art.
- Extension device-filter click handler still needs wiring to `renderDevices`;
  the controls and styles are in place.
- Bundled Nunito TTFs instead of the Google Fonts fetch.
- Authenticode signing plus `WinVerifyTrust` in `pipe_server.cpp`.

## What I need from you

1. `powershell -ExecutionPolicy Bypass -File desktop\packaging\build-all.ps1 -Channel prod -Installer -MakeIcons`
2. `flutter analyze` output if anything fails to compile.
3. After installing: the diagnostics dump again. It now carries the service
   log, which is where the real tunnel failure is recorded.
