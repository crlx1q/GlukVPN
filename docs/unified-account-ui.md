# Unified account presentation and connection map

## Scope
- Website, Windows/Android Flutter client and Chrome extension use plan names: Free, Basic, Pro, β Pro. A plan name is independent of subscription expiry or account blocking; those controls remain enforced.
- The earlier ZIP was used as a visual reference, not restored wholesale. The existing background world remains the only map in the Flutter home screen; the desktop connections sheet is a list without a second map.
- Website login returns to a complete round dotted planet. Desktop login already uses the spherical DottedWorld projection.
- Website tester badge markup is preserved during account-state resets. Device management uses SVG icons rather than emoji.

## Shared data contract
All clients use GET /api/user/active-map for their authenticated account in the selected API channel. Production and beta are intentionally separate. Polling is normally every 5 seconds while visible; this is near-real-time polling, not a WebSocket guarantee.

The response contains all account devices with current sessions (one latest session per device), no first-five truncation. activeTunnels counts ACTIVE records; pendingTunnels counts PENDING records. Pending sessions are not drawn as established connections. Locations are approximate IP-country locations and the actual node coordinates. Missing geography is not invented. Devices sharing a point are grouped; their labels remain available.

Flutter markers use the exact same projection as the background painter. Desktop supports hover; Android has a map-inspection toggle which fades/ignores normal controls and lets users tap the existing background points. Authentication changes invalidate snapshots, and map requests time out after 15 seconds. The extension clears stale responses on logout, channel changes and failed requests.

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

The account list is now deliberately map-free regardless of the old showMap flag. Windows and Android share AccountDevicesButton and the same scrollable cards; Chrome uses the same layout, fields and Material devices icon. Web/Chrome device icons are unchanged ready-made Material glyphs rasterized into a local PNG sprite, not hand-drawn SVG paths. They correspond to Flutter Icons.devices/computer/smartphone/web/dns. Attribution: Google Material Design Icons, Apache-2.0, https://github.com/google/material-design-icons; exported through react-icons/md. Do not replace these with emoji or custom SVG approximations.

### REQUIRED server update for cross-device positions

New optional devices.map_country_code column, migration 20260905210000_session_map_origin (despite its name, the final migration adds a DEVICE column). Apply normal Prisma migrations and regenerate the client BEFORE running the new server. No migration has been executed by the assistant.

POST /api/user/map-origin accepts ONLY {countryCode}, derives account and device identifiers from the authenticated device-scoped token, rejects extra keys and unsupported codes, and updates only that active device. Existing rows stay null. The country estimate is recorded even before a connection is opened, so an extension popup can close without losing the future session's fallback location. Changing display geography never changes VPN routing, entitlements, handshake state or access control.

Windows/Android send their device-local country estimate (existing locale/timezone resolver, WITHOUT the shared account origin). Chrome sends its own timezone's country. These are WEAK estimates, not measured physical locations or GPS. IP-derived location remains preferred when GeoIP is enabled and succeeds; otherwise active-map uses the device's labelled `device-estimate`. The frontend labels the approximation. No user's country is copied to another user's or another device's record. Unknown countries stay unknown. Devices can be in the wrong country if their clock/locale is set incorrectly; real GeoIP is still preferable.

Release order: database migration + Prisma generate → control server → site assets and rebuilt Windows/Android clients → reload extension. Then open each client once to report its region. Updating only the UI cannot populate absent server-side positions. Keep production and beta separate.

Verification: npm run typecheck was attempted again; the connection returned `spawn npm ENOENT` before compilation. Full Flutter build/analyzer and live multi-device verification remain required. Added account-map-origin.test.ts and account_map_camera_test.dart for the regression cases. No push/deployment was performed.

Executed follow-up checks: isolated production map-service functions with mocked database/provider dependencies (country isolation for two devices, GeoIP disabled, IP preference when enabled, unknown geography, pending-vs-active counts, authenticated write filters); Chromium tests of the updated web map (seven routes, grouping, interaction, 320/390/900px, untrusted labels). These are component checks, not a live server or native Flutter test. Copy docs/licenses/Material-Icons-Apache-2.0.txt into third-party notices when packaging the site/extension.
