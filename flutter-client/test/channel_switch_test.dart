import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/config.dart';
import 'package:glukvpn/models/models.dart';
import 'package:glukvpn/services/api_client.dart';
import 'package:glukvpn/services/secure_store.dart';
import 'package:glukvpn/state/channel_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The decision logic behind the PROD/BETA card: a switch is only made after
/// the target control plane has answered, in both directions, and a refused
/// switch leaves the active channel and its session exactly as they were.
///
/// Everything network-shaped is injected - the availability probe as a
/// function, `GET /api/version` through a mock HTTP client, and the secure
/// storage plugin through a mocked method channel - so the test runs offline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel storageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final Map<String, String> storage = <String, String>{};

  setUp(() {
    storage.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (MethodCall call) async {
      final Map<Object?, Object?> args =
          (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      final String key = args['key'] as String? ?? '';
      switch (call.method) {
        case 'read':
          return storage[key];
        case 'write':
          storage[key] = args['value'] as String? ?? '';
          return null;
        case 'delete':
          storage.remove(key);
          return null;
        case 'containsKey':
          return storage.containsKey(key);
        case 'readAll':
          return Map<String, String>.of(storage);
        case 'deleteAll':
          storage.clear();
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
  });

  ChannelVersion version(String channel, String number) =>
      ChannelVersion.fromJson(<String, dynamic>{
        'channel': channel,
        'version': number,
      });

  /// An API client whose only route is `GET /api/version`, so the unprobed
  /// [ChannelController.switchTo] path can complete offline as well.
  ApiClient offlineApi() => ApiClient(
        httpClient: MockClient((http.Request request) async {
          if (request.url.path == '/api/version') {
            final bool beta = request.url.host.startsWith('beta');
            return http.Response(
              jsonEncode(<String, dynamic>{
                'channel': beta ? 'beta' : 'prod',
                'version': beta ? '1.3.0' : '1.2.0',
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{"error":"not found"}', 404);
        }),
      );

  AuthUser user({bool admin = false, bool tester = false}) => AuthUser(
        id: 'u1',
        username: 'someone',
        status: 'ACTIVE',
        isAdmin: admin,
        isTester: tester,
        maxDevices: 3,
        maxConcurrentSessions: 1,
      );

  group('ChannelController.trySwitch', () {
    test('does not switch when the target does not answer', () async {
      final List<String> probed = <String>[];
      int bootstraps = 0;
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        onChannelChanged: (_) async => bootstraps++,
        probeChannel: (String url) async {
          probed.add(url);
          return null;
        },
      );

      final ChannelSwitchResult result =
          await channel.trySwitch(AppChannel.beta);

      expect(result, ChannelSwitchResult.targetUnavailable);
      expect(probed, <String>[AppConfig.baseUrlFor(AppChannel.beta)]);
      expect(channel.active, AppChannel.prod, reason: 'nothing moved');
      expect(bootstraps, 0, reason: 'the session was never rebuilt');
      expect(channel.unavailableChannel, AppChannel.beta);
      expect(channel.lastSwitchResult, ChannelSwitchResult.targetUnavailable);
      expect(channel.isReachable(AppChannel.beta), isFalse);
      expect(channel.pendingTarget, isNull);
      expect(channel.switching, isFalse);
      expect(storage, isEmpty, reason: 'the stored channel is untouched');
    });

    test('switches once the target answers, and keeps its version', () async {
      int bootstraps = 0;
      AppChannel? announced;
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        onChannelChanged: (AppChannel next) async {
          bootstraps++;
          announced = next;
        },
        probeChannel: (_) async => version('beta', '1.3.0'),
      );

      final ChannelSwitchResult result =
          await channel.trySwitch(AppChannel.beta);

      expect(result, ChannelSwitchResult.switched);
      expect(channel.active, AppChannel.beta);
      expect(channel.isBeta, isTrue);
      expect(bootstraps, 1);
      expect(announced, AppChannel.beta);
      expect(channel.versionOf(AppChannel.beta)?.version, '1.3.0');
      expect(channel.isReachable(AppChannel.beta), isTrue);
      expect(channel.unavailableChannel, isNull);
      expect(channel.lastSwitchResult, ChannelSwitchResult.switched);
      expect(channel.baseUrl, AppConfig.baseUrlFor(AppChannel.beta));
    });

    test('probes in both directions: PROD is checked before going back',
        () async {
      final List<String> probed = <String>[];
      bool prodUp = false;
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        probeChannel: (String url) async {
          probed.add(url);
          if (url == AppConfig.baseUrlFor(AppChannel.beta)) {
            return version('beta', '1.3.0');
          }
          return prodUp ? version('prod', '1.2.0') : null;
        },
      );
      await channel.trySwitch(AppChannel.beta);
      expect(channel.active, AppChannel.beta);

      final ChannelSwitchResult refused =
          await channel.trySwitch(AppChannel.prod);
      expect(refused, ChannelSwitchResult.targetUnavailable);
      expect(channel.active, AppChannel.beta, reason: 'stays on beta');
      expect(channel.unavailableChannel, AppChannel.prod);
      expect(probed.last, AppConfig.baseUrlFor(AppChannel.prod));

      prodUp = true;
      final ChannelSwitchResult accepted =
          await channel.trySwitch(AppChannel.prod);
      expect(accepted, ChannelSwitchResult.switched);
      expect(channel.active, AppChannel.prod);
      expect(channel.unavailableChannel, isNull);
    });

    test('the active channel is a no-op and is not probed', () async {
      int probes = 0;
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        probeChannel: (_) async {
          probes++;
          return version('prod', '1.2.0');
        },
      );

      expect(await channel.trySwitch(AppChannel.prod),
          ChannelSwitchResult.alreadyActive);
      expect(probes, 0);
      expect(channel.lastSwitchResult, isNull);
    });

    test('a second tap while the probe is out reports busy', () async {
      final Completer<ChannelVersion?> gate = Completer<ChannelVersion?>();
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        probeChannel: (_) => gate.future,
      );

      final Future<ChannelSwitchResult> first =
          channel.trySwitch(AppChannel.beta);
      expect(channel.pendingTarget, AppChannel.beta);
      expect(channel.switching, isTrue);

      expect(await channel.trySwitch(AppChannel.beta), ChannelSwitchResult.busy);

      gate.complete(version('beta', '1.3.0'));
      expect(await first, ChannelSwitchResult.switched);
      expect(channel.pendingTarget, isNull);
      expect(channel.switching, isFalse);
    });

    test('clearError forgets the outcome of the last attempt', () async {
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        probeChannel: (_) async => null,
      );
      await channel.trySwitch(AppChannel.beta);
      expect(channel.unavailableChannel, AppChannel.beta);

      channel.clearError();
      expect(channel.unavailableChannel, isNull);
      expect(channel.lastSwitchResult, isNull);
    });

    test('setBetaEnabled goes through the same availability check', () async {
      final ChannelController channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        probeChannel: (_) async => null,
      );
      expect(await channel.setBetaEnabled(true), isFalse);
      expect(channel.active, AppChannel.prod);
    });
  });

  group('ChannelController entitlement', () {
    late ChannelController channel;

    setUp(() {
      channel = ChannelController(
        api: offlineApi(),
        store: SecureStore(),
        probeChannel: (_) async => version('beta', '1.3.0'),
      );
    });

    test('the card is for admins and testers, not for everybody', () {
      // Internal builds see the card regardless; the test suite is not one.
      expect(AppConfig.internalBuild, isFalse);
      expect(channel.canSwitch, isTrue);
      expect(channel.canSwitchFor(user(admin: true)), isTrue);
      expect(channel.canSwitchFor(user(tester: true)), isTrue);
      expect(channel.canSwitchFor(user()), isFalse);
      expect(channel.canSwitchFor(null), isFalse);
      // The old name still answers, with the new rule.
      // ignore: deprecated_member_use_from_same_package
      expect(channel.canSwitchAs(user(tester: true)), isTrue);
    });

    test('a tester is not demoted from beta at start-up', () async {
      await channel.trySwitch(AppChannel.beta);
      await channel.demoteIfNotEntitled(user(tester: true));
      expect(channel.active, AppChannel.beta);
    });

    test('a plain account is moved back to PROD', () async {
      await channel.trySwitch(AppChannel.beta);
      await channel.demoteIfNotEntitled(user());
      expect(channel.active, AppChannel.prod);
    });

    test('signed out keeps a channel chosen by hand in this run', () async {
      await channel.trySwitch(AppChannel.beta);
      await channel.demoteIfNotEntitled(null);
      expect(channel.active, AppChannel.beta,
          reason: 'the sign-in screen must stay pointed at beta');
    });
  });
}
