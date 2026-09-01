import 'dart:io' show Platform, Process, ProcessResult;

/// Which platform implementation is active.
///
/// Kept deliberately tiny so that shared code can branch without importing
/// anything Windows- or Android-specific. Android must never gain a
/// compile-time dependency on Windows APIs.
enum PlatformTarget { android, windows, other }

PlatformTarget get currentPlatformTarget {
  if (Platform.isAndroid) return PlatformTarget.android;
  if (Platform.isWindows) return PlatformTarget.windows;
  return PlatformTarget.other;
}

bool get isDesktopTarget => currentPlatformTarget == PlatformTarget.windows;

/// Device label sent to `POST /api/devices/register`.
///
/// The control server accepts any string up to 32 chars in `platform`
/// (see control-server/src/routes/devices.ts), so no backend change is needed.
String get devicePlatformTag {
  switch (currentPlatformTarget) {
    case PlatformTarget.android:
      return 'android';
    case PlatformTarget.windows:
      return 'windows';
    case PlatformTarget.other:
      return 'unknown';
  }
}

/// The machine's own name, as its owner knows it: "ALISHER-PC", "Pixel 7".
///
/// ROUND 6: the device list used to read "Windows · Desktop" for every PC and
/// "Android · Phone" for every phone, which is useless the moment an account
/// has two of either - you cannot tell which row to sign out.
///
/// Deliberately no new dependency for this. Windows exposes the computer name
/// through `dart:io`, and on Android `getprop` is part of the platform, so both
/// answers come from the OS itself. Any failure falls back to the old generic
/// label rather than blocking registration - a device that cannot name itself
/// must still be able to sign in.
Future<String> resolvePhysicalDeviceName() async {
	try {
		switch (currentPlatformTarget) {
			case PlatformTarget.windows:
			case PlatformTarget.other:
				final String host = Platform.localHostname.trim();
				if (host.isNotEmpty && host.toLowerCase() != 'localhost') {
					return _tidyDeviceName(host);
				}
				return suggestedDeviceLabel;
			case PlatformTarget.android:
				final String model = await _getprop('ro.product.model');
				if (model.isEmpty) return suggestedDeviceLabel;
				final String brand = await _getprop('ro.product.brand');
				// "Pixel 7" already contains the brand; "SM-S911B" does not.
				final bool redundant = brand.isEmpty ||
						model.toLowerCase().startsWith(brand.toLowerCase());
				final String label = redundant
						? model
						: '${brand[0].toUpperCase()}${brand.substring(1)} $model';
				return _tidyDeviceName(label);
		}
	} catch (_) {
		// Sandboxed shell, missing binary, locked-down OEM build - all fine.
	}
	return suggestedDeviceLabel;
}

Future<String> _getprop(String key) async {
	final ProcessResult result = await Process.run('getprop', <String>[key]);
	return result.stdout.toString().trim();
}

/// The control server caps `deviceName` at 64 characters, so trim rather than
/// let registration fail validation on a long hostname.
String _tidyDeviceName(String raw) {
	final String clean = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
	if (clean.isEmpty) return suggestedDeviceLabel;
	return clean.length <= 64 ? clean : clean.substring(0, 64).trim();
}

/// Human readable device name suggestion, e.g. "Windows · Desktop".
String get suggestedDeviceLabel {
  switch (currentPlatformTarget) {
    case PlatformTarget.android:
      return 'Android · Phone';
    case PlatformTarget.windows:
      return 'Windows · Desktop';
    case PlatformTarget.other:
      return 'Desktop';
  }
}
