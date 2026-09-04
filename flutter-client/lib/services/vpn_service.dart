import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import '../config.dart';
import '../models/models.dart';

/// Tunnel lifecycle as this app models it.
///
/// Deliberately our own enum: the plugin's stage values are mapped by *name*
/// (see [VpnService.parseStage]), so a rename or reordering inside the plugin
/// cannot break compilation here.
enum TunnelStage {
  unknown,
  preparing,
  connecting,
  connected,
  disconnecting,
  disconnected,
  denied,
  error,
}

extension TunnelStageX on TunnelStage {
  bool get isConnected => this == TunnelStage.connected;
  bool get isBusy =>
      this == TunnelStage.preparing ||
      this == TunnelStage.connecting ||
      this == TunnelStage.disconnecting;
}

/// Wrapper around the platform WireGuard tunnel.
///
/// The tunnel itself is created by Android's own `VpnService` (the plugin embeds
/// the wireguard-go backend), which is exactly why the system VPN permission
/// dialog appears on the first connect. There is no HTTP proxy anywhere in this
/// app, and nothing here tries to hide the VPN from the user or the system.
class VpnService {
  VpnService({WireGuardFlutterInterface? backend})
      : _backend = backend ?? WireGuardFlutter.instance;

  final WireGuardFlutterInterface _backend;

  final StreamController<TunnelStage> _stages =
      StreamController<TunnelStage>.broadcast();

  StreamSubscription<Object?>? _stageSubscription;
  bool _initialized = false;

  /// Stage updates pushed by the platform side.
  Stream<TunnelStage> get stages => _stages.stream;

  /// Prepares the tunnel interface. Safe to call repeatedly.
  Future<void> initialize() async {
    if (_initialized) return;
    await _backend.initialize(interfaceName: AppConfig.tunnelInterfaceName);
    _initialized = true;

    // The plugin exposes a typed stage stream; accepting `Object?` keeps this
    // file independent of the plugin's enum type.
    _stageSubscription ??= _backend.vpnStageSnapshot.listen(
      (Object? event) {
        if (!_stages.isClosed) _stages.add(parseStage(event));
      },
      onError: (Object _) {
        if (!_stages.isClosed) _stages.add(TunnelStage.error);
      },
    );
  }

  static const MethodChannel _wgControl =
      MethodChannel('billion.group.wireguard_flutter/wgcontrol');

  /// Synchronizes permission state with wireguard_flutter backend so its internal
  /// havePermission flag is set to true before starting a connection.
  Future<void> syncPermissions() async {
    try {
      await _wgControl.invokeMethod<void>('checkPermission');
    } catch (error) {
      debugPrint('vpn: syncPermissions failed: $error');
    }
  }

  /// Brings the tunnel up.
  ///
  /// [privateKeyBase64] is read from secure storage by the caller and used only
  /// to build the in-memory wg-quick config. It is never logged and never sent
  /// anywhere over the network.
  Future<void> start({
    required TunnelConfig tunnel,
    required String privateKeyBase64,
  }) async {
    await initialize();
    final String config = tunnel.toWgQuickConfig(privateKeyBase64: privateKeyBase64);
    await _backend.startVpn(
      serverAddress: tunnel.endpoint,
      wgQuickConfig: config,
      providerBundleIdentifier: AppConfig.appId,
    );
  }

  /// Tears the tunnel down. Never throws: a failed local teardown must not block
  /// the server-side disconnect.
  Future<void> stop() async {
    if (!_initialized) return;
    try {
      await _backend.stopVpn();
    } catch (error) {
      debugPrint('vpn: stopVpn failed: $error');
    }
  }

  /// Current stage according to the platform, used on app resume to re-sync the
  /// UI with a tunnel that may still be running from a previous app session.
  Future<TunnelStage> currentStage() async {
    if (!_initialized) return TunnelStage.disconnected;
    try {
      return parseStage(await _backend.stage());
    } catch (_) {
      return TunnelStage.unknown;
    }
  }

  Future<void> dispose() async {
    await _stageSubscription?.cancel();
    _stageSubscription = null;
    await _stages.close();
  }

  /// Maps a platform stage value onto [TunnelStage] by name.
  @visibleForTesting
  static TunnelStage parseStage(Object? raw) {
    if (raw == null) return TunnelStage.unknown;
    final String name = raw.toString().split('.').last.trim().toLowerCase();
    switch (name) {
      case 'connected':
        return TunnelStage.connected;
      case 'connecting':
      case 'authenticating':
      case 'reconnect':
      case 'waitingconnection':
        return TunnelStage.connecting;
      case 'preparing':
        return TunnelStage.preparing;
      case 'disconnecting':
      case 'exiting':
        return TunnelStage.disconnecting;
      case 'disconnected':
      case 'noconnection':
        return TunnelStage.disconnected;
      case 'denied':
        return TunnelStage.denied;
      default:
        return TunnelStage.unknown;
    }
  }
}
