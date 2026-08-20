import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/models/models.dart';

/// What a user is allowed to see about a server, and what they are not.
///
/// The rule these tests lock in: the UI reads places from the backend and never
/// shows an internal node handle.
void main() {
  group('VpnNodeInfo geography', () {
    Map<String, dynamic> nodeJson({
      String name = 'de-01',
      String country = 'Germany',
      String countryCode = 'DE',
      String? region = 'Hesse',
      String? city = 'Frankfurt',
      String title = 'Germany',
      String subtitle = 'Frankfurt',
      String pingTarget = '203.0.113.10',
    }) {
      return <String, dynamic>{
        'id': 'node-1',
        'name': name,
        'country': country,
        'countryCode': countryCode,
        'region': region,
        'city': city,
        'title': title,
        'subtitle': subtitle,
        'pingTarget': pingTarget,
        'host': 'de1.example.net',
        'port': 51820,
        'status': 'ACTIVE',
        'online': true,
        'connectable': true,
        'loadPercent': 12.5,
        'activePeers': 3,
        'capacity': 250,
      };
    }

    test('parses the structured place fields', () {
      final VpnNodeInfo node = VpnNodeInfo.fromJson(nodeJson());
      expect(node.country, 'Germany');
      expect(node.countryCode, 'DE');
      expect(node.region, 'Hesse');
      expect(node.city, 'Frankfurt');
      expect(node.pingTarget, '203.0.113.10');
    });

    test('shows Germany / Frankfurt, never the node name', () {
      final VpnNodeInfo node = VpnNodeInfo.fromJson(nodeJson());
      expect(node.displayTitle, 'Germany');
      expect(node.displaySubtitle, 'Frankfurt');
      expect(node.displayTitle, isNot(contains('de-01')));
      expect(node.displaySubtitle, isNot(contains('de-01')));
      // The handle is still available for admin and debug surfaces.
      expect(node.name, 'de-01');
    });

    test('falls back to country and city when the API sends no display lines',
        () {
      final VpnNodeInfo node =
          VpnNodeInfo.fromJson(nodeJson(title: '', subtitle: ''));
      expect(node.displayTitle, 'Germany');
      expect(node.displaySubtitle, 'Frankfurt');
    });

    test('falls back to region, then country code, but never to the name', () {
      final VpnNodeInfo noCity = VpnNodeInfo.fromJson(
        nodeJson(title: '', subtitle: '', city: null),
      );
      expect(noCity.displaySubtitle, 'Hesse');

      final VpnNodeInfo bare = VpnNodeInfo.fromJson(
        nodeJson(title: '', subtitle: '', city: null, region: null),
      );
      expect(bare.displaySubtitle, 'DE');
      expect(bare.displaySubtitle, isNot('de-01'));
    });

    test('latency host prefers the ping target over the tunnel endpoint', () {
      final VpnNodeInfo node = VpnNodeInfo.fromJson(nodeJson());
      expect(node.latencyHost, '203.0.113.10');

      final VpnNodeInfo noTarget =
          VpnNodeInfo.fromJson(nodeJson(pingTarget: ''));
      expect(noTarget.latencyHost, 'de1.example.net');
    });
  });

  group('ping levels', () {
    test('buckets a round-trip into the three signal levels', () {
      expect(pingLevelFor(24), PingLevel.excellent);
      expect(pingLevelFor(79), PingLevel.excellent);
      expect(pingLevelFor(80), PingLevel.medium);
      expect(pingLevelFor(179), PingLevel.medium);
      expect(pingLevelFor(180), PingLevel.low);
      expect(pingLevelFor(900), PingLevel.low);
    });

    test('an absent or nonsense sample is unknown, not "low"', () {
      expect(pingLevelFor(null), PingLevel.unknown);
      expect(pingLevelFor(0), PingLevel.unknown);
      expect(pingLevelFor(-5), PingLevel.unknown);
    });

    test('lit bars match the level', () {
      expect(PingLevel.excellent.bars, 3);
      expect(PingLevel.medium.bars, 2);
      expect(PingLevel.low.bars, 1);
      expect(PingLevel.unknown.bars, 0);
      expect(PingLevel.unknown.label, isEmpty);
      expect(PingLevel.excellent.label, 'Excellent');
    });
  });

  group('AuthUser identity', () {
    Map<String, dynamic> userJson({
      String publicId = '10758930',
      String? email,
      bool emailVerified = false,
      Map<String, dynamic>? origin,
    }) {
      return <String, dynamic>{
        'id': '9f1c2e77-0000-4000-8000-000000000001',
        'publicId': publicId,
        'username': 'gluk',
        'email': email,
        'emailVerified': emailVerified,
        'status': 'ACTIVE',
        'isAdmin': false,
        'maxDevices': 5,
        'maxConcurrentSessions': 2,
        if (origin != null) 'origin': origin,
      };
    }

    test('keeps the public account number separate from the internal id', () {
      final AuthUser user = AuthUser.fromJson(userJson());
      expect(user.publicId, '10758930');
      expect(user.publicId.startsWith('1'), isTrue);
      expect(user.publicId.length, 8);
      expect(user.id, isNot(user.publicId));
      expect(user.publicIdLabel, 'ID 10758930');
    });

    test('renaming keeps the account number and the email', () {
      final AuthUser user =
          AuthUser.fromJson(userJson(email: 'a@example.com', emailVerified: true));
      final AuthUser renamed = user.copyWith(username: 'newname');
      expect(renamed.username, 'newname');
      expect(renamed.publicId, user.publicId);
      expect(renamed.id, user.id);
      expect(renamed.email, 'a@example.com');
      expect(renamed.emailVerified, isTrue);
    });

    test('an unknown account number renders as nothing, not a placeholder', () {
      final AuthUser user = AuthUser.fromJson(userJson(publicId: ''));
      expect(user.publicIdLabel, isEmpty);
    });

    test('approximate origin is country and region only', () {
      final AuthUser user = AuthUser.fromJson(
        userJson(
          origin: <String, dynamic>{
            'country': 'Germany',
            'countryCode': 'DE',
            'region': 'Hesse',
          },
        ),
      );
      expect(user.originCountry, 'Germany');
      expect(user.originCountryCode, 'DE');
      expect(user.originRegion, 'Hesse');
      expect(user.originLabel, 'Germany, Hesse');
    });

    test('origin collapses sensibly when the server resolved less', () {
      final AuthUser countryOnly = AuthUser.fromJson(
        userJson(origin: <String, dynamic>{'country': 'Germany'}),
      );
      expect(countryOnly.originLabel, 'Germany');

      final AuthUser nothing = AuthUser.fromJson(userJson());
      expect(nothing.originLabel, isNull);
    });
  });
}
