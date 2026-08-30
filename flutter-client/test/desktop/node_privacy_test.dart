// Requirement 8: internal node identifiers must never reach a normal user.
//
// "beta-01", "test-01" and friends exist in the fleet. A paying customer must
// never see them in the server list, and Auto must never pick one.

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/desktop/logic/node_selector.dart';
import 'package:glukvpn/models/models.dart';

VpnNodeInfo node(
  String name, {
  String? id,
  String country = 'Germany',
  String countryCode = 'DE',
  bool online = true,
  bool connectable = true,
  int loadPercent = 20,
  int activePeers = 10,
  int capacity = 100,
}) {
  return VpnNodeInfo(
    id: id ?? name,
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
    city: 'Frankfurt',
    title: country,
    subtitle: 'Frankfurt',
  );
}

void main() {
  group('isInternalNode', () {
    test('flags every internal marker', () {
      const internal = <String>[
        'beta-01',
        'test-01',
        'staging-fra',
        'stage-2',
        'dev-node',
        'internal-01',
        'canary-de',
        'lab-1',
        'tmp-node',
      ];
      for (final name in internal) {
        expect(isInternalNode(node(name)), isTrue, reason: name);
      }
    });

    test('leaves production nodes alone', () {
      const production = <String>[
        'de-01',
        'nl-02',
        'kz-01',
        'fra-1',
        'us-east-1',
      ];
      for (final name in production) {
        expect(isInternalNode(node(name)), isFalse, reason: name);
      }
    });

    test('markers must be whole words, not substrings', () {
      // "betamax-01" is not a beta node, and "contest-1" is not a test node.
      // A naive `contains` check would hide both from paying users.
      expect(isInternalNode(node('betamax-01')), isFalse);
      expect(isInternalNode(node('contest-1')), isFalse);
      expect(isInternalNode(node('greatest-1')), isFalse);
      expect(isInternalNode(node('development')), isFalse);
    });

    test('matching is case insensitive', () {
      expect(isInternalNode(node('BETA-01')), isTrue);
      expect(isInternalNode(node('Test-02')), isTrue);
    });
  });

  group('visibleNodes', () {
    final nodes = <VpnNodeInfo>[
      node('de-01'),
      node('beta-01'),
      node('nl-02', country: 'Netherlands', countryCode: 'NL'),
      node('test-01'),
      node('kz-01', country: 'Kazakhstan', countryCode: 'KZ'),
    ];

    test('a public build sees only production nodes', () {
      final visible = visibleNodes(nodes);
      expect(visible.map((n) => n.name), <String>['de-01', 'nl-02', 'kz-01']);
    });

    test('an internal build sees everything', () {
      final visible = visibleNodes(nodes, internalBuild: true);
      expect(visible.length, nodes.length);
    });

    test('an empty fleet does not throw', () {
      expect(visibleNodes(<VpnNodeInfo>[]), isEmpty);
    });
  });

  group('Auto never leaks an internal node', () {
    test('even when the internal node is by far the best', () {
      final nodes = <VpnNodeInfo>[
        // Deliberately perfect: idle, empty, and the lowest ping below.
        node('beta-01', loadPercent: 0, activePeers: 0),
        node('de-01', loadPercent: 80, activePeers: 90),
      ];

      final choice = pickBestNode(
        nodes,
        pings: <String, int>{'beta-01': 5, 'de-01': 250},
      );

      expect(choice.isEmpty, isFalse);
      expect(choice.node!.name, 'de-01');
    });

    test('an internal-only fleet yields no choice for a public build', () {
      final choice = pickBestNode(<VpnNodeInfo>[node('beta-01')]);
      expect(choice.isEmpty, isTrue);
    });
  });

  group('display fields never expose the handle', () {
    test('title and subtitle come from the backend, not the node name', () {
      final n = node('de-01');
      expect(n.displayTitle, isNot(contains('de-01')));
      expect(n.displaySubtitle, isNot(contains('de-01')));
    });
  });
}
