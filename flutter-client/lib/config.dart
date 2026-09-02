import 'dart:ui' show Size;

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

	// -------------------------------------------------------------------------
	// Version and update checks
	// -------------------------------------------------------------------------

	/// Human version of this build. Must stay in sync with pubspec.yaml's
	/// `version: 1.0.0+2`. package_info_plus reads the real value at runtime on
	/// desktop, but the update checker needs a number before any plugin is
	/// initialised, and the unit tests must not depend on a platform channel.
	static const String appVersion = '1.0.0';

	/// Monotonic build number from pubspec.yaml (the part after `+`).
	static const int appBuild = 2;

	/// The public site. Registration, password recovery and the link sign-in
	/// page all live there; the clients only ever open URLs under it, they never
	/// reimplement those flows.
	static const String siteBaseUrl = 'https://vpn.gluk.tech';

	/// Static release manifest, published next to the installers.
	///
	/// Deliberately a static file and not an API route: a client is most likely
	/// to be out of date exactly while the control server is being redeployed,
	/// and a static file cannot go down together with the backend.
	static const String updateManifestUrl =
			'https://vpn.gluk.tech/api/version.json';

	/// How often a running client re-reads the manifest.
	static const Duration updateCheckInterval = Duration(hours: 4);

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
	/// ROUND 11: on. The button now runs the device-authorization grant against
	/// the Telegram bot (`/start login-<CODE>`), so it is a real sign-in path
	/// rather than a placeholder. Turn it off only if the control plane is
	/// deployed without TELEGRAM_BOT_TOKEN - the server then returns no
	/// telegramUrl and the flow falls back to confirming on the website.
	static const bool telegramSignInEnabled = true;
	static const bool googleSignInEnabled = false;

	/// Self-service registration. ROUND 8: on. The control server now runs the
	/// whole sign-up chain - email plus a six digit code, then a Telegram
	/// contact handed to the bot - so an open endpoint can no longer be farmed
	/// for throwaway accounts. Admin-created accounts still work.
	static const bool selfRegistrationEnabled = true;

	// -------------------------------------------------------------------------
	// Build channel
	// -------------------------------------------------------------------------

	/// Selected at build time on desktop:
	///   flutter build windows --dart-define=GLUK_CHANNEL=beta
	/// Android keeps using [ChannelController], which can switch at runtime, so
	/// this only sets the starting point.
	static const String _buildChannel =
			String.fromEnvironment('GLUK_CHANNEL', defaultValue: 'prod');

	/// Set by the channel switch in Settings, which is shown to administrators
	/// only. `null` means "whatever this build was compiled for".
	///
	/// ROUND 12: the five-click gesture that used to set this is gone from every
	/// client. Ordinary users have no channel switch at all, so this stays null
	/// for them - and a non-admin session that inherited beta from an older
	/// build is moved back to prod at startup.
	static AppChannel? _channelOverride;

	static AppChannel? get channelOverride => _channelOverride;

	/// Applies a developer channel override, or clears it with `null`.
	///
	/// Beta is refused outright when the build was compiled without it. That is
	/// the whole point of `ALLOW_BETA_CHANNEL`: a public build must not be
	/// talkable into the beta control plane, not even by its own dev menu or by a
	/// leftover preference from an internal build.
	static bool setChannelOverride(AppChannel? channel) {
		if (channel != null && channel.isBeta && !betaChannelAvailable) return false;
		_channelOverride = channel;
		return true;
	}

	/// The channel this build talks to. A build compiled with
	/// `ALLOW_BETA_CHANNEL=false` can never resolve to beta, even if someone
	/// passes `GLUK_CHANNEL=beta`.
	static AppChannel get activeChannel {
		final AppChannel? override = _channelOverride;
		if (override != null) return override;
		final AppChannel channel = AppChannel.fromId(_buildChannel);
		if (channel.isBeta && !betaChannelAvailable) return AppChannel.prod;
		return channel;
	}

	static String get activeBaseUrl => baseUrlFor(activeChannel);

	/// Internal builds show diagnostics, internal nodes and the raw MTU field.
	/// Public builds must never set this.
	static const bool internalBuild = bool.fromEnvironment('GLUK_INTERNAL');

	// -------------------------------------------------------------------------
	// Windows desktop
	// -------------------------------------------------------------------------
	//
	// Everything below is desktop-only. The constants live here rather than in
	// lib/desktop/ so that a single place defines the contract shared with the
	// native service, and so Android never has to import desktop code.

	/// Named pipe the UI uses to reach GlukVpnTunnelService.
	/// Must match kPipeName in native/glukvpn-tunnel-service/src/service.h.
	static const String tunnelPipeName = 'GlukVPN.tunnel';

	/// Windows service name registered with the SCM.
	static const String tunnelServiceName = 'GlukVpnTunnel';

	/// WireGuard adapter name shown in Network Connections.
	static const String desktopAdapterName = 'GlukVPN';

	/// Service executable, relative to the install directory.
	static const String desktopServiceRelativePath =
			r'service\GlukVpnTunnelService.exe';

	/// How often the UI polls the tunnel service. Faster than the API poll
	/// because this is a local pipe and it drives the connect animation.
	static const Duration serviceStatusInterval = Duration(seconds: 2);

	/// A handshake older than this means the tunnel is no longer carrying
	/// traffic. Matches kHandshakeStaleSeconds in the native service.
	static const Duration handshakeStaleAfter = Duration(seconds: 180);

	/// Hard ceiling on the connecting phase. Past this the UI reports a failure
	/// instead of spinning forever.
	static const Duration connectTimeout = Duration(seconds: 25);

	/// The main window is a fixed panel, like the reference design: the minimum
	/// and the default are the same size and WindowController turns resizing
	/// off, so the composition can never be stretched into empty space again.
	/// Smaller than the previous 1160x1000, and much closer to square.
	///
	/// ROUND 5: 1000x780, down from 1080x880. The reference mockup is a compact
	/// square panel; ours was still wide enough that the map card dominated the
	/// screen with empty bands above and below it. Note the interaction with the
	/// home breakpoint: content width is 1000 - 208 sidebar - 36 padding = 756,
	/// so DesktopHomeScreen switches to three columns at 700, not 900.
	static const Size desktopMinSize = Size(1000, 780);
	static const Size desktopDefaultSize = Size(1000, 780);
	/// Tray quick panel. Small on purpose: it only carries the connect button,
	/// the current server, ping and the two traffic counters, in the spirit of
	/// the native Windows utility panels that appear above the tray.
	static const Size miniPanelSize = Size(320, 356);

	/// Deliberately short. The logo animation must never be the reason the app
	/// feels slow; session, servers and subscription all load behind it.
	static const Duration splashDuration = Duration(milliseconds: 620);
}
