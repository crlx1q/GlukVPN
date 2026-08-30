// Requirement 8: Auto must pick the best node by availability, ping, load and
// subscription access. Free accounts get Auto only; paid accounts may choose.

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/desktop/logic/node_selector.dart';
import 'package:glukvpn/models/models.dart';

VpnNodeInfo node(
  String name, {
  String country = 'Germany',
  String countryCode = 'DE',
  bool online = true,
  bool connectable = true,
  int loadPercent = 20,
  int activePeers = 10,
  int capacity = 100,
}) {
  return VpnNodeInfo(
    id: name,
    name: name,
    country: country,
    countryCode: countryCode,
    host: '$name.gluk.tech',
    port: 51820,
    status: online ? 'ONLINE' : 'OFFLINE',
    online: online,
    connectable: connectable,
    loadPercent: loadPercent,
    activePeers: activePeers,
    capacity: capacity,
    title: country,
    subtitle: 'Frankfurt',
  );
}

void main() {
  group('nodeScore', () {
    test('a fast, idle node beats a slow, busy one', () {
      final fast = nodeScore(node('de-01', loadPercent: 10, activePeers: 5),
          measuredPingMs: 20);
      final slow = nodeScore(node('de-02', loadPercent: 90, activePeers: 95),
          measuredPingMs: 300);

      expect(fast, greaterThan(slow));
    });

    test('ping dominates load, because latency is what users feel', () {
      // 55% ping vs 30% load: a much faster but busier node should still win.
      final fastBusy = nodeScore(
        node('a', loadPercent: 85, activePeers: 85),
        measuredPingMs: 15,
      );
      final slowIdle = nodeScore(
        node('b', loadPercent: 5, activePeers: 5),
        measuredPingMs: 320,
      );

      expect(fastBusy, greaterThan(slowIdle));
    });

    test('a node with no ping measurement is still scoreable', () {
      expect(nodeScore(node('de-01')), isA<double>());
    });

    test('headroom is taken into account', () {
      final roomy = nodeScore(
        node('a', activePeers: 10, capacity: 100),
        measuredPingMs: 50,
      );
      final full = nodeScore(
        node('b', activePeers: 99, capacity: 100),
        measuredPingMs: 50,
      );

      expect(roomy, greaterThan(full));
    });
  });

  group('pickBestNode', () {
    test('picks the lowest-latency healthy node', () {
      final nodes = <VpnNodeInfo>[
        node('de-01'),
        node('nl-02', country: 'Netherlands', countryCode: 'NL'),
        node('kz-01', country: 'Kazakhstan', countryCode: 'KZ'),
      ];

      final choice = pickBestNode(
        nodes,
        pings: <String, int>{'de-01': 120, 'nl-02': 35, 'kz-01': 210},
      );

      expect(choice.node!.name, 'nl-02');
    });

    test('offline nodes are never chosen', () {
      final nodes = <VpnNodeInfo>[
        node('de-01', online: false, loadPercent: 0, activePeers: 0),
        node('nl-02', country: 'Netherlands', countryCode: 'NL'),
      ];

      final choice = pickBestNode(
        nodes,
        pings: <String, int>{'de-01': 5, 'nl-02': 400},
      );

      expect(choice.node!.name, 'nl-02');
    });

    test('nodes marked not connectable are never chosen', () {
      final nodes = <VpnNodeInfo>[
        node('de-01', connectable: false, loadPercent: 0),
        node('nl-02', country: 'Netherlands', countryCode: 'NL'),
      ];

      final choice = pickBestNode(nodes);
      expect(choice.node!.name, 'nl-02');
    });

    test('an empty or fully offline fleet returns an empty choice', () {
      expect(pickBestNode(<VpnNodeInfo>[]).isEmpty, isTrue);
      expect(
        pickBestNode(<VpnNodeInfo>[node('de-01', online: false)]).isEmpty,
        isTrue,
      );
    });

    test('a country preference is honoured when that node is healthy', () {
      final nodes = <VpnNodeInfo>[
        node('de-01'),
        node('kz-01', country: 'Kazakhstan', countryCode: 'KZ'),
      ];

      final choice = pickBestNode(
        nodes,
        pings: <String, int>{'de-01': 40, 'kz-01': 60},
        preferCountryCode: 'KZ',
      );

      expect(choice.node!.countryCode, 'KZ');
    });

    test('a choice always carries a reason for the UI and the logs', () {
      final choice = pickBestNode(<VpnNodeInfo>[node('de-01')]);
      expect(choice.reason, isNotEmpty);
    });
  });

  group('manualSelectionAllowed', () {
    SubscriptionInfo sub(String status, {Duration? remaining}) =>
        SubscriptionInfo(
          status: status,
          expiresAt: remaining == null ? null : DateTime.now().add(remaining),
        );

    test('an active subscription unlocks manual server choice', () {
      expect(
        manualSelectionAllowed(
          sub('ACTIVE', remaining: const Duration(days: 30)),
        ),
        isTrue,
      );
    });

    test('free, expired and missing subscriptions are Auto only', () {
      expect(manualSelectionAllowed(null), isFalse);
      expect(manualSelectionAllowed(sub('EXPIRED')), isFalse);
      expect(manualSelectionAllowed(sub('FREE')), isFalse);
      expect(
        manualSelectionAllowed(
          sub('ACTIVE', remaining: const Duration(days: -1)),
        ),
        isFalse,
        reason: 'ACTIVE with a past expiry is not active',
      );
    });
  });
}
