import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// One release, as published in the static manifest.
///
/// The manifest is intentionally tiny and tolerant: a missing field must never
/// throw, because a broken update check has to stay invisible rather than take
/// the app down with it.
@immutable
class ReleaseInfo {
	const ReleaseInfo({
		required this.version,
		required this.build,
		required this.changelog,
		required this.releaseDate,
		required this.windowsUrl,
		required this.androidUrl,
		required this.minSupportedVersion,
	});

	factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
		final Map<String, dynamic> downloads =
				(json['downloads'] as Map<String, dynamic>?) ??
						const <String, dynamic>{};
		return ReleaseInfo(
			version: _text(json['version']),
			build: (json['build'] as num?)?.toInt() ?? 0,
			changelog: _text(json['changelog']),
			releaseDate: _text(json['releaseDate']),
			windowsUrl: _absolute(downloads['windows']),
			androidUrl: _absolute(downloads['android']),
			minSupportedVersion: _text(json['minSupportedVersion']),
		);
	}

	final String version;
	final int build;
	final String changelog;
	final String releaseDate;
	final String windowsUrl;
	final String androidUrl;
	final String minSupportedVersion;

	/// Installer for the platform we are running on. Empty when this release has
	/// nothing to offer here - a Linux debug run, for instance.
	String get downloadUrl {
		switch (defaultTargetPlatform) {
			case TargetPlatform.windows:
				return windowsUrl;
			case TargetPlatform.android:
				return androidUrl;
			default:
				return '';
		}
	}

	bool get isValid => version.isNotEmpty;
}

String _text(Object? raw) => raw is String ? raw.trim() : '';

/// The manifest may carry site-relative paths (`/downloads/...`) so the file
/// survives a domain change without an edit. Absolute URLs are left alone.
String _absolute(Object? raw) {
	final String value = _text(raw);
	if (value.isEmpty) return '';
	if (value.startsWith('http://') || value.startsWith('https://')) return value;
	final String base = AppConfig.siteBaseUrl;
	if (value.startsWith('/')) return base + value;
	return base + '/' + value;
}

/// Compares dotted numeric versions: `1.10.0` is newer than `1.9.3`, which a
/// plain string compare gets wrong. Missing segments count as zero, so `1.1`
/// equals `1.1.0`. A prerelease suffix (`1.0.1-rc1`) sorts *before* the plain
/// release of the same numbers, matching semver.
int compareVersions(String a, String b) {
	final List<String> aParts = a.trim().split('-');
	final List<String> bParts = b.trim().split('-');
	final List<int> aNums = _numbers(aParts.first);
	final List<int> bNums = _numbers(bParts.first);
	final int len = aNums.length > bNums.length ? aNums.length : bNums.length;
	for (int i = 0; i < len; i++) {
		final int left = i < aNums.length ? aNums[i] : 0;
		final int right = i < bNums.length ? bNums[i] : 0;
		if (left != right) return left < right ? -1 : 1;
	}
	final bool aPre = aParts.length > 1 && aParts[1].isNotEmpty;
	final bool bPre = bParts.length > 1 && bParts[1].isNotEmpty;
	if (aPre == bPre) return 0;
	return aPre ? -1 : 1;
}

List<int> _numbers(String core) {
	final List<int> out = <int>[];
	for (final String piece in core.split('.')) {
		final String digits = piece.replaceAll(RegExp(r'[^0-9]'), '');
		out.add(digits.isEmpty ? 0 : int.parse(digits));
	}
	return out;
}

/// Polls the release manifest and tells the UI whether to show the update
/// banner.
///
/// Rules that shaped this:
///  * A failed check is not an error the user should see. The VPN works fine on
///    an older build; the banner simply does not appear.
///  * The check runs once at start and then every four hours. A desktop client
///    lives in the tray for weeks, so "at start" alone would never fire again.
///  * Dismissing the banner hides it for this run only. It comes back next
///    launch, which is the honest middle ground between nagging and letting a
///    broken build sit forever.
class UpdateChecker extends ChangeNotifier {
	UpdateChecker({http.Client? client, Duration? interval})
			: _client = client ?? http.Client(),
				_ownsClient = client == null,
				_interval = interval ?? AppConfig.updateCheckInterval;

	final http.Client _client;
	final bool _ownsClient;
	final Duration _interval;

	Timer? _timer;
	bool _disposed = false;
	bool _checking = false;
	bool _dismissed = false;
	ReleaseInfo? _latest;
	DateTime? _lastCheckedAt;

	ReleaseInfo? get latest => _latest;
	DateTime? get lastCheckedAt => _lastCheckedAt;
	bool get checking => _checking;

	/// The manifest advertises something newer than this build.
	bool get updateAvailable {
		final ReleaseInfo? release = _latest;
		if (release == null || !release.isValid) return false;
		if (compareVersions(release.version, AppConfig.appVersion) > 0) return true;
		// Same version string, higher build number: a rebuild that fixed something
		// without a version bump still deserves the banner.
		return compareVersions(release.version, AppConfig.appVersion) == 0 &&
				release.build > AppConfig.appBuild;
	}

	/// This build is older than the oldest version the server still supports.
	/// The banner stays put in that case - it cannot be dismissed.
	bool get updateRequired {
		final ReleaseInfo? release = _latest;
		if (release == null || release.minSupportedVersion.isEmpty) return false;
		return compareVersions(AppConfig.appVersion, release.minSupportedVersion) <
				0;
	}

	bool get bannerVisible =>
			updateAvailable && (updateRequired || !_dismissed);

	/// Installer to open when the user taps Download. Falls back to the download
	/// page, which always exists, when the manifest has no direct link.
	String get downloadUrl {
		final String direct = _latest?.downloadUrl ?? '';
		if (direct.isNotEmpty) return direct;
		return AppConfig.siteBaseUrl + '/download/';
	}

	void dismiss() {
		if (_dismissed || updateRequired) return;
		_dismissed = true;
		notifyListeners();
	}

	/// Starts the first check and the four-hour timer. Safe to call twice.
	void start() {
		if (_disposed || _timer != null) return;
		_timer = Timer.periodic(_interval, (_) => check());
		// A tray app can outlive several releases; do not let the periodic timer
		// keep a suspended isolate awake.
		unawaited(check());
	}

	Future<void> check() async {
		if (_disposed || _checking) return;
		_checking = true;
		try {
			final http.Response response = await _client
					.get(
						Uri.parse(AppConfig.updateManifestUrl),
						headers: const <String, String>{
							'accept': 'application/json',
							'cache-control': 'no-cache',
						},
					)
					.timeout(AppConfig.httpTimeout);
			if (_disposed) return;
			if (response.statusCode != 200) return;
			final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
			if (decoded is! Map<String, dynamic>) return;
			final ReleaseInfo release = ReleaseInfo.fromJson(decoded);
			if (!release.isValid) return;
			_latest = release;
			_lastCheckedAt = DateTime.now();
			notifyListeners();
		} catch (_) {
			// Offline, DNS blocked, a proxy serving HTML, malformed JSON: none of it
			// is worth a word to the user. Silence is the feature here.
		} finally {
			_checking = false;
		}
	}

	@override
	void dispose() {
		_disposed = true;
		_timer?.cancel();
		_timer = null;
		if (_ownsClient) _client.close();
		super.dispose();
	}
}
