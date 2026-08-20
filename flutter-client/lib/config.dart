/// Build-time and channel configuration.
///
/// The app can talk to either control plane:
///
///   PROD  https://api.gluk.tech        - real accounts, real nodes
///   BETA  https://beta-api.gluk.tech   - throwaway accounts, new features
///
/// The two are completely separate deployments with separate databases and
/// separate signing secrets, so a session on one is meaningless on the other.
/// That is why tokens are stored per channel and switching channels signs you
/// out of the channel you left (see SecureStore's channel-scoped keys).
enum AppChannel {
	prod('prod', 'PROD', 'https://api.gluk.tech'),
	beta('beta', 'BETA', 'https://beta-api.gluk.tech');

	const AppChannel(this.id, this.label, this.defaultBaseUrl);

	/// Stable identifier used in storage keys and sent nowhere.
	final String id;

	/// Shown on the channel badge.
	final String label;

	final String defaultBaseUrl;

	bool get isBeta => this == AppChannel.beta;

	static AppChannel fromId(String? id) => AppChannel.values.firstWhere(
				(channel) => channel.id == id,
				orElse: () => AppChannel.prod,
			);
}

class AppConfig {
	AppConfig._();

	/// Overridable at build time:
	///   flutter build apk --dart-define=API_BASE_URL=https://api.gluk.tech
	/// Kept for the existing CI invocation and for pointing a debug build at a
	/// laptop. When set it overrides BOTH channels, because a custom host has no
	/// meaningful prod/beta split.
	static const String _overrideBaseUrl = String.fromEnvironment('API_BASE_URL');

	/// Beta channel URL, overridable separately for testing.
	static const String _betaOverrideBaseUrl =
			String.fromEnvironment('BETA_API_BASE_URL');

	/// Set `--dart-define=ALLOW_BETA_CHANNEL=false` to ship a build that cannot
	/// be switched to beta at all.
	static const bool betaChannelAvailable =
			bool.fromEnvironment('ALLOW_BETA_CHANNEL', defaultValue: true);

	/// The channel a fresh install starts on. Always prod - beta is opt-in from
	/// Settings, never the default.
	static const AppChannel defaultChannel = AppChannel.prod;

	static String baseUrlFor(AppChannel channel) {
		if (_overrideBaseUrl.isNotEmpty) return _overrideBaseUrl;
		if (channel == AppChannel.beta && _betaOverrideBaseUrl.isNotEmpty) {
			return _betaOverrideBaseUrl;
		}
		return channel.defaultBaseUrl;
	}

	/// True when the build was pointed at a custom host, in which case the
	/// channel switch is hidden - it would be a lie.
	static bool get hasBaseUrlOverride => _overrideBaseUrl.isNotEmpty;

	/// Kept for code that has no channel context yet (splash, crash reporting).
	static String get apiBaseUrl => baseUrlFor(defaultChannel);

	/// Android application id; also the VPN tunnel's owner.
	static const String appId = 'tech.gluk.glukvpn';

	/// Name of the WireGuard interface created on the device.
	static const String tunnelInterfaceName = 'glukvpn';

	static const Duration httpTimeout = Duration(seconds: 15);

	/// How often the app re-reads /api/vpn/status while connected.
	static const Duration statusPollInterval = Duration(seconds: 10);

	/// Live ping cadence on the home screen.
	static const Duration pingInterval = Duration(seconds: 3);

	/// Used once after connecting to show the exit IP.
	static const String exitIpProbeUrl = 'https://api.ipify.org?format=json';
	static const Duration exitIpTimeout = Duration(seconds: 10);

	/// Client-side validation, mirroring the server's rules.
	static const int minUsernameLength = 3;
	static const int maxUsernameLength = 32;
	static const int minPasswordLength = 8;

	/// Sign-in providers that are visible but not wired up yet. Telegram
	/// verification and Google sign-in are planned; the buttons are rendered
	/// disabled rather than hidden so the layout matches the final design.
	static const bool telegramSignInEnabled = false;
	static const bool googleSignInEnabled = false;

	/// Self-service registration. Off until Telegram verification exists -
	/// without it an open endpoint would be an invitation to create thousands of
	/// accounts. Admin-created accounts still work.
	static const bool selfRegistrationEnabled = false;
}
