/// Compile-time configuration for the client.
///
/// Nothing secret lives here. The control-plane URL is injected at build time so
/// the same source tree can target another deployment without code edits:
///
/// ```sh
/// flutter build apk --release --dart-define=API_BASE_URL=https://api.gluk.tech
/// ```
class AppConfig {
  const AppConfig._();

  /// Base URL of the control plane. HTTPS only.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.gluk.tech',
  );

  /// Android application id. The tunnel plugin wants it as
  /// `providerBundleIdentifier` (it only matters on Apple platforms, but the
  /// parameter is required).
  static const String appId = 'tech.gluk.glukvpn';

  /// Name of the tunnel interface created on the phone.
  static const String tunnelInterfaceName = 'glukvpn';

  static const Duration httpTimeout = Duration(seconds: 15);

  /// How often the app refreshes traffic counters / session state from the
  /// control plane while connected. Node reports arrive every 30s, so polling
  /// faster than this would only show stale numbers.
  static const Duration statusPollInterval = Duration(seconds: 10);

  /// Live latency readout cadence.
  static const Duration pingInterval = Duration(seconds: 3);

  /// Public echo endpoint, queried once per connection to prove the exit IP
  /// actually moved to the VPN node. It sees only the node's address.
  static const String exitIpProbeUrl = 'https://api.ipify.org?format=json';
  static const Duration exitIpTimeout = Duration(seconds: 10);

  /// Mirrors the server-side validation schema, so the UI can fail fast.
  static const int minUsernameLength = 3;
  static const int minPasswordLength = 8;

  static bool get usesHttps => apiBaseUrl.startsWith('https://');
}
