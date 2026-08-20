# GlukVPN Flutter client (Android)

Android client for the GlukVPN prototype. It talks to the control plane over
HTTPS, generates its own WireGuard key pair on the device, and brings up a real
system VPN tunnel through the Android VPN API.

- Package name: `glukvpn`
- Application id: `tech.gluk.glukvpn`
- Control plane: `https://api.gluk.tech` (override at build time)
- Tunnel: WireGuard via [`wireguard_flutter`](https://pub.dev/packages/wireguard_flutter)

## What it does

1. **Login** with a local username/password (no email, no phone).
2. **Registers this device**: generates an X25519 key pair, uploads **only the
   public key**, receives a device-scoped access/refresh token pair.
3. **Lists nodes** from `GET /api/nodes` with live status, load, CPU/RAM and
   heartbeat age.
4. **Connects**: `POST /api/vpn/connect` returns the node public key, endpoint,
   assigned VPN IP, DNS, allowed IPs and keepalive. The app builds a wg-quick
   config locally, adds the private key from secure storage, and starts the
   tunnel. Android shows its own VPN permission dialog on first start.
5. **Shows live state**: status, country, exit IP, duration, traffic and a
   real-time ping to the tunnel gateway.
6. **Disconnects**: closes the tunnel, then `POST /api/vpn/disconnect` so the
   control plane tells the node agent to remove the peer.

The private key never leaves the phone. It is created on the device, stored via
`flutter_secure_storage` (Android `EncryptedSharedPreferences`), never sent to
the API and never printed to logs.

## Screens

| Screen | Contents |
| --- | --- |
| Login | username, password, control-plane URL, warning if the URL is not HTTPS |
| VPN (home) | connect orb, country + flag, exit IP, VPN IP, duration, live ping, traffic down/up/total, endpoint, peer state, session status |
| Servers | one card per node: flag, name, status dot, load bar, endpoint, peers, CPU, RAM, uptime, heartbeat age, agent version |
| Settings | account, subscription, this device (id + public key preview), devices list, control-plane info, log out |
| Devices | all registered devices, current-device badge, connected node, last seen, revoke |

## Layout

```
flutter-client/
  lib/
    config.dart              # compile-time config (API URL, intervals, limits)
    main.dart                # entrypoint, wires services + controllers
    app.dart                 # theme, AuthGate, bottom navigation shell
    models/models.dart       # API DTOs (users, nodes, sessions, tunnel config)
    services/
      api_client.dart         # REST client, token refresh, typed errors
      secure_store.dart       # secure storage for keys/tokens/device id
      wg_keys.dart            # X25519 keygen with wg-compatible clamping
      vpn_service.dart        # wireguard_flutter wrapper, stage stream
      ping_service.dart       # live latency to the tunnel gateway
    state/
      auth_controller.dart    # login, device registration, logout
      vpn_controller.dart     # nodes, connect/disconnect, polling, stats
    widgets/common.dart      # small shared UI pieces
    screens/                 # login, home, servers, settings, devices
  test/                      # unit tests (keys, models, formatting, stages)
  android_overrides/         # AndroidManifest + Gradle namespace patch
  .github/workflows/build-apk.yml
```

There is no committed `android/` directory: the platform scaffold is generated
with `flutter create` and then patched from `android_overrides/`. That keeps the
repo small and avoids committing generated Gradle files.

## Build the APK locally

Requirements: Flutter **3.24.5** (stable), JDK 17, Android SDK.

```sh
cd flutter-client

# 1. generate the Android scaffold (safe to re-run; it never overwrites lib/)
flutter create --platforms=android --org tech.gluk --project-name glukvpn .

# 2. apply the overrides
cp android_overrides/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
cat android_overrides/namespace_patch.gradle >> android/build.gradle

# 3. build
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=API_BASE_URL=https://api.gluk.tech
```

On Windows PowerShell, replace step 2 with:

```powershell
Copy-Item android_overrides\AndroidManifest.xml android\app\src\main\AndroidManifest.xml -Force
Get-Content android_overrides\namespace_patch.gradle | Add-Content android\build.gradle
```

The APK lands in `build/app/outputs/flutter-apk/app-release.apk`.

### Why the two overrides are needed

- **`AndroidManifest.xml`** — adds the permissions and the `VpnService`
  declaration the tunnel needs (`FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`, `INTERNET`) plus the
  notification channel metadata. `flutter create` does not know about them.
- **`namespace_patch.gradle`** — `wireguard_flutter` 0.1.3 predates AGP 8 and
  ships no `namespace`, so an unpatched build fails with
  `Namespace not specified`. The patch injects a namespace for legacy
  subprojects instead of forking the plugin.

### Debug build against a local API

```sh
flutter run --dart-define=API_BASE_URL=https://api.gluk.tech
```

HTTP URLs are rejected by the manifest's network security config, and the login
screen shows a warning if a non-HTTPS URL was compiled in.

## CI: signed APK from GitHub Actions

`.github/workflows/build-apk.yml` runs on push, on tags and on manual dispatch.
It performs the same steps as above, then:

- decodes the release keystore from secrets, if they are present;
- builds a **signed** release APK when they are, or an unsigned one otherwise;
- uploads the APK as a build artifact;
- attaches the APK to a GitHub Release when the run is for a `v*` tag.

Required repository secrets for a signed build:

| Secret | Meaning |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

Generate a keystore once, keep it out of Git:

```sh
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias glukvpn
```

To cut a release: `git tag v0.1.0 && git push origin v0.1.0`.

## Install on the phone

1. Download the APK from the workflow artifact or the release page.
2. Allow installation from unknown sources for your browser/file manager.
3. Install, open, log in with the seeded test user.
4. Press **CONNECT** and accept the Android VPN permission dialog.
5. A key icon appears in the status bar while the tunnel is up.

## Tests

```sh
flutter test
```

Covered:

- `wg_keys_test.dart` — scalar clamping, the RFC 7748 X25519 vector, key
  round-trip, no private key in `toString()`.
- `models_test.dart` — API payload parsing, `wg-quick` config generation,
  gateway derivation, subscription/session state rules.
- `vpn_service_test.dart` — platform stage mapping, including `noConnection`
  and `denied`.
- `format_test.dart` — flags, durations, byte scaling, uptime, relative times.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Ping shows `--` while connected | The node blocks ICMP on `wg0`. Add `iptables -I INPUT -i wg0 -j ACCEPT` on the node. The app then falls back to timing an HTTPS request. |
| `Germany unavailable` / node card is OFFLINE | The node agent stopped sending heartbeats (offline after 30s). Check `systemctl status vpn-node-agent`. |
| Permission dialog dismissed | Stage becomes `denied`; press CONNECT again and accept. |
| Connected but no internet | MTU or NAT on the node. Verify `net.ipv4.ip_forward=1` and the `MASQUERADE` rule for `10.8.0.0/24`. |
| `Namespace not specified` at build time | `android_overrides/namespace_patch.gradle` was not appended to `android/build.gradle`. |
| Login fails with 429 | Login throttling after 5 failed attempts; wait 15 minutes or clear attempts via the control-server CLI. |

## Privacy

The app reports nothing but what the control plane needs: device name, public
key, and platform string. Traffic accounting comes from WireGuard byte counters
on the node. No URLs, no DNS queries and no payload data are collected anywhere
in this project.

## Visual system (BETA sprint 2)

The mock-ups in `gluk_vpn_v5_connection.html` are treated as the specification,
not as inspiration. Where a value could be read out of the CSS, it was.

### Connect button

`lib/widgets/connect_button.dart` is a direct port of `.blob-zone`:

| Mock-up | Flutter |
| --- | --- |
| `.blob-glow` 260 px radial `rgba(124,92,246,.35)`, `blur(4px)`, `glowPulse 3.6s` | `_Glow` - the glow is a layer of the effect, underneath the button, not a shadow on it |
| `.blob-outer` 210 px `linear-gradient(150deg,…)`, `morph1 7s` | `_MorphBlob` with the CSS keyframes transcribed into `_morph1` |
| `.blob-inner-ring` `linear-gradient(320deg,…)`, `opacity .4`, `blur(2px)`, `morph2 7s` | second `_MorphBlob` with `_morph2` |
| `.power-btn` 150 px, `radial-gradient(circle at 35% 30%,#201a30,#0a0812 75%)`, inset hairline, `0 20px 40px rgba(0,0,0,.6)`, `:active scale(.96)` | the sphere on top, `AnimatedScale` on press |

Each elliptical border radius from `@keyframes morph1/morph2` is stored as an
`_MorphFrame` (eight radii, rotation, scale) and interpolated - which is why the
blobs breathe like the HTML instead of merely rotating. States change accent and
tempo only (`_tint`, `_morphPeriod`); the motion language is shared. There are
no particles: the original has none.

### One camera, one planet

Onboarding is a single `DottedWorld` filmed by `IntroCamera`
(`lib/screens/onboarding_screen.dart`), which is plain data and unit-tested in
`test/onboarding_camera_test.dart`:

1. the whole globe, small, slightly below centre;
2. a flight to the user's approximate position - `centreLongitude` /
   `centreLatitude` move the camera, and the marker fades in;
3. a flight on to the node: `zoom` passes `pi`, so the planet no longer fits,
   `globeAnchor` pushes its middle to `x = 0.30`, and only the right half stays
   on screen while a light thread joins the two points.

Zoom dips at the midpoint of each move, so it reads as travel rather than as a
zoom ramp. "Let's Go" continues the same shot: `globeness` 1 -> 0 unrolls the
sphere into the flat map at `zoom 2.85`, which runs off both edges - a full
bleed background for sign-in, not a strip in a box. The page view only reads
swipes; every visual is driven by the fractional page offset.

The location is approximate and derived from the device region or its UTC
offset. No GPS, no location permission, no geolocation request.

### Signal bars

`lib/utils/signal.dart` grades a node from its own numbers - measured round
trip, reported load, online status - and never from its country:

* good/bad anchors: 40/220 ms and 40/95 % load;
* weighted 0.65 ping + 0.35 load;
* either dimension being bad on its own caps the result, so a 20 ms node that is
  93 % full still shows one bar;
* an unmeasured ping is never three bars (an ICMP probe can be filtered).

`SignalBars` draws three upright bars: green / amber / red / grey, with no
number inside. The ping value stays in the row's metadata line.

### Glass

`GlukSizes.glassBlur = 7` and `navBlur = 10` with `cell = 0x40120E1C` follow the
mock-up's `--glass: rgba(255,255,255,0.05)`: the world behind a card has to stay
readable. Panels are glass, not dark rectangles.

### Checks

`flutter analyze`, `flutter test` and the Android build have to run on a machine
with the Flutter SDK - they were not executed in the authoring environment. The
APK workflow builds the `beta` branch on push.
