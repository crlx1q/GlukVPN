// Settings must survive a restart exactly as the user left them, and a
// corrupted or half-written file must never prevent the app from starting.

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/desktop/state/desktop_settings.dart';
import 'package:glukvpn/platform/tunnel_backend.dart';

void main() {
  group('defaults', () {
    test('are safe for a first launch', () {
      const d = DesktopSettings.defaults;

      expect(d.startWithWindows, isFalse);
      expect(d.startMinimized, isFalse);
      expect(d.autoConnect, isFalse);
      expect(d.killSwitch, isFalse);
      expect(d.splitMode, SplitMode.allApps);
      expect(d.splitApps, isEmpty);
      expect(d.animationsEnabled, isTrue);
      expect(d.reduceMotion, isFalse);
      expect(d.language, 'system');
    });

    test('the VPN outlives the window, and Exit tears it down', () {
      // Requirement 11: closing the window must not disconnect, but Exit must.
      expect(DesktopSettings.defaults.keepTunnelWithoutUi, isTrue);
      expect(DesktopSettings.defaults.disconnectOnExit, isTrue);
    });
  });

  group('JSON round trip', () {
    test('a fully populated settings object survives intact', () {
      final original = DesktopSettings.defaults.copyWith(
        startWithWindows: true,
        startMinimized: true,
        language: 'ru',
        animationsEnabled: false,
        reduceMotion: true,
        autoConnect: true,
        killSwitch: true,
        dns: <String>['1.1.1.1', '9.9.9.9'],
        mtu: 1380,
        splitMode: SplitMode.excludeSelected,
        splitApps: <String>[r'C:\Apps\Telegram.exe', r'C:\Apps\Discord.exe'],
        keepTunnelWithoutUi: false,
        disconnectOnExit: false,
        windowWidth: 1280,
        windowHeight: 800,
        windowX: 120,
        windowY: 64,
        lastNodeId: 'de-01',
        autoNodeSelection: false,
      );

      final restored = DesktopSettings.fromJson(original.toJson());

      expect(restored.startWithWindows, isTrue);
      expect(restored.startMinimized, isTrue);
      expect(restored.language, 'ru');
      expect(restored.animationsEnabled, isFalse);
      expect(restored.reduceMotion, isTrue);
      expect(restored.autoConnect, isTrue);
      expect(restored.killSwitch, isTrue);
      expect(restored.dns, <String>['1.1.1.1', '9.9.9.9']);
      expect(restored.mtu, 1380);
      expect(restored.splitMode, SplitMode.excludeSelected);
      expect(restored.splitApps.length, 2);
      expect(restored.keepTunnelWithoutUi, isFalse);
      expect(restored.disconnectOnExit, isFalse);
      expect(restored.windowWidth, 1280);
      expect(restored.windowHeight, 800);
      expect(restored.windowX, 120);
      expect(restored.windowY, 64);
      expect(restored.lastNodeId, 'de-01');
      expect(restored.autoNodeSelection, isFalse);
    });

    test('the payload is versioned so future migrations are possible', () {
      expect(
        DesktopSettings.defaults.toJson()['version'],
        DesktopSettings.schemaVersion,
      );
    });

    test('advanced fields round trip', () {
      final original = DesktopSettings.defaults.copyWith(
        bypassRoutes: <String>['10.0.0.0/8', 'intranet.local'],
        pauseAnimationsOnBattery: false,
      );
      final restored = DesktopSettings.fromJson(original.toJson());

      expect(restored.bypassRoutes, <String>['10.0.0.0/8', 'intranet.local']);
      expect(restored.pauseAnimationsOnBattery, isFalse);
    });

    test('every split mode round trips', () {
      for (final mode in SplitMode.values) {
        final restored = DesktopSettings.fromJson(
          DesktopSettings.defaults.copyWith(splitMode: mode).toJson(),
        );
        expect(restored.splitMode, mode, reason: mode.name);
      }
    });
  });

  group('geometry migration', () {
    test('a version 1 file forgets its window rectangle exactly once', () {
      // The window was reshaped to something much closer to square; keeping a
      // stored 1165x739 would leave the new layout cramped for ever.
      final legacy = DesktopSettings.fromJson(<String, dynamic>{
        'version': 1,
        'windowWidth': 1165.0,
        'windowHeight': 739.0,
        'windowX': 40.0,
        'windowY': 20.0,
        'killSwitch': true,
      });

      expect(legacy.windowWidth, isNull);
      expect(legacy.windowHeight, isNull);
      expect(legacy.windowX, isNull);
      expect(legacy.windowY, isNull);
      // Everything else must survive the migration untouched.
      expect(legacy.killSwitch, isTrue);
    });

    test('a current file keeps its geometry', () {
      final current = DesktopSettings.fromJson(<String, dynamic>{
        'version': DesktopSettings.schemaVersion,
        'windowWidth': 1200.0,
        'windowHeight': 980.0,
      });

      expect(current.windowWidth, 1200);
      expect(current.windowHeight, 980);
    });
  });

  group('hostile input', () {
    test('an empty object falls back to the defaults', () {
      final restored = DesktopSettings.fromJson(<String, dynamic>{});
      expect(restored.splitMode, SplitMode.allApps);
      expect(restored.language, 'system');
      expect(restored.killSwitch, isFalse);
    });

    test('wrong types do not throw', () {
      final restored = DesktopSettings.fromJson(<String, dynamic>{
        'killSwitch': 'yes',
        'mtu': 'huge',
        'dns': 'not-a-list',
        'splitMode': 'nonsense',
        'windowWidth': <String>['bad'],
      });

      expect(restored.splitMode, SplitMode.allApps);
      expect(restored.dns, isEmpty);
    });
  });

  group('MTU clamping', () {
    test('stays inside the range WireGuard can actually use', () {
      expect(DesktopSettings.clampMtu(1000), 1280);
      expect(DesktopSettings.clampMtu(1280), 1280);
      expect(DesktopSettings.clampMtu(1420), 1420);
      expect(DesktopSettings.clampMtu(1500), 1500);
      expect(DesktopSettings.clampMtu(9000), 1500);
    });
  });

  group('copyWith', () {
    test('leaves untouched fields alone', () {
      final changed =
          DesktopSettings.defaults.copyWith(killSwitch: true, language: 'en');

      expect(changed.killSwitch, isTrue);
      expect(changed.language, 'en');
      expect(changed.splitMode, DesktopSettings.defaults.splitMode);
      expect(changed.autoConnect, DesktopSettings.defaults.autoConnect);
    });

    test('nullable fields need an explicit clear flag', () {
      final withMtu =
          DesktopSettings.defaults.copyWith(mtu: 1400, lastNodeId: 'de-01');
      expect(withMtu.mtu, 1400);
      expect(withMtu.lastNodeId, 'de-01');

      // Passing null must not clear, otherwise every copyWith would wipe them.
      expect(withMtu.copyWith(killSwitch: true).mtu, 1400);

      expect(withMtu.copyWith(clearMtu: true).mtu, isNull);
      expect(withMtu.copyWith(clearLastNodeId: true).lastNodeId, isNull);
    });
  });
}
