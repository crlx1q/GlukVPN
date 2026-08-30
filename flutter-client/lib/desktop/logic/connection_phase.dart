import '../../widgets/connect_button.dart';
import '../../platform/tunnel_backend.dart';

/// Every user-visible state the desktop connect flow can be in.
///
/// Requirement 6 of the spec lists exactly these ten.
enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  serverUnavailable,
  connectionFailed,
  sessionExpired,
  limitReached,
  accessRevoked,
  tunnelLost,
}

/// Reduced phase used by the animated connect button, which only knows four
/// visual states. Keeps the widget decoupled from error taxonomy.


extension ConnectionPhaseX on ConnectionPhase {
  bool get isBusy =>
      this == ConnectionPhase.connecting || this == ConnectionPhase.disconnecting;

  bool get isConnected => this == ConnectionPhase.connected;

  bool get isError {
    switch (this) {
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.limitReached:
      case ConnectionPhase.accessRevoked:
      case ConnectionPhase.tunnelLost:
        return true;
      case ConnectionPhase.disconnected:
      case ConnectionPhase.connecting:
      case ConnectionPhase.connected:
      case ConnectionPhase.disconnecting:
        return false;
    }
  }

  /// The user must sign in again before anything else will work.
  bool get requiresReauth =>
      this == ConnectionPhase.sessionExpired ||
      this == ConnectionPhase.accessRevoked;

  /// Whether the big connect button should accept a tap.
  ///
  /// Note that recoverable failures stay enabled so the button doubles as
  /// "retry" — that is the behaviour users expect after a failed attempt.
  bool get connectEnabled {
    switch (this) {
      case ConnectionPhase.disconnected:
      case ConnectionPhase.connected:
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.tunnelLost:
      case ConnectionPhase.limitReached:
        return true;
      case ConnectionPhase.connecting:
      case ConnectionPhase.disconnecting:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.accessRevoked:
        return false;
    }
  }

  /// Which tray .ico to show. Matches assets/tray/<name>.ico.
  String get trayIconName {
    switch (this) {
      case ConnectionPhase.connected:
        return 'on';
      case ConnectionPhase.connecting:
      case ConnectionPhase.disconnecting:
        return 'connecting';
      case ConnectionPhase.disconnected:
        return 'off';
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.limitReached:
      case ConnectionPhase.accessRevoked:
      case ConnectionPhase.tunnelLost:
        return 'error';
    }
  }

  /// i18n key for the status line under the connect button.
  String get labelKey {
    switch (this) {
      case ConnectionPhase.disconnected:
        return 'status.disconnected';
      case ConnectionPhase.connecting:
        return 'status.connecting';
      case ConnectionPhase.connected:
        return 'status.connected';
      case ConnectionPhase.disconnecting:
        return 'status.disconnecting';
      case ConnectionPhase.serverUnavailable:
        return 'status.serverUnavailable';
      case ConnectionPhase.connectionFailed:
        return 'status.connectionFailed';
      case ConnectionPhase.sessionExpired:
        return 'status.sessionExpired';
      case ConnectionPhase.limitReached:
        return 'status.limitReached';
      case ConnectionPhase.accessRevoked:
        return 'status.accessRevoked';
      case ConnectionPhase.tunnelLost:
        return 'status.tunnelLost';
    }
  }

  ConnectPhase get buttonPhase {
    switch (this) {
      case ConnectionPhase.connected:
        return ConnectPhase.connected;
      case ConnectionPhase.connecting:
        return ConnectPhase.connecting;
      case ConnectionPhase.disconnecting:
        return ConnectPhase.disconnecting;
      case ConnectionPhase.disconnected:
      case ConnectionPhase.serverUnavailable:
      case ConnectionPhase.connectionFailed:
      case ConnectionPhase.sessionExpired:
      case ConnectionPhase.limitReached:
      case ConnectionPhase.accessRevoked:
      case ConnectionPhase.tunnelLost:
        return ConnectPhase.idle;
    }
  }
}

/// Outcome of evaluating whether we may legitimately show CONNECTED.
class TunnelVerdict {
  const TunnelVerdict(this.phase, this.reason);

  final ConnectionPhase phase;

  /// Machine-readable reason, useful in logs and tests.
  final String reason;

  @override
  String toString() => 'TunnelVerdict(${phase.name}, $reason)';
}

/// Minimal view of `GET /api/vpn/status` needed by the verifier.
///
/// Declared here rather than importing the full model so this file stays
/// trivially testable and free of network types.
class ServerTunnelStatus {
  const ServerTunnelStatus({
    required this.peerReady,
    required this.subscriptionActive,
  });

  final bool peerReady;
  final bool subscriptionActive;
}

/// Decides when the UI is allowed to say CONNECTED.
///
/// This exists specifically to prevent the premature-CONNECTED bug the
/// Android client has. Four independent conditions must all hold:
///
///   1. the privileged service reports state == connected;
///   2. the WireGuard handshake is fresh (within [handshakeStaleAfter]);
///   3. the control server agrees the peer is provisioned (peerReady);
///   4. we have observed actual data movement or a gateway ping.
///
/// Anything less is still "connecting". Critically, a *missing* server status
/// (API down, captive network) never invalidates an otherwise healthy tunnel —
/// the tunnel is the source of truth, not our control plane.
class TunnelVerifier {
  const TunnelVerifier({
    this.handshakeStaleAfter = const Duration(seconds: 180),
  });

  final Duration handshakeStaleAfter;

  TunnelVerdict evaluate({
    required TunnelSnapshot snapshot,
    ServerTunnelStatus? serverStatus,
    bool dataObserved = false,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now().toUtc();

    switch (snapshot.state) {
      case TunnelState.unavailable:
        return const TunnelVerdict(
          ConnectionPhase.connectionFailed,
          'tunnel_service_unavailable',
        );
      case TunnelState.denied:
        return const TunnelVerdict(
          ConnectionPhase.connectionFailed,
          'tunnel_permission_denied',
        );
      case TunnelState.error:
        return TunnelVerdict(
          ConnectionPhase.connectionFailed,
          snapshot.errorCode ?? 'tunnel_error',
        );
      case TunnelState.disconnecting:
        return const TunnelVerdict(
          ConnectionPhase.disconnecting,
          'tearing_down',
        );
      case TunnelState.disconnected:
        return const TunnelVerdict(ConnectionPhase.disconnected, 'down');
      case TunnelState.unknown:
      case TunnelState.connecting:
        return const TunnelVerdict(ConnectionPhase.connecting, 'bringing_up');
      case TunnelState.connected:
        break;
    }

    // Condition 3: subscription revoked out from under a live tunnel.
    if (serverStatus != null && !serverStatus.subscriptionActive) {
      return const TunnelVerdict(
        ConnectionPhase.limitReached,
        'subscription_inactive',
      );
    }

    // Condition 2: handshake freshness.
    final age = snapshot.handshakeAge(at);
    if (age == null) {
      return const TunnelVerdict(
        ConnectionPhase.connecting,
        'handshake_pending',
      );
    }
    if (age > handshakeStaleAfter) {
      // We had a handshake before and lost it: that is a dropped tunnel,
      // not a slow start.
      return const TunnelVerdict(
        ConnectionPhase.tunnelLost,
        'handshake_stale',
      );
    }

    // Condition 3 (positive form). A null serverStatus means the API is
    // unreachable; we deliberately do NOT punish the tunnel for that.
    if (serverStatus != null && !serverStatus.peerReady) {
      return const TunnelVerdict(
        ConnectionPhase.connecting,
        'peer_not_ready',
      );
    }

    // Condition 4: proof that packets actually flow.
    if (!dataObserved && snapshot.rxBytes <= 0) {
      return const TunnelVerdict(
        ConnectionPhase.connecting,
        'no_traffic_yet',
      );
    }

    return const TunnelVerdict(ConnectionPhase.connected, 'verified');
  }
}

/// Maps a control-API failure onto a user-facing phase.
///
/// [refreshFailed] distinguishes "token was stale but we recovered" from
/// "the session is genuinely gone".
ConnectionPhase phaseForApiError({
  int? statusCode,
  String? code,
  bool refreshFailed = false,
}) {
  final upper = code?.toUpperCase();

  if (statusCode == 401) {
    return refreshFailed
        ? ConnectionPhase.sessionExpired
        : ConnectionPhase.connectionFailed;
  }

  if (statusCode == 403) {
    switch (upper) {
      case 'DEVICE_REVOKED':
      case 'DEVICE_INACTIVE':
        return ConnectionPhase.accessRevoked;
      case 'SUBSCRIPTION_REQUIRED':
      case 'SUBSCRIPTION_EXPIRED':
        return ConnectionPhase.limitReached;
      default:
        return ConnectionPhase.accessRevoked;
    }
  }

  if (statusCode == 409 || statusCode == 429) {
    return ConnectionPhase.limitReached;
  }

  if (statusCode != null && statusCode >= 500 && statusCode <= 599) {
    return ConnectionPhase.serverUnavailable;
  }

  // Network-level failure, timeout, DNS, no status code at all.
  return ConnectionPhase.connectionFailed;
}


