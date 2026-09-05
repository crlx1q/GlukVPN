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

Deploy the control server and updated clients as one coordinated release; do not upload only JavaScript without the new script references. No database migration, infrastructure reconfiguration or deployment is included in this change.

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
