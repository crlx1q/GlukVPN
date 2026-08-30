// The most important test file in the desktop client.
//
// The Android app has a long-standing bug where it shows CONNECTED as soon as
// the tunnel is *requested*. On Windows that is unacceptable: the user would
// believe traffic is protected while it is still going out in the clear.
//
// TunnelVerifier is the single gate that prevents it. Four independent
// conditions must all hold before the UI may say CONNECTED.

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/desktop/logic/connection_phase.dart';
import 'package:glukvpn/platform/tunnel_backend.dart';

void main() {
  const verifier = TunnelVerifier();

  final now = DateTime.utc(2026, 8, 31, 12, 0, 0);
  final nowUnix = now.millisecondsSinceEpoch ~/ 1000;

  const ready = ServerTunnelStatus(peerReady: true, subscriptionActive: true);

  /// A tunnel that satisfies every condition, which individual tests then
  /// break one at a time.
  TunnelSnapshot healthy({
    int handshakeAgeSeconds = 5,
    int rxBytes = 4096,
    int txBytes = 2048,
  }) {
    return TunnelSnapshot.down.copyWith(
      state: TunnelState.connected,
      sessionId: 'session-1',
      adapterName: 'GlukVPN',
      vpnIp: '10.9.0.10',
      rxBytes: rxBytes,
      txBytes: txBytes,
      lastHandshakeUnix: nowUnix - handshakeAgeSeconds,
      sinceUnix: nowUnix - 60,
    );
  }

  group('the happy path', () {
    test('all four conditions satisfied means connected', () {
      final verdict = verifier.evaluate(
        snapshot: healthy(),
        serverStatus: ready,
        dataObserved: true,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connected);
      expect(verdict.reason, 'verified');
    });
  });

  group('premature CONNECTED is impossible', () {
    test('a requested but not yet handshaked tunnel is still connecting', () {
      final verdict = verifier.evaluate(
        snapshot: TunnelSnapshot.down.copyWith(
          state: TunnelState.connecting,
          sessionId: 'session-1',
        ),
        serverStatus: ready,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connecting);
      expect(verdict.reason, 'bringing_up');
    });

    test('service says connected but there is no handshake yet', () {
      final verdict = verifier.evaluate(
        snapshot: TunnelSnapshot.down.copyWith(
          state: TunnelState.connected,
          sessionId: 'session-1',
          adapterName: 'GlukVPN',
        ),
        serverStatus: ready,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connecting);
      expect(verdict.reason, 'handshake_pending');
    });

    test('handshake is fresh but the server has not provisioned the peer', () {
      final verdict = verifier.evaluate(
        snapshot: healthy(),
        serverStatus:
            const ServerTunnelStatus(peerReady: false, subscriptionActive: true),
        dataObserved: true,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connecting);
      expect(verdict.reason, 'peer_not_ready');
    });

    test('no traffic has moved yet', () {
      final verdict = verifier.evaluate(
        snapshot: healthy(rxBytes: 0, txBytes: 0),
        serverStatus: ready,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connecting);
      expect(verdict.reason, 'no_traffic_yet');
    });

    test('an inactive subscription blocks CONNECTED', () {
      final verdict = verifier.evaluate(
        snapshot: healthy(),
        serverStatus: const ServerTunnelStatus(
          peerReady: true,
          subscriptionActive: false,
        ),
        dataObserved: true,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.limitReached);
      expect(verdict.reason, 'subscription_inactive');
    });
  });

  group('handshake freshness boundary', () {
    test('179 seconds is still connected', () {
      final verdict = verifier.evaluate(
        snapshot: healthy(handshakeAgeSeconds: 179),
        serverStatus: ready,
        dataObserved: true,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connected);
    });

    test('181 seconds means the tunnel was lost', () {
      final verdict = verifier.evaluate(
        snapshot: healthy(handshakeAgeSeconds: 181),
        serverStatus: ready,
        dataObserved: true,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.tunnelLost);
      expect(verdict.reason, 'handshake_stale');
    });
  });

  group('the tunnel is the source of truth, not the API', () {
    test('a healthy tunnel stays connected when the API is unreachable', () {
      // Requirement 12: the control plane going down must not tear down or
      // mislabel a working tunnel.
      final verdict = verifier.evaluate(
        snapshot: healthy(),
        serverStatus: null,
        dataObserved: true,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connected);
      expect(verdict.reason, 'verified');
    });
  });

  group('service-level failures', () {
    test('an unavailable service is reported, not silently ignored', () {
      final verdict = verifier.evaluate(
        snapshot: TunnelSnapshot.down.copyWith(
          state: TunnelState.unavailable,
        ),
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connectionFailed);
      expect(verdict.reason, 'tunnel_service_unavailable');
    });

    test('a denied request is an access problem', () {
      final verdict = verifier.evaluate(
        snapshot: TunnelSnapshot.down.copyWith(state: TunnelState.denied),
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.accessRevoked);
      expect(verdict.reason, 'tunnel_permission_denied');
    });

    test('an errored tunnel surfaces as a connection failure', () {
      final verdict = verifier.evaluate(
        snapshot: TunnelSnapshot.down.copyWith(
          state: TunnelState.error,
          errorCode: 'driver_unavailable',
        ),
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.connectionFailed);
      expect(verdict.reason, 'tunnel_error');
    });

    test('a down tunnel is simply disconnected', () {
      final verdict = verifier.evaluate(
        snapshot: TunnelSnapshot.down,
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.disconnected);
      expect(verdict.reason, 'down');
    });

    test('a tear-down in progress reports disconnecting', () {
      final verdict = verifier.evaluate(
        snapshot:
            TunnelSnapshot.down.copyWith(state: TunnelState.disconnecting),
        now: now,
      );

      expect(verdict.phase, ConnectionPhase.disconnecting);
      expect(verdict.reason, 'tearing_down');
    });
  });

  group('TunnelSnapshot helpers', () {
    test('totalBytes sums both directions', () {
      expect(healthy(rxBytes: 100, txBytes: 25).totalBytes, 125);
    });

    test('handshakeAge is measured from the last handshake', () {
      final snapshot = healthy(handshakeAgeSeconds: 42);
      expect(snapshot.hasHandshake, isTrue);
      expect(snapshot.handshakeAge(now), const Duration(seconds: 42));
    });

    test('a tunnel that never handshaked has no age', () {
      expect(TunnelSnapshot.down.hasHandshake, isFalse);
      expect(TunnelSnapshot.down.handshakeAge(now), isNull);
    });
  });
}
