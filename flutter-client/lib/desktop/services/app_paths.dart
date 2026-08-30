import 'dart:io';

/// Every filesystem location the desktop client uses.
///
/// Requirement 3 of the spec: the executable may live anywhere (including a
/// portable folder), but user data always goes to %APPDATA%. Machine-wide
/// state that the privileged service must also reach goes to %PROGRAMDATA%.
///
/// The override parameters exist so unit tests can point this at a temp
/// directory without touching the real profile.
class AppPaths {
  AppPaths({String? appDataOverride, String? programDataOverride})
      : _appDataOverride = appDataOverride,
        _programDataOverride = programDataOverride;

  static const String appFolderName = 'GlukVPN';

  final String? _appDataOverride;
  final String? _programDataOverride;

  String get _appDataBase {
    final override = _appDataOverride;
    if (override != null) return override;
    final env = Platform.environment['APPDATA'];
    if (env != null && env.isNotEmpty) return env;
    // Very defensive fallback; should never happen on a real Windows box.
    final profile = Platform.environment['USERPROFILE'] ?? '.';
    return '$profile\\AppData\\Roaming';
  }

  String get _programDataBase {
    final override = _programDataOverride;
    if (override != null) return override;
    final env = Platform.environment['PROGRAMDATA'];
    if (env != null && env.isNotEmpty) return env;
    return 'C:\\ProgramData';
  }

  /// %APPDATA%\GlukVPN — per-user, roams, never needs admin.
  String get appDataRoot => _join(_appDataBase, appFolderName);

  /// %PROGRAMDATA%\GlukVPN — shared with the LocalSystem service.
  String get programDataRoot => _join(_programDataBase, appFolderName);

  /// DPAPI-protected blobs: refresh token, WireGuard private key.
  String get secureDirPath => _join(appDataRoot, 'secure');

  String get settingsFilePath => _join(appDataRoot, 'settings.json');

  String get usageFilePath => _join(appDataRoot, 'usage.json');

  String get logsDirPath => _join(appDataRoot, 'logs');

  String get uiLogPath => _join(logsDirPath, 'ui.log');

  /// Written by the service, read by us when diagnosing.
  String get serviceLogPath =>
      _join(_join(programDataRoot, 'logs'), 'service.log');

  /// Directory containing glukvpn.exe.
  String get installDir => File(Platform.resolvedExecutable).parent.path;

  /// Where the installer puts the privileged service.
  String get tunnelServiceExePath =>
      _join(_join(installDir, 'service'), 'GlukVpnTunnelService.exe');

  /// Creates the per-user directories. Cheap and idempotent; safe on every
  /// launch. Never creates %PROGRAMDATA% — that is the service's job, since
  /// it needs a restrictive ACL we cannot set without admin.
  Future<void> ensureCreated() async {
    for (final path in <String>[appDataRoot, secureDirPath, logsDirPath]) {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  static String _join(String a, String b) {
    if (a.endsWith('\\') || a.endsWith('/')) return '$a$b';
    return '$a\\$b';
  }
}
