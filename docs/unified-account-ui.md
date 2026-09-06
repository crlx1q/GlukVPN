# Unified account presentation and connection map

## Scope
- Website, Windows/Android Flutter client and Chrome extension use plan names: Free, Basic, Pro, β Pro. A plan name is independent of subscription expiry or account blocking; those controls remain enforced.
- The earlier ZIP was used as a visual reference, not restored wholesale. The existing background world remains the only map in the Flutter home screen; the desktop connections sheet is a list without a second map.
- Website login returns to a complete round dotted planet. Desktop login already uses the spherical DottedWorld projection.
- Website tester badge markup is preserved during account-state resets. Device management uses SVG icons rather than emoji.

## Shared data contract
All clients use GET /api/user/active-map for their authenticated account in the selected API channel. Production and beta are intentionally separate. Polling is normally every 5 seconds while visible; this is near-real-time polling, not a WebSocket guarantee.

The response contains all account devices with current sessions (one latest session per device), no first-five truncation. activeTunnels counts ACTIVE records; pendingTunnels counts PENDING records. Pending sessions are not drawn as established connections. Locations are approximate IP-country locations and the actual node coordinates. Missing geography is not invented. Devices sharing a point are grouped; their labels remain available.

Flutter markers use the exact same projection as the background painter. Map points are NOT interactive on any surface (see the third pass below): a one-pixel dot cannot be hit reliably, so every device detail lives in the "Devices" panel instead. Authentication changes invalidate snapshots, and map requests time out after 15 seconds. The extension clears stale responses on logout, channel changes and failed requests.

## Infrastructure-budget permission
The analytics route derives includeBudget ONLY from the authenticated server-side isAdmin role. Ordinary users receive budget:null, and no OCI budget query is performed for them. Admin responses carry budget.adminOnly:true. Flutter hides the entire section unless this marker exists; web additionally checks the current admin role. This is not a user traffic quota.

Deploy the control server and updated clients as one coordinated release; do not upload only JavaScript without the new script references. The original pass required no database migration. The follow-up below adds an optional device column and requires migration before release. No infrastructure reconfiguration or deployment was performed.

## Verification
Executed in the sandbox: syntax check and Chromium tests of the exact new account-map-ui.js with the reference world dataset: 7 simultaneous routes, grouped devices, tap details, 320/390/900 px widths, pending/missing-coordinate/empty states, untrusted labels; no browser exceptions.

Added automated assertions in site/tests/site.test.cjs and flutter-client/test/account_plan_display_test.dart. These new repository suites have not been executed in the connected workspace. `npm run typecheck` failed before starting the compiler with `spawn npm ENOENT`; Flutter SDK is unavailable in the sandbox. This is not a claim that Windows/Android or extension builds passed.

Before release:
1. Run `npm run typecheck` and `npm test` from the repository root.
2. Run `npm test --prefix site`.
3. Run `flutter analyze` and `flutter test` in flutter-client; build/test Windows and Android normally.
4. Test one ordinary account and one administrator: budget:null vs admin-only object.
5. Connect at least two devices to different nodes in the SAME API channel; verify updates from each platform, disconnection, logout/relogin, unknown geography and network failures.
6. Reload the unpacked Chrome extension; confirm map, subscription chip and channel-switch clearing. Verify registration/login are unaffected.

## Follow-up: restore the original connection route (2026-09-05, second pass)

The reference ZIP was extracted and compared. Desktop originally used zoomBoost=1.62; the reduced 0.95 globe is restored to 1.62. Local current-device routes no longer depend on the presence of an account-map response: an empty/unknown-geo response cannot suppress a locally confirmed route. A valid current-device account arc suppresses only its own duplicate. Mobile camera fitting includes every account route, rather than cropping remote devices outside the selected route's framing.

The account list is now deliberately map-free regardless of the old showMap flag. Windows and Android share AccountDevicesButton and the same scrollable cards; Chrome uses the same layout, fields and Material devices icon. The third pass below replaces the bottom sheet / `<dialog>` with an anchored translucent dropdown on all four surfaces. Web/Chrome device icons are unchanged ready-made Material glyphs rasterized into a local PNG sprite, not hand-drawn SVG paths. They correspond to Flutter Icons.devices/computer/smartphone/web/dns. Attribution: Google Material Design Icons, Apache-2.0, https://github.com/google/material-design-icons; exported through react-icons/md. Do not replace these with emoji or custom SVG approximations.

### REQUIRED server update for cross-device positions

New optional devices.map_country_code column, migration 20260905210000_session_map_origin (despite its name, the final migration adds a DEVICE column). Apply normal Prisma migrations and regenerate the client BEFORE running the new server. No migration has been executed by the assistant.

POST /api/user/map-origin accepts ONLY {countryCode}, derives account and device identifiers from the authenticated device-scoped token, rejects extra keys and unsupported codes, and updates only that active device. Existing rows stay null. The country estimate is recorded even before a connection is opened, so an extension popup can close without losing the future session's fallback location. Changing display geography never changes VPN routing, entitlements, handshake state or access control.

Windows/Android send their device-local country estimate (existing locale/timezone resolver, WITHOUT the shared account origin). Chrome sends its own timezone's country. These are WEAK estimates, not measured physical locations or GPS. IP-derived location remains preferred when GeoIP is enabled and succeeds; otherwise active-map uses the device's labelled `device-estimate`. The frontend labels the approximation. No user's country is copied to another user's or another device's record. Unknown countries stay unknown. Devices can be in the wrong country if their clock/locale is set incorrectly; real GeoIP is still preferable.

Release order: database migration + Prisma generate → control server → site assets and rebuilt Windows/Android clients → reload extension. Then open each client once to report its region. Updating only the UI cannot populate absent server-side positions. Keep production and beta separate.

Verification: npm run typecheck was attempted again; the connection returned `spawn npm ENOENT` before compilation. Full Flutter build/analyzer and live multi-device verification remain required. Added account-map-origin.test.ts and account_map_camera_test.dart for the regression cases. No push/deployment was performed.

Executed follow-up checks: isolated production map-service functions with mocked database/provider dependencies (country isolation for two devices, GeoIP disabled, IP preference when enabled, unknown geography, pending-vs-active counts, authenticated write filters); Chromium tests of the updated web map (seven routes, grouping, interaction, 320/390/900px, untrusted labels). These are component checks, not a live server or native Flutter test. Copy docs/licenses/Material-Icons-Apache-2.0.txt into third-party notices when packaging the site/extension.

## Follow-up: one UI language on all four surfaces (2026-09-06, third pass)

Pure UI/UX pass. No API, schema, routing or entitlement behaviour changed; `GET /api/user/active-map` and `POST /api/user/map-origin` are untouched.

### Single hero order

Site `/app`, Windows, Android and the Chrome popup all lay the hero out in the same order: status pill -> "You . country" -> power button -> server card, with the devices chip pinned to the top-right corner. The extension previously rendered its location row below the power blob, which was the only remaining structural difference; `popup.html` now moves `.loc-row` directly after `#status-badge`.

### Devices chip and anchored dropdown

The chip carries **no text**. It is a single square icon tile, and the count sits **inside it** as a circular badge overlapping the bottom-right corner. The word "Devices"/"Устройства" and the separate chevron are deleted on every surface: at this size a label only collided with the status pill next to it. The count is announced through `title`/`aria-label` (`Устройства онлайн: N`), and the badge is hidden entirely at zero.

Tapping it opens a translucent panel anchored under the chip:

| token | value |
| --- | --- |
| panel surface | `rgba(23,18,42,.94-.97)` + `blur(18px)`, border `rgba(196,181,253,.20)`, radius 18, padding 11, shadow `0 20px 48px rgba(0,0,0,.62)` |
| panel width | `min(300px, 100vw - 32px)`, list `max-height min(52vh, 400px)` |
| chip | icon-only 36-40px tile, radius 12-13, bg `rgba(26,20,40,.90)`, border `rgba(139,92,246,.38)` -> `.70` when open, glyph 19-20px `#c4b5fd` |
| count badge | circular 17-18px at `right:-6 bottom:-6`, bg `#6d4de0`, 2px page-bg ring, text `#efe7ff` 800 10-10.5px |
| device row | `36px | 1fr | auto` grid, gap 10, padding 8, radius 14 |
| icon tile | 36px, radius 12, bg `rgba(139,92,246,.20)`, glyph 19px `#c4b5fd` |
| row text | name 13 `#f5f3fb` 700 / meta 11 `#9b93ad` / route 11 `#bfb4d4` |
| online dot | 7px `#3ddc97` + `0 0 9px rgba(61,220,151,.85)` |

The panel is one step smaller than the second pass (width 320 -> 300, radius 20 -> 18, padding 13 -> 11, tile 44 -> 36) because it now has to sit next to the status pill on a 320px phone without overlapping it.

### Device detail screen

The `>` at the end of a row is a real 32-34px button, not decoration. Pressing it swaps the panel body for a detail view of that one device; the header grows a back arrow that returns to the list, and the "N connected" summary line is hidden while the detail is open. Rows are label-left / value-right: exit server, node city, uptime, location, accuracy, plus a violet note when the row is the current device. If the opened device disappears from a poll, the panel falls back to the list instead of showing a dead screen.

Implementations: `_AccountDevicesPanelState._openedId` + `_DeviceDetail` (Flutter), `panel.dataset.glukDetail` + `detail(d)` (site), `accountDetailId` + `accountDeviceDetail()` (extension).

What this replaces: the extension's `<dialog class="account-devices-sheet">` (its non-transparent backdrop painted over the server card, which is the bug in screenshot 5) and the Flutter `showModalBottomSheet` (an alien bottom sheet on Windows). Both are now the same anchored dropdown: `.account-devices-pop` in the extension, `_AccountDevicesPanel` behind `showGeneralDialog` with a transparent barrier in Flutter, `[data-gluk-panel]` on the site.

The row no longer prints the `~ device region estimate` / `~ IP country` line. The estimate is still labelled where it matters (map origin, docs above), but repeating it on every card was the noise visible in screenshot 3.

### Non-interactive map points

Hover/tap affordances on map dots are removed on every surface, because a dot rendered at `r <= 1.2` map units is not a realistic hit target:

- Site: the `.account-map-point` buttons, the `[data-map-detail]` popover and the "hover or tap a point" hint are gone.
- Extension: `tabindex`, `aria-label` and the per-dot `<title>` are gone (the route `<path>` keeps its title); the `pointer-events/cursor:help` rules are deleted.
- Flutter: `_DottedWorldPainter.connectionMarkers` and its 36px `Tooltip` hit boxes are deleted.
- Android: the map-inspection toggle ("Inspect background map") is deleted, so the phone and Windows now expose literally the same devices UI.

Accessibility is not reduced: the same device names, platforms, routes and states are announced by the panel rows, which are full-size targets.

### Connection threads and the two dots

Styled after the original desktop preset (`world_stage.dart` / `dotted_world.dart` in v3): a thin dashed thread with a soft lift instead of a flat line, one marker per end, each with a translucent halo.

**Colour direction (corrected).** Violet is **me** - the device, placed by its own location. Green is the **exit server**, whether it was picked automatically or by hand. The second pass had this backwards; the thread now fades `#c4b5fd` (device) -> `#3ddc97` (server) on all four surfaces, and the gradient stop in the extension's `#pathGrad` was flipped to match.

- Device marker: violet ring 26-30px (Flutter `radius max(7.5, 3.1 * flatScale)`), dark fill `rgba(26,19,48,.94)`, and the **platform glyph inside it** - laptop, phone or browser - so the map answers "which of my devices is this" without opening the panel. `paintDeviceMarker` (Flutter), `.gluk-pin` (site), `.account-pin` (extension).
- Server marker: solid `#3ddc97` dot with a green halo, pulsing `r 1 -> 1.24`.
- Grouping: devices sharing a point collapse into one marker with a violet count badge (`3` = three devices at that point). One thread per `(origin spot -> server)` pair, so two devices on the same server draw one thread and two devices on different servers draw two. The grouping key is `round(x*10):round(y*10)` - identical in Flutter, the site and the extension, so the three surfaces group the same way.
- Draw-in animation restored from the zip: the thread is drawn over `.62s` and only then starts the flowing dash (`3.6s` linear, infinite). In Flutter the arc for the current device follows the real connect phase through `arcProgress`, while already-established threads of other devices render complete.
- Site/extension: `stroke-width .4`, `stroke-dasharray 1.6 1.9`, `stroke-dashoffset` animated over 3.6s linear, halo `r 2.5`, dot `r .95`.
- Quadratic lift is proportional to span: `max(3.5, |bx - ax| * 0.16)`, so short hops stay flat and long hops bow.
- Every flow animation is disabled under `prefers-reduced-motion` / `MotionSettings.reduceMotion`.

### Icons

The white/washed-out device glyphs came from painting the Material PNG sprite directly. Site and extension now use the sprite as a CSS `mask` with `background-color: currentColor`, so glyphs inherit `#c4b5fd` and can be re-tinted per state without new artwork. The sprite, its geometry and the Apache-2.0 attribution above are unchanged; the ban on emoji/hand-drawn SVG replacements still stands.

### Mobile

No map card in the middle of the phone screen. The world stays a backdrop behind the hero; below 760px the site hides `.dash-map__stage` and `.dash-map__legend`. The chip row stays horizontal and the panel stays anchored (`min(300px, 100vw - 32px)`, `max-height 60vh`) rather than going full width - a full-width static block was what pushed the status pill out of the frame.

**Spawn framing fix.** On Android the map used to fly in from the right: the first frame had no server and no arcs, so it fell back to `legacyView`, and the un-seeded `TweenAnimationBuilder`s then animated from that fallback to `FlatMapView.fitConnections`. `_MapBackdropState` now holds the first framing still (`_framed`, `framingGrace = 650ms`, `_markFramed()`): until the route is known the transition duration is `Duration.zero`, so the app opens already centred on the frame between the device and its server, and only the slow ambient sway runs afterwards.

### Session release: disconnect used to hang

After disconnecting on Windows or Android the device stayed visible to everyone on the map and the session stayed `ACTIVE` in the admin panel. The Chrome extension was immune, which was the clue: it never raises a WireGuard tunnel, so its `POST /api/vpn/disconnect` always reaches the server.

Root cause: both Flutter controllers tore the tunnel down **first** and only then called the API. By that point the routes were gone, the HTTP call failed, and the failure was deliberately swallowed (`// The server reaps stale sessions on its own`) - but nothing actually reaped it, because the monitor only closes sessions for maintenance, disabled users, revoked devices, expired subscriptions and offline nodes.

Three changes, defence in depth:

1. **Order.** `VpnController.disconnect()` and `DesktopVpnController.disconnect()` now release the session **before** `_vpn.stop()` / `_tunnel.down()`, while the route to the API still exists, and retry once afterwards over the restored plain network.
2. **Persistence.** `_closeServerSession` / `_releaseServerSession` retry on a `0 / 400ms / 1200ms` backoff, stop early on `404` (already closed), and finish with a **session-less** `POST /api/vpn/disconnect`, which makes the server resolve the row itself via `findLiveSessionForDevice`. The id is held in `_pendingClose` until the server confirms, so a failed attempt is no longer lost - the desktop version used to null `_activeSessionId` before the call and could never retry.
3. **Server safety net.** `POST /api/node/heartbeat` already computed `missingPeers` and only echoed it back to the agent. It now closes those rows with `reason: "peer_missing"`. The node is the source of truth: no peer means no tunnel. Guards: `ACTIVE` only (`PENDING` is still waiting for `ADD_PEER`), `transport === "wireguard"` only (VLESS and browser sessions have no peer by nature), and only after a grace period of `max(60, NODE_HEARTBEAT_INTERVAL_SEC * 6)` seconds so a tunnel that is coming up right now is never killed.

The net effect is that a hung session can survive at most one grace period even if the client is force-killed, loses power or never regains network.

### Verification (third pass)

Static only. `npm` is still absent from the connected sandbox (`spawn npm ENOENT`), and there is no Flutter SDK, so no suite was executed. Checked by inspection/grep: no references remain to `connectionMarkers`, `onShowMap`, `_inspectMap`, `account-devices-sheet`, `account-map-point`, `data-map-detail` or `account-device-geo`; the strings asserted by `extension/tests/sprint2-contracts.test.mjs` (`String(normalizedError(error)?.code`, `openDeviceLimitModal`, `renderAccountMap`, `restrictionLabel`) are all still present; `accountMapArcs` semantics and the `D.deviceIcon` / `D.drawAccountMap` declaration order required by `site/tests/site.test.cjs` are preserved; `dashboard.css?v=20260905.4` was deliberately NOT bumped because the site suite pins that string.

Still required before release: `npm run typecheck` and `npm test` at the root, `npm test --prefix site`, `node --test glukvpn-extension-1.5.0/extension/tests/`, `flutter analyze` + `flutter test`, then a visual pass on 320/390/900px web, the Chrome popup, Windows and Android.

## Follow-up: stable markers, self-without-tunnel, one power button (2026-09-06, fourth pass)

Pure UI pass. No API, schema, routing or entitlement change; `GET /api/user/active-map` and `POST /api/user/map-origin` are untouched.

### Repaint guard: the extension re-animated every 5 seconds

Symptom: in the Chrome popup another device vanished and re-appeared with a freshly drawn thread on every poll, endlessly. Cause: `renderAccountMap()` opened with an unconditional `group.replaceChildren()` / `pins.replaceChildren()`, so the 5-second `active-map` poll destroyed and rebuilt identical nodes and restarted the `account-draw` / `account-pin-in` keyframes each time.

Both polled surfaces now compare a render signature before touching the DOM:

- Extension: `accountMapSig` holds `JSON.stringify` of the drawn arcs, the self/node points and the device count. `const dirty = sig !== accountMapSig` gates the clearing, the arc loop and the chip rebuild. `count.hidden`, `title`, `aria-label` and `updateAccountDevices()` stay unconditional so uptimes keep ticking.
- Site: `D.lastAccountMapSig` gates `paintThreads()` + `paintPins()`; `paintWorld()` and `paintPanel()` stay unconditional. `|| !stage.querySelector('.gluk-threads')` re-arms the guard when `sprint2.js` clears the overlay.

Flutter needs no guard: it repaints from state instead of rebuilding nodes.

### Missing Chrome glyph

`materialDeviceIcon()` already mapped `chrome|browser|ext` -> `web`, so the empty / "journal" glyph was purely CSS. The sprite modifiers used **pixel** `mask-position` offsets, but the chip, pin and row tile each set a different `mask-size`, so a fixed pixel offset landed between sprite cells. All five modifiers are now percentages of the element box - `--devices 0 0`, `--computer 25% 0`, `--phone 50% 0`, `--web 75% 0`, `--server 100% 0` - which is correct at any `mask-size` (`site/assets/css/dashboard.css`, `extension/ui/theme.css`).

### Legacy simulation removed from the extension

The old hard-coded two-dot demo route still ran under the account map: `setPoint()`, `drawRoute()`, `#conn-path`, `#you-dot`, `#you-ring`, `#server-dot`, `#server-ring` and their CSS (`.conn-path`, `.pt-ring`, `.pt-dot.you`, `.pt-dot.srv` and the `.hero.on` / `.hero.busy` variants). It painted a permanent inactive thread unrelated to real sessions. Deleted from `popup.js`, `popup.html` and `theme.css`; the former caller now only records geography (`selfLatLon`, `nodeLatLon`) and calls `renderAccountMap()`. `.hero.offline .net-node-ring` / `.map-img` keep their `animation: none !important`; `@keyframes dashFlow` is now unreferenced.

### Self marker without a tunnel

Required behaviour: opening any surface shows **where I am** even with zero connections; before this pass the map showed only the selected server. All three map surfaces now seed both ends unconditionally and skip the self marker only when a live arc already belongs to the current device:

- Flutter `dotted_world.dart`: `selfPlatform` is plumbed from `world_stage.dart` (`'computer'`) and `home_screen.dart` (`'phone'`); the account branch seeds `deviceSpots` from `selfPoint` when `!ownArc` and always seeds `serverSpots` from `serverPoint`.
- Extension: `selfLatLon` / `nodeLatLon` produce the violet self pin ("Это устройство") plus the green server halo and dot.
- Site: `ends(snapshot, routes)` reads the first `isCurrent` device and returns `{self: origin, selfPlatform, node: node.location}`. Both fields exist regardless of tunnel state because `accountInsights.ts` derives `origin` from `sessionOrigin` (IP) or `deviceEstimate` (`devices.map_country_code`).

### Stable marker geometry (supersedes the third-pass radius)

Flutter markers were sized from `flatScale`, so they grew and shrank with every zoom tween - the "sometimes big, sometimes small" report. `paintDeviceMarker` is now zoom-independent: `const double radius = 13` (26px, the size used in the old ZIP), pulse ring `1.75`, pulse stroke `1.4`, ring stroke `1.6`, `const double badgeRadius = 8`. `flatScale` stays as an unused optional parameter so existing call sites still compile. This replaces `radius max(7.5, 3.1 * flatScale)` from the third pass.

### Mobile camera (supersedes the third-pass spawn fix)

"Centred" meant **horizontally** centred, not centred in the phone. `_MapBackdropState` no longer uses `FlatMapView.fitConnections`, which recomputed zoom *and* vertical framing and produced both the chess-piece sliding and the fly-in from the right. It now spans `selfPoint.x`, `serverPoint.x` and every `arc.from.x` / `arc.to.x`, then always builds `FlatMapView.topAnchored(centreOn: MapPoint((minX + maxX) / 2, selfPoint.y), coverage: 0.88, topPadding: -6)` - the framing the old ZIP used. Zoom is constant, so markers no longer drift sideways between polls, and an inactive map stays anchored at the top. `fitConnections` remains in `map_view.dart` because `account_map_camera_test.dart` still exercises it.

### Yellow underline in the devices panel

`showGeneralDialog` provides no `Material` ancestor, so the panel's `Text` widgets fell back to the default `TextStyle`, which carries an amber underline. `_AccountDevicesPanel` is now wrapped in `Material(type: MaterialType.transparency)` inside the transition builder.

### One power button on all four surfaces

The extension's three-state power button is the reference and is ported into the shared `GlukConnectButton` (`flutter-client/lib/widgets/connect_button.dart`), which Windows and Android both use through `desktop_connect_button.dart`:

| phase | tint | glow | blob fade | greyscale |
| --- | --- | --- | --- | --- |
| idle | 0 | 0 | .17 | 1 |
| connecting | .34 | .85 | .74 | 0 |
| connected | .86 | 1 | 1 | 0 |
| disconnecting | .50 | .70 | .74 | 0 |

Greyscale uses `HSLColor.fromColor(c).withSaturation(0)` rather than channel arithmetic, because `Color.red/green/blue/value` are deprecated and would trip `deprecated_member_use` in `flutter analyze`.

### Verification (fourth pass)

Static only, same sandbox limits: `npm` is absent (`spawn npm ENOENT`) and there is no Flutter SDK, so no suite was executed. Checked by grep: no live references to `drawRoute`, `setPoint`, `conn-path`, `you-dot`, `you-ring`, `server-dot` or `server-ring` remain in the extension (comments only); `accountMapSig`, `nodeLatLon`, `selfLatLon`, `D.lastAccountMapSig` and `selfPlatform` appear exactly at the intended sites; `fitConnections` is gone from `home_screen.dart` and still present in `map_view.dart` for its test. `dashboard.css?v=20260905.4` was again deliberately NOT bumped because `site/tests/site.test.cjs` pins that string.

Still required before release: `npm run typecheck` and `npm test` at the root, `npm test --prefix site`, `node --test glukvpn-extension-1.5.0/extension/tests/sprint2-contracts.test.mjs`, `flutter analyze` + `flutter test`, native Windows and Android builds, then a visual pass at 320/390/900px, the Chrome popup, Windows and Android with zero, one and three live devices.

## Пятый проход: статистика, кнопки устройства и мелочи карты

### Значок расширения и спрайт иконок

Спрайт `material-devices.png` теперь содержит **шесть** клеток — к `devices`,
`computer`, `phone`, `web`, `server` добавлен `extension` (пазл). Смещения маски:
0 / 20 / 40 / 60 / 80 / 100 %. Браузерное устройство (`chrome`, `browser`, `ext`)
рисуется пазлом, а не окном браузера: `web` слишком похож на монитор.
Источник — `react-icons/md` (`MdExtension`), правило «никаких эмодзи и своих SVG»
остаётся в силе.

### Маркеры и движение

- Своё устройство прячется, если рядом есть другой маркер: 2.5 единицы карты
  на сайте и в расширении, 30 px на canvas во Flutter. Числа разные намеренно:
  это разные системы координат.
- Ключи группировки считаются по округлённым координатам, но **рисовать надо
  по точному `at`**. Иначе маркеры шагают по пиксельной сетке рывками.
- Гало и белое кольцо маркера одинаковы на трёх поверхностях: во Flutter —
  гало `radius * 1.9` с размытием и кольцо `radius + 1.3`, в CSS — тройной
  `box-shadow` у `.gluk-pin` и `.account-pin`.
- Расширение: `activeMapRevision` увеличивается только при выходе, смене
  аккаунта или переключении канала. Сброс ревизии на каждом пустом ответе
  гасил нити раз в 5 секунд.

### Экран статистики (один контракт на три площадки)

Источник данных один: `GET /api/user/analytics?period=day|week|month`.

| Площадка | Где |
| --- | --- |
| ПК и телефон | общий `lib/widgets/usage_stats.dart` (`UsageStatsView`); подключён в `desktop_stats_screen.dart` и `screens/stats_screen.dart` (телефон — из настроек) |
| Сайт | `site/assets/js/sprint2.js`, `renderAnalytics` |
| Расширение | собственный вид `#view-stats` + RPC `analytics` |

Общие правила оформления:

- три периода: день — по часам, неделя — 7 дней, месяц — 30 дней;
- янтарная плашка про неполную историю (`coverage.partial`), если измерения начались позже начала окна;
- две карточки итогов: загружено (зелёная) и отправлено (сиреневая);
- график столбиками с подписью пика и осью в UTC (время сервера честнее локального пересчёта);
- блок «По устройствам»: иконка платформы из того же спрайта, ↓/↑ и полоса доли;
- домены и категории: видны **только топ-5**, остальные раскрываются кнопкой «Показать все · N»;
- карточка бюджета — только админам. `includeBudget` выводится сервером из `isAdmin`, клиент не может попросить его флагом; обычный пользователь получает `budget: null`;
- бюджет подписан сервером («Месячные траты инфраструктуры · <узел>») и верстается списком карточек: узлов будет несколько, и второй сервер не должен требовать переверстки.

### Кнопки «Отключить» и «Выйти»

Смысл один везде: «Отключить» гасит только туннель, «Выйти» гасит туннель
и убирает устройство из аккаунта. Пара стоит и в раскрытом устройстве
панели на карте, и в списках устройств рядом с выходом.

- Сервер: `POST /api/vpn/disconnect` теперь разрешает владельцу аккаунта
  закрывать сессию другого своего устройства (`session.deviceId === device.id ||
  session.userId === user.id`). Сессии чужих аккаунтов по-прежнему невидимы (404).
- В ответе `active-map` у устройства есть `sessionId` — именно он нужен кнопке
  «Отключить»; `id` — это id устройства для `DELETE /api/devices/{id}`.
  Во Flutter `ActiveTunnelDevice` теперь читает `sessionId`.
- `/api/devices` `sessionId` не отдаёт, поэтому списки устройств берут его из живой
  карты: сайт — из `lastMap`, телефон — запросом `activeMap()` по нажатию.
  Если сессии нет, кнопка неактивна, а не врёт.
- Своё устройство гасится обычным путём (расширение — `disconnect`, телефон —
  `VpnController.disconnect()`), иначе остались бы включёнными прокси и бейдж.
- Новые имена: RPC расширения `closeAccountSession`, хук сайта `D.deviceAction`
  (запросы живут в `sprint2.js`, где есть авторизованный клиент),
  CSS-классы `.gluk-act` / `.account-act` / `.s2-off`.

### Убранное

- Сегменты «Вышли» / «Отозванные» удалены на всех площадках: телефон
  (`devices_screen.dart`), ПК (`desktop_account_screen.dart`), расширение
  (`popup.html`, `#seg-devices`). При выходе устройство удаляется из списка,
  так что раздел всегда был пустым.
- С экрана аккаунта на телефоне убран список устройств: он дублировал
  «Мои устройства» до буквы.

### Уведомление на телефоне

В уведомлении показывается человеческое место («Германия, Франкфурт»),
а не техническое имя узла вида `de-prod-1`.

### Анимации фаз подключения (едино на трёх поверхностях)

Эталон — ПК: `world_stage.dart`, `_arcProgress()`. Состояний три, и они должны
читаться без текста:

| Фаза | Нитка | Кнопка |
| --- | --- | --- |
| попытка | вырисовывается снова и снова | сиреневая + спиннер |
| подключено | целая, с бегущим пунктиром | зелёная + свечение |
| отключение | втягивается обратно | сереет |

- Телефон: `_MapBackdrop` получает `connecting` / `disconnecting` и считает
  `arcProgress` по той же таблице; в спокойных состояниях остаётся плавный tween.
- Расширение: `renderAccountMap()` рисует «пробную» нитку `.account-route.is-pending`
  (попытка) и `.is-leaving` (отключение) от своего маркера к выбранному серверу.
  На пути стоит `pathLength="1"`, чтобы одна CSS-анимация работала на дугах любой
  длины. Фаза входит в отпечаток сцены (`accountMapSig`), иначе карта не
  перерисуется при смене фазы.
- `prefers-reduced-motion` гасит обе анимации и оставляет статичную нить.
