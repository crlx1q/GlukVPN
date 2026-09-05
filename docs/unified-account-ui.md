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

The chip is `icon + label + count badge + chevron` everywhere. Tapping it opens a translucent panel anchored under the chip:

| token | value |
| --- | --- |
| panel surface | `rgba(23,18,42,.94-.97)` + `blur(18px)`, border `rgba(196,181,253,.20)`, radius 20, shadow `0 22px 54px rgba(0,0,0,.62)` |
| chip | radius 14, bg `rgba(26,20,40,.90)`, border `rgba(139,92,246,.36)`, text `#c4b5fd` 600 |
| count badge | radius 8, bg `rgba(139,92,246,.24)`, text `#efe7ff` 800 |
| device row | `40-44px | 1fr | auto` grid, gap 11-12, padding 9-10, radius 16 |
| icon tile | 40-44px, radius 13-14, bg `rgba(139,92,246,.20)`, glyph `#c4b5fd` |
| row text | name `#f5f3fb` 700 / meta `#9b93ad` / route `#bfb4d4` |
| online dot | 7-8px `#3ddc97` + `0 0 9-10px rgba(61,220,151,.85)` |

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

Styled after the original popup design: a thin dashed green thread with a soft lift instead of a flat line, a green origin dot and a violet exit-node dot, each with a translucent halo.

- Origin (device) `#3ddc97` / node `#c4b5fd` on ALL surfaces. `dotted_world.dart` previously painted these the other way round; `_paintArc` gained an optional `accentTo` so the account thread fades green -> violet.
- Site/extension: `stroke-width .4`, `stroke-dasharray 1.6 1.9`, `stroke-dashoffset` animated over 3.6s linear, halo `r 2.5`, dot `r .95`.
- Quadratic lift is proportional to span: `max(3.5, |bx - ax| * 0.16)`, so short hops stay flat and long hops bow.
- Every flow animation is disabled under `prefers-reduced-motion` / `MotionSettings.reduceMotion`.

### Icons

The white/washed-out device glyphs came from painting the Material PNG sprite directly. Site and extension now use the sprite as a CSS `mask` with `background-color: currentColor`, so glyphs inherit `#c4b5fd` and can be re-tinted per state without new artwork. The sprite, its geometry and the Apache-2.0 attribution above are unchanged; the ban on emoji/hand-drawn SVG replacements still stands.

### Mobile

No map card in the middle of the phone screen. The world stays a backdrop behind the hero; below 760px the site hides `.dash-map__stage` and `.dash-map__legend`, the chip goes full width and the panel becomes static instead of absolutely positioned.

### Verification (third pass)

Static only. `npm` is still absent from the connected sandbox (`spawn npm ENOENT`), and there is no Flutter SDK, so no suite was executed. Checked by inspection/grep: no references remain to `connectionMarkers`, `onShowMap`, `_inspectMap`, `account-devices-sheet`, `account-map-point`, `data-map-detail` or `account-device-geo`; the strings asserted by `extension/tests/sprint2-contracts.test.mjs` (`String(normalizedError(error)?.code`, `openDeviceLimitModal`, `renderAccountMap`, `restrictionLabel`) are all still present; `accountMapArcs` semantics and the `D.deviceIcon` / `D.drawAccountMap` declaration order required by `site/tests/site.test.cjs` are preserved; `dashboard.css?v=20260905.4` was deliberately NOT bumped because the site suite pins that string.

Still required before release: `npm run typecheck` and `npm test` at the root, `npm test --prefix site`, `node --test glukvpn-extension-1.5.0/extension/tests/`, `flutter analyze` + `flutter test`, then a visual pass on 320/390/900px web, the Chrome popup, Windows and Android.
