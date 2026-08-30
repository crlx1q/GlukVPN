// Phase-machine behaviour that the desktop UI depends on.
//
// These are pure Dart tests: no Flutter bindings, no platform channels, no
// network. They run on any machine with `flutter test`, including CI without
// Windows.

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/desktop/logic/connection_phase.dart';
import 'package:glukvpn/widgets/connect_button.dart';

void main() {
  group('ConnectionPhaseX', () {
    test('only connecting and disconnecting are busy', () {
      expect(ConnectionPhase.connecting.isBusy, isTrue);
      expect(ConnectionPhase.disconnecting.isBusy, isTrue);

      expect(ConnectionPhase.disconnected.isBusy, isFalse);
      expect(ConnectionPhase.connected.isBusy, isFalse);
      expect(ConnectionPhase.tunnelLost.isBusy, isFalse);
    });

    test('isConnected is true for exactly one phase', () {
      final connected = ConnectionPhase.values.where((p) => p.isConnected);
      expect(connected, <ConnectionPhase>[ConnectionPhase.connected]);
    });

    test('every failure phase reports isError', () {
      const failures = <ConnectionPhase>[
        ConnectionPhase.serverUnavailable,
        ConnectionPhase.connectionFailed,
        ConnectionPhase.sessionExpired,
        ConnectionPhase.limitReached,
        ConnectionPhase.accessRevoked,
        ConnectionPhase.tunnelLost,
      ];
      for (final phase in failures) {
        expect(phase.isError, isTrue, reason: '${phase.name} should be an error');
      }

      expect(ConnectionPhase.disconnected.isError, isFalse);
      expect(ConnectionPhase.connected.isError, isFalse);
    });

    test('only session expiry and revocation require re-authentication', () {
      final reauth =
          ConnectionPhase.values.where((p) => p.requiresReauth).toSet();
      expect(
        reauth,
        <ConnectionPhase>{
          ConnectionPhase.sessionExpired,
          ConnectionPhase.accessRevoked,
        },
      );
    });

    test('the Connect button stays usable after a failure', () {
      // Requirement: a failed attempt must never leave a dead button.
      expect(ConnectionPhase.connectionFailed.connectEnabled, isTrue);
      expect(ConnectionPhase.serverUnavailable.connectEnabled, isTrue);
      expect(ConnectionPhase.tunnelLost.connectEnabled, isTrue);
      expect(ConnectionPhase.limitReached.connectEnabled, isTrue);

      // ...but not while a transition is already in flight.
      expect(ConnectionPhase.connecting.connectEnabled, isFalse);
      expect(ConnectionPhase.disconnecting.connectEnabled, isFalse);
    });

    test('tray icon names map onto the four shipped .ico files', () {
      expect(ConnectionPhase.disconnected.trayIconName, 'off');
      expect(ConnectionPhase.connecting.trayIconName, 'connecting');
      expect(ConnectionPhase.disconnecting.trayIconName, 'connecting');
      expect(ConnectionPhase.connected.trayIconName, 'on');
      expect(ConnectionPhase.tunnelLost.trayIconName, 'error');

      // Guards against adding a phase without an icon.
      const shipped = <String>{'off', 'connecting', 'on', 'error'};
      for (final phase in ConnectionPhase.values) {
        expect(shipped, contains(phase.trayIconName));
      }
    });

    test('every phase has a translatable label key', () {
      for (final phase in ConnectionPhase.values) {
        expect(phase.labelKey, 'phase.${phase.name}');
      }
    });

    test('buttonPhase collapses failures onto disconnected', () {
      expect(ConnectionPhase.connectionFailed.buttonPhase,
          ConnectPhase.disconnected);
      expect(ConnectionPhase.tunnelLost.buttonPhase, ConnectPhase.disconnected);
      expect(ConnectionPhase.connected.buttonPhase, ConnectPhase.connected);
      expect(ConnectionPhase.connecting.buttonPhase, ConnectPhase.connecting);
    });
  });

  group('phaseForApiError', () {
    test('401 only expires the session when the refresh also failed', () {
      expect(
        phaseForApiError(statusCode: 401, refreshFailed: true),
        ConnectionPhase.sessionExpired,
      );
      expect(
        phaseForApiError(statusCode: 401),
        ConnectionPhase.connectionFailed,
      );
    });

    test('a revoked or deactivated device is an access problem', () {
      expect(
        phaseForApiError(statusCode: 403, code: 'DEVICE_REVOKED'),
        ConnectionPhase.accessRevoked,
      );
      expect(
        phaseForApiError(statusCode: 403, code: 'device_inactive'),
        ConnectionPhase.accessRevoked,
      );
    });

    test('subscription problems are a limit, not a revocation', () {
      expect(
        phaseForApiError(statusCode: 403, code: 'SUBSCRIPTION_REQUIRED'),
        ConnectionPhase.limitReached,
      );
      expect(
        phaseForApiError(statusCode: 403, code: 'SUBSCRIPTION_EXPIRED'),
        ConnectionPhase.limitReached,
      );
    });

    test('device and session ceilings map to limitReached', () {
      expect(phaseForApiError(statusCode: 409), ConnectionPhase.limitReached);
      expect(phaseForApiError(statusCode: 429), ConnectionPhase.limitReached);
    });

    test('server faults are reported as the server being unavailable', () {
      for (final code in <int>[500, 502, 503, 504]) {
        expect(
          phaseForApiError(statusCode: code),
          ConnectionPhase.serverUnavailable,
          reason: 'HTTP $code',
        );
      }
    });

    test('a transport failure with no status is a generic failure', () {
      expect(phaseForApiError(), ConnectionPhase.connectionFailed);
      expect(phaseForApiError(statusCode: 0), ConnectionPhase.connectionFailed);
    });
  });
}
