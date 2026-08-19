import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/services/vpn_service.dart';

void main() {
  group('VpnService.parseStage', () {
    test('maps the connected stage', () {
      expect(VpnService.parseStage('VpnStage.connected'), TunnelStage.connected);
      expect(VpnService.parseStage('connected'), TunnelStage.connected);
    });

    test('treats every in-progress platform stage as connecting', () {
      expect(VpnService.parseStage('VpnStage.connecting'), TunnelStage.connecting);
      expect(VpnService.parseStage('VpnStage.authenticating'), TunnelStage.connecting);
      expect(VpnService.parseStage('VpnStage.reconnect'), TunnelStage.connecting);
      expect(VpnService.parseStage('VpnStage.waitingConnection'), TunnelStage.connecting);
    });

    test('keeps preparing separate, since that is when Android asks for permission', () {
      expect(VpnService.parseStage('VpnStage.preparing'), TunnelStage.preparing);
    });

    test('maps teardown stages', () {
      expect(VpnService.parseStage('VpnStage.disconnecting'), TunnelStage.disconnecting);
      expect(VpnService.parseStage('VpnStage.exiting'), TunnelStage.disconnecting);
    });

    test('maps down stages, including a lost connection', () {
      expect(VpnService.parseStage('VpnStage.disconnected'), TunnelStage.disconnected);
      expect(VpnService.parseStage('VpnStage.noConnection'), TunnelStage.disconnected);
    });

    test('surfaces a denied VPN permission so the UI can explain it', () {
      expect(VpnService.parseStage('VpnStage.denied'), TunnelStage.denied);
    });

    test('is tolerant of casing, padding and unexpected values', () {
      expect(VpnService.parseStage(' VpnStage.Connected '), TunnelStage.connected);
      expect(VpnService.parseStage('DISCONNECTED'), TunnelStage.disconnected);
      expect(VpnService.parseStage('VpnStage.somethingNew'), TunnelStage.unknown);
      expect(VpnService.parseStage(''), TunnelStage.unknown);
      expect(VpnService.parseStage(null), TunnelStage.unknown);
      expect(VpnService.parseStage(42), TunnelStage.unknown);
    });
  });

  group('TunnelStage', () {
    test('only the connected stage counts as connected', () {
      expect(TunnelStage.connected.isConnected, isTrue);
      expect(TunnelStage.connecting.isConnected, isFalse);
      expect(TunnelStage.disconnected.isConnected, isFalse);
      expect(TunnelStage.denied.isConnected, isFalse);
      expect(TunnelStage.error.isConnected, isFalse);
      expect(TunnelStage.unknown.isConnected, isFalse);
    });

    test('transient stages are busy, settled ones are not', () {
      expect(TunnelStage.connecting.isBusy, isTrue);
      expect(TunnelStage.preparing.isBusy, isTrue);
      expect(TunnelStage.disconnecting.isBusy, isTrue);
      expect(TunnelStage.connected.isBusy, isFalse);
      expect(TunnelStage.disconnected.isBusy, isFalse);
    });
  });
}
