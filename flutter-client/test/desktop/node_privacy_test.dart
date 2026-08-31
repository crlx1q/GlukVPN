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

  group('selectableNodes never leaves the user stranded', () {
    // The bug this exists to prevent: an account with exactly one node whose
    // handle matched an internal marker got an empty list, a dead Connect
    // button and "no_available_nodes" in the log.
    test('a mixed fleet is still filtered', () {
      final nodes = <VpnNodeInfo>[node('de-01'), node('beta-01')];
      expect(
        selectableNodes(nodes).map((n) => n.name),
        <String>['de-01'],
      );
    });

    test('an internal-only fleet stays usable', () {
      final nodes = <VpnNodeInfo>[node('beta-01')];
      expect(visibleNodes(nodes), isEmpty);
      expect(selectableNodes(nodes).length, 1);
      expect(fleetIsInternalOnly(nodes), isTrue);
    });

    test('an empty fleet stays empty', () {
      expect(selectableNodes(<VpnNodeInfo>[]), isEmpty);
      expect(fleetIsInternalOnly(<VpnNodeInfo>[]), isFalse);
    });

    test('the fallback can be switched off', () {
      final nodes = <VpnNodeInfo>[node('beta-01')];
      expect(selectableNodes(nodes, allowFallback: false), isEmpty);
    });
  });

  group('public labels never expose the handle', () {
    test('an internal node is described by its geography', () {
      final n = node('beta-01', country: 'Germany', countryCode: 'DE');
      expect(publicNodeTitle(n), 'Germany');
      expect(publicNodeSubtitle(n), 'Frankfurt');
      expect(publicNodeTitle(n), isNot(contains('beta')));
    });

    test('a title that is itself internal is discarded', () {
      final n = VpnNodeInfo(
        id: 'beta-01',
        name: 'beta-01',
        country: '',
        countryCode: 'KZ',
        host: 'beta-01.gluk.tech',
        port: 51820,
        status: 'ONLINE',
        online: true,
        connectable: true,
        loadPercent: 10,
        activePeers: 1,
        capacity: 50,
        title: 'beta-01',
        subtitle: 'beta-01',
      );

      expect(publicNodeTitle(n), 'KZ');
      expect(publicNodeSubtitle(n), isNull);
    });

    test('a node with nothing usable falls back to the caller label', () {
      final n = VpnNodeInfo(
        id: 'test-1',
        name: 'test-1',
        country: '',
        countryCode: '',
        host: 'test-1.gluk.tech',
        port: 51820,
        status: 'ONLINE',
        online: true,
        connectable: true,
        loadPercent: 0,
        activePeers: 0,
        capacity: 10,
      );

      expect(publicNodeTitle(n, fallback: 'Auto'), 'Auto');
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
