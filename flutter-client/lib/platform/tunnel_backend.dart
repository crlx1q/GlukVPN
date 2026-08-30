/// Platform-neutral tunnel abstraction.
///
/// Shared code (controllers, UI) only ever talks to this interface. The
/// Android implementation wraps the existing `VpnService`; the Windows
/// implementation talks to the privileged C++ service over a named pipe.
///
/// Nothing in this file may import `dart:ffi`, `package:win32` or
/// `wireguard_flutter` — that is what keeps Android free of Windows deps.
library;

/// Coarse tunnel state as reported by the platform layer.
enum TunnelState {
  /// We have not asked yet, or the answer is not usable.
  unknown,

  /// No tunnel.
  disconnected,

  /// Adapter is coming up, handshake not confirmed yet.
  connecting,

  /// Adapter exists and the driver considers the peer live.
  connected,

  /// Tear-down in progress.
  disconnecting,

  /// The backend reported a hard failure.
  error,

  /// The backend itself is not reachable (service missing / stopped).
  unavailable,

  /// The user or the OS refused permission (Android VPN consent, UAC).
  denied,
}

/// Split tunnelling mode. Mirrors the C++ `SplitMode` enum.
enum SplitMode { allApps, onlySelected, excludeSelected }

String splitModeWire(SplitMode mode) {
  switch (mode) {
    case SplitMode.allApps:
      return 'all';
    case SplitMode.onlySelected:
      return 'only';
    case SplitMode.excludeSelected:
      return 'exclude';
  }
}

SplitMode splitModeFromWire(String? value) {
  switch (value) {
    case 'only':
      return SplitMode.onlySelected;
    case 'exclude':
      return SplitMode.excludeSelected;
    default:
      return SplitMode.allApps;
  }
}

/// Everything the UI needs to know about the live tunnel.
///
/// This is intentionally a plain value type so it can be constructed in tests
/// without touching any platform channel.
class TunnelSnapshot {
  const TunnelSnapshot({
    required this.state,
    this.sessionId,
    this.adapterName,
    this.luid,
    this.vpnIp,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.lastHandshakeUnix = 0,
    this.sinceUnix = 0,
    this.killSwitchActive = false,
    this.splitEngine,
    this.errorCode,
    this.errorMessage,
  });

  final TunnelState state;
  final String? sessionId;
  final String? adapterName;
  final int? luid;
  final String? vpnIp;
  final int rxBytes;
  final int txBytes;

  /// Unix seconds of the last successful WireGuard handshake. 0 = never.
  final int lastHandshakeUnix;

  /// Unix seconds when the tunnel came up. 0 = unknown.
  final int sinceUnix;

  final bool killSwitchActive;
  final String? splitEngine;
  final String? errorCode;
  final String? errorMessage;

  static const TunnelSnapshot unknown =
      TunnelSnapshot(state: TunnelState.unknown);

  static const TunnelSnapshot down =
      TunnelSnapshot(state: TunnelState.disconnected);

  int get totalBytes => rxBytes + txBytes;

  bool get hasHandshake => lastHandshakeUnix > 0;

  /// Age of the last handshake. Returns null when there has never been one.
  Duration? handshakeAge(DateTime now) {
    if (lastHandshakeUnix <= 0) return null;
    final then =
        DateTime.fromMillisecondsSinceEpoch(lastHandshakeUnix * 1000, isUtc: true);
    final age = now.toUtc().difference(then);
    return age.isNegative ? Duration.zero : age;
  }

  Duration? uptime(DateTime now) {
    if (sinceUnix <= 0) return null;
    final then =
        DateTime.fromMillisecondsSinceEpoch(sinceUnix * 1000, isUtc: true);
    final up = now.toUtc().difference(then);
    return up.isNegative ? Duration.zero : up;
  }

  TunnelSnapshot copyWith({
    TunnelState? state,
    String? sessionId,
    String? adapterName,
    int? luid,
    String? vpnIp,
    int? rxBytes,
    int? txBytes,
    int? lastHandshakeUnix,
    int? sinceUnix,
    bool? killSwitchActive,
    String? splitEngine,
    String? errorCode,
    String? errorMessage,
  }) {
    return TunnelSnapshot(
      state: state ?? this.state,
      sessionId: sessionId ?? this.sessionId,
      adapterName: adapterName ?? this.adapterName,
      luid: luid ?? this.luid,
      vpnIp: vpnIp ?? this.vpnIp,
      rxBytes: rxBytes ?? this.rxBytes,
      txBytes: txBytes ?? this.txBytes,
      lastHandshakeUnix: lastHandshakeUnix ?? this.lastHandshakeUnix,
      sinceUnix: sinceUnix ?? this.sinceUnix,
      killSwitchActive: killSwitchActive ?? this.killSwitchActive,
      splitEngine: splitEngine ?? this.splitEngine,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  String toString() =>
      'TunnelSnapshot(${state.name}, hs=$lastHandshakeUnix, rx=$rxBytes, '
      'tx=$txBytes, err=$errorCode)';
}

/// Options passed when bringing a tunnel up.
class TunnelUpOptions {
  const TunnelUpOptions({
    this.adapterName = 'GlukVPN',
    this.killSwitch = false,
    this.dns = const <String>[],
    this.mtu,
    this.splitMode = SplitMode.allApps,
    this.splitApps = const <String>[],
    this.bypassRoutes = const <String>[],
    this.endpointIps = const <String>[],
    this.keepAlive = true,
  });

  final String adapterName;
  final bool killSwitch;
  final List<String> dns;
  final int? mtu;
  final SplitMode splitMode;
  final List<String> splitApps;
  final List<String> bypassRoutes;

  /// Server endpoint IPs that must stay reachable outside the tunnel,
  /// otherwise the kill switch would strangle our own handshake.
  final List<String> endpointIps;

  final bool keepAlive;
}

/// Result of a backend operation. Never throws for expected failures — the
/// caller maps [errorCode] onto a user-facing connection phase.
class TunnelResult {
  const TunnelResult.ok(this.snapshot)
      : errorCode = null,
        errorMessage = null;

  const TunnelResult.failure(this.errorCode, this.errorMessage, {this.snapshot});

  final TunnelSnapshot? snapshot;
  final String? errorCode;
  final String? errorMessage;

  bool get ok => errorCode == null;
}

/// The contract every platform must satisfy.
abstract class TunnelBackend {
  /// Cheap probe: is the backend usable at all right now?
  Future<bool> isAvailable();

  /// Bring the tunnel up from a wg-quick style configuration.
  ///
  /// [wgConf] is produced by the existing `TunnelConfig.toWgQuickConfig()`,
  /// which already emits exactly the format both Android and `tunnel.dll`
  /// expect. That shared helper is why this port was cheap.
  Future<TunnelResult> up({
    required String wgConf,
    required String sessionId,
    TunnelUpOptions options = const TunnelUpOptions(),
  });

  /// Tear the tunnel down.
  Future<TunnelResult> down();

  /// Poll current state. Must be safe to call frequently.
  Future<TunnelSnapshot> status();

  /// Change split tunnelling without a full reconnect where possible.
  /// May return `reconnect_required`.
  Future<TunnelResult> setSplit({
    required SplitMode mode,
    List<String> apps = const <String>[],
    List<String> bypassRoutes = const <String>[],
  });

  /// Release any resources. Does not imply disconnecting.
  Future<void> dispose() async {}
}
