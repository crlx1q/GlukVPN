import 'dart:io' show Platform;

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
