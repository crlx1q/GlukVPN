import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/models/models.dart';

void main() {
  group('TunnelConfig', () {
    Map<String, dynamic> payload() => <String, dynamic>{
          'sessionId': 'session-1',
          'interfaceAddress': '10.8.0.5/32',
          'dns': <String>['1.1.1.1', '1.0.0.1'],
          'mtu': 1420,
          'peerPublicKey': 'nodePublicKey0000000000000000000000000000000=',
          'endpoint': '138.2.186.223:51820',
          'allowedIps': <String>['0.0.0.0/0'],
          'persistentKeepalive': 25,
        };

    test('parses what POST /api/vpn/connect returns', () {
      final TunnelConfig tunnel = TunnelConfig.fromJson(payload());
      expect(tunnel.sessionId, 'session-1');
      expect(tunnel.interfaceAddress, '10.8.0.5/32');
      expect(tunnel.assignedIp, '10.8.0.5');
      expect(tunnel.dns, <String>['1.1.1.1', '1.0.0.1']);
      expect(tunnel.mtu, 1420);
      expect(tunnel.allowedIps, <String>['0.0.0.0/0']);
      expect(tunnel.persistentKeepalive, 25);
    });

    test('derives the in-tunnel gateway used as the ping target', () {
      expect(TunnelConfig.fromJson(payload()).gatewayIp, '10.8.0.1');
    });

    test('builds a wg-quick config that routes everything through the node', () {
      final TunnelConfig tunnel = TunnelConfig.fromJson(payload());
      final String config = tunnel.toWgQuickConfig(privateKeyBase64: 'DEVICE_PRIVATE_KEY');

      expect(config, contains('[Interface]'));
      expect(config, contains('PrivateKey = DEVICE_PRIVATE_KEY'));
      expect(config, contains('Address = 10.8.0.5/32'));
      expect(config, contains('DNS = 1.1.1.1, 1.0.0.1'));
      expect(config, contains('MTU = 1420'));
      expect(config, contains('[Peer]'));
      expect(config, contains('PublicKey = nodePublicKey0000000000000000000000000000000='));
      expect(config, contains('AllowedIPs = 0.0.0.0/0'));
      expect(config, contains('Endpoint = 138.2.186.223:51820'));
      expect(config, contains('PersistentKeepalive = 25'));
    });

    test('log summary never contains key material', () {
      final TunnelConfig tunnel = TunnelConfig.fromJson(payload());
      final String summary = tunnel.describeForLog();
      expect(summary, contains('session-1'));
      expect(summary, contains('138.2.186.223:51820'));
      expect(summary, isNot(contains('PrivateKey')));
      expect(summary, isNot(contains('nodePublicKey0000000000000000000000000000000=')));
      expect(tunnel.toString(), summary);
    });

    test('falls back to a full tunnel when allowedIps is empty', () {
      final Map<String, dynamic> json = payload()..['allowedIps'] = <String>[];
      final String config = TunnelConfig.fromJson(json)
          .toWgQuickConfig(privateKeyBase64: 'k');
      expect(config, contains('AllowedIPs = 0.0.0.0/0'));
    });
  });

  group('VpnNodeInfo', () {
    test('parses the public node projection', () {
      final VpnNodeInfo node = VpnNodeInfo.fromJson(<String, dynamic>{
        'id': 'node-1',
        'name': 'de-01',
        'country': 'Germany',
        'countryCode': 'DE',
        'host': 'vpn.example.com',
        'port': 51820,
        'status': 'ONLINE',
        'online': true,
        'connectable': true,
        'loadPercent': 4,
        'activePeers': 2,
        'capacity': 50,
        'cpuPercent': 7.5,
        'ramPercent': 41.2,
        'uptimeSeconds': 90000,
        'agentVersion': '0.1.0',
        'lastHeartbeat': '2026-08-19T11:00:00.000Z',
      });

      expect(node.name, 'de-01');
      expect(node.countryCode, 'DE');
      expect(node.endpoint, 'vpn.example.com:51820');
      expect(node.online, isTrue);
      expect(node.connectable, isTrue);
      expect(node.loadPercent, 4);
      expect(node.cpuPercent, 7.5);
      expect(node.uptimeSeconds, 90000);
      expect(node.lastHeartbeat?.toUtc().hour, 11);
    });

    test('survives a pending node with no metrics yet', () {
      final VpnNodeInfo node = VpnNodeInfo.fromJson(<String, dynamic>{
        'id': 'node-2',
        'name': 'de-02',
        'country': 'Germany',
        'countryCode': 'DE',
        'host': '203.0.113.10',
        'status': 'PENDING',
      });

      expect(node.port, 51820, reason: 'defaults to the WireGuard port');
      expect(node.online, isFalse);
      expect(node.connectable, isFalse);
      expect(node.cpuPercent, isNull);
      expect(node.uptimeSeconds, isNull);
      expect(node.agentVersion, isNull);
      expect(node.lastHeartbeat, isNull);
    });
  });

  group('VpnSessionInfo', () {
    test('flattens the nested node and exposes byte totals', () {
      final VpnSessionInfo session = VpnSessionInfo.fromJson(<String, dynamic>{
        'id': 'session-9',
        'status': 'ACTIVE',
        'assignedVpnIp': '10.8.0.7',
        'bytesRx': 1500,
        'bytesTx': 500,
        'durationSec': 65,
        'connectedAt': '2026-08-19T10:00:00.000Z',
        'lastHandshakeAt': '2026-08-19T10:01:00.000Z',
        'node': <String, dynamic>{
          'id': 'node-1',
          'name': 'de-01',
          'country': 'Germany',
          'countryCode': 'DE',
          'host': 'vpn.example.com',
        },
        'deviceId': 'device-3',
      });

      expect(session.isLive, isTrue);
      expect(session.isActive, isTrue);
      expect(session.totalBytes, 2000);
      expect(session.nodeName, 'de-01');
      expect(session.nodeCountryCode, 'DE');
      expect(session.deviceId, 'device-3');
    });

    test('treats PENDING as live but not active', () {
      final VpnSessionInfo session = VpnSessionInfo.fromJson(<String, dynamic>{
        'id': 'session-10',
        'status': 'PENDING',
        'assignedVpnIp': '10.8.0.8',
      });
      expect(session.isLive, isTrue);
      expect(session.isActive, isFalse);
      expect(session.totalBytes, 0);
      expect(session.nodeName, isNull);
    });

    test('a closed session is neither live nor active', () {
      final VpnSessionInfo session = VpnSessionInfo.fromJson(<String, dynamic>{
        'id': 'session-11',
        'status': 'CLOSED',
        'assignedVpnIp': '10.8.0.9',
        'disconnectedAt': '2026-08-19T12:00:00.000Z',
      });
      expect(session.isLive, isFalse);
      expect(session.isActive, isFalse);
    });
  });

  group('VpnStatusInfo', () {
    test('parses a connected status with an installed peer', () {
      final VpnStatusInfo status = VpnStatusInfo.fromJson(<String, dynamic>{
        'connected': true,
        'peerReady': true,
        'subscriptionActive': true,
        'session': <String, dynamic>{
          'id': 'session-9',
          'status': 'ACTIVE',
          'assignedVpnIp': '10.8.0.7',
        },
        'serverTime': '2026-08-19T10:05:00.000Z',
      });

      expect(status.connected, isTrue);
      expect(status.peerReady, isTrue);
      expect(status.session?.id, 'session-9');
      expect(status.serverTime, isNotNull);
    });

    test('reports a disconnected status with no session', () {
      final VpnStatusInfo status = VpnStatusInfo.fromJson(<String, dynamic>{
        'connected': false,
        'peerReady': false,
        'subscriptionActive': false,
      });
      expect(status.connected, isFalse);
      expect(status.session, isNull);
      expect(status.subscriptionActive, isFalse);
    });
  });

  group('SubscriptionInfo', () {
    test('is active only when ACTIVE and not expired', () {
      final DateTime future = DateTime.now().add(const Duration(days: 5));
      final DateTime past = DateTime.now().subtract(const Duration(days: 1));

      expect(
        SubscriptionInfo.fromJson(<String, dynamic>{
          'status': 'ACTIVE',
          'expiresAt': future.toIso8601String(),
        }).isActive,
        isTrue,
      );
      expect(
        SubscriptionInfo.fromJson(<String, dynamic>{
          'status': 'ACTIVE',
          'expiresAt': past.toIso8601String(),
        }).isActive,
        isFalse,
      );
      expect(
        SubscriptionInfo.fromJson(<String, dynamic>{
          'status': 'EXPIRED',
          'expiresAt': future.toIso8601String(),
        }).isActive,
        isFalse,
      );
      expect(
        SubscriptionInfo.fromJson(<String, dynamic>{'status': 'ACTIVE'}).isActive,
        isFalse,
        reason: 'no expiry means we cannot claim it is active',
      );
    });
  });

  group('DeviceInfo / DevicesResult', () {
    test('parses the device list with the connected node name', () {
      final DevicesResult result = DevicesResult.fromJson(<String, dynamic>{
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'device-1',
            'deviceName': 'android-a1b2',
            'status': 'ACTIVE',
            'platform': 'android',
            'isCurrent': true,
            'connected': true,
            'connectedNode': <String, dynamic>{'id': 'node-1', 'name': 'de-01'},
            'lastSeen': '2026-08-19T10:00:00.000Z',
          },
          <String, dynamic>{
            'id': 'device-2',
            'deviceName': 'old-phone',
            'status': 'REVOKED',
          },
        ],
        'maxDevices': 3,
      });

      expect(result.maxDevices, 3);
      expect(result.devices, hasLength(2));
      expect(result.devices.first.isCurrent, isTrue);
      expect(result.devices.first.connectedNodeName, 'de-01');
      expect(result.devices.first.isActive, isTrue);
      expect(result.devices.last.isActive, isFalse);
      expect(result.devices.last.connected, isFalse);
      expect(result.devices.last.connectedNodeName, isNull);
    });

    test('tolerates a missing devices array', () {
      final DevicesResult result = DevicesResult.fromJson(<String, dynamic>{});
      expect(result.devices, isEmpty);
      expect(result.maxDevices, 3);
    });
  });

  group('AuthUser', () {
    test('parses limits used by the UI', () {
      final AuthUser user = AuthUser.fromJson(<String, dynamic>{
        'id': 'user-1',
        'username': 'testuser',
        'status': 'ACTIVE',
        'isAdmin': false,
        'maxDevices': 3,
        'maxConcurrentSessions': 1,
        'createdAt': '2026-08-19T09:00:00.000Z',
      });

      expect(user.username, 'testuser');
      expect(user.isActive, isTrue);
      expect(user.isAdmin, isFalse);
      expect(user.maxDevices, 3);
      expect(user.maxConcurrentSessions, 1);
    });

    test('a disabled user is not active', () {
      final AuthUser user = AuthUser.fromJson(<String, dynamic>{
        'id': 'user-2',
        'username': 'blocked',
        'status': 'DISABLED',
      });
      expect(user.isActive, isFalse);
    });

    test('keeps the immutable public id and labels it for the UI', () {
      final AuthUser user = AuthUser.fromJson(<String, dynamic>{
        'id': 'user-3',
        'publicId': '00000042',
        'username': 'testuser',
        'status': 'ACTIVE',
      });

      expect(user.publicId, '00000042');
      expect(user.publicIdLabel, 'ID 00000042');
    });

    test('renaming changes the nickname and never the public id', () {
      final AuthUser user = AuthUser.fromJson(<String, dynamic>{
        'id': 'user-3',
        'publicId': '00000042',
        'username': 'oldname',
        'status': 'ACTIVE',
      });

      final AuthUser renamed = user.copyWith(username: 'newname');
      expect(renamed.username, 'newname');
      expect(renamed.publicId, '00000042');
      expect(renamed.id, user.id);
    });

    test('an older server that does not send publicId still parses', () {
      final AuthUser user = AuthUser.fromJson(<String, dynamic>{
        'id': 'user-4',
        'username': 'legacy',
        'status': 'ACTIVE',
      });
      expect(user.publicId, isEmpty);
      expect(user.publicIdLabel, 'ID unavailable');
    });
  });

  group('ChannelVersion', () {
    test('parses GET /api/version for the prod channel', () {
      final ChannelVersion version = ChannelVersion.fromJson(<String, dynamic>{
        'service': 'glukvpn-control',
        'channel': 'prod',
        'version': '1.0.0',
        'commit': '6ed631cd6bd54ab461b920f903484e0049ed3edf',
        'migration': '20260820130000_deploy_jobs',
        'database': 'up',
        'releasedAt': '2026-08-20T12:00:00.000Z',
      });

      expect(version.channel, 'prod');
      expect(version.isBeta, isFalse);
      expect(version.channelLabel, 'PROD');
      expect(version.label, 'PROD 1.0.0');
      expect(version.commitShort, '6ed631c');
      expect(version.databaseUp, isTrue);
      expect(version.releasedAt, isNotNull);
    });

    test('flags the beta channel and a database that is down', () {
      final ChannelVersion version = ChannelVersion.fromJson(<String, dynamic>{
        'channel': 'beta',
        'version': '1.2.0',
        'database': 'down',
      });

      expect(version.isBeta, isTrue);
      expect(version.channelLabel, 'BETA');
      expect(version.label, 'BETA 1.2.0');
      expect(version.databaseUp, isFalse);
      expect(version.commitShort, isEmpty);
    });
  });

  group('UsernameChangeResult', () {
    test('reads the nested user object returned by the rename endpoint', () {
      final UsernameChangeResult result =
          UsernameChangeResult.fromJson(<String, dynamic>{
        'user': <String, dynamic>{
          'id': 'user-1',
          'publicId': '00000001',
          'username': 'newname',
        },
        'changed': true,
      });

      expect(result.username, 'newname');
      expect(result.publicId, '00000001');
      expect(result.changed, isTrue);
    });

    test('a no-op rename is reported as unchanged', () {
      final UsernameChangeResult result =
          UsernameChangeResult.fromJson(<String, dynamic>{
        'user': <String, dynamic>{'publicId': '00000001', 'username': 'same'},
        'changed': false,
      });
      expect(result.changed, isFalse);
    });
  });
}
