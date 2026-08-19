import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/secure_store.dart';
import '../services/wg_keys.dart';

enum AuthStage { unknown, restoring, unauthenticated, authenticated }

/// Owns the account session and this device's WireGuard identity.
///
/// Key invariant: the private key is generated here, stored in [SecureStore],
/// and only its public half is ever handed to [ApiClient.registerDevice].
class AuthController extends ChangeNotifier {
  AuthController({required ApiClient api, required SecureStore store})
      : _api = api,
        _store = store {
    _api.onTokensChanged = _handleTokens;
  }

  final ApiClient _api;
  final SecureStore _store;

  AuthStage _stage = AuthStage.unknown;
  AuthUser? _user;
  SubscriptionInfo? _subscription;
  String? _error;
  bool _busy = false;
  bool _explicitLogout = false;

  String? _deviceId;
  String? _deviceName;
  String? _devicePublicKey;

  ApiClient get api => _api;
  AuthStage get stage => _stage;
  AuthUser? get user => _user;
  SubscriptionInfo? get subscription => _subscription;
  String? get error => _error;
  bool get busy => _busy;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;
  String? get devicePublicKey => _devicePublicKey;
  bool get isAuthenticated => _stage == AuthStage.authenticated;
  bool get subscriptionActive => _subscription?.isActive ?? false;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Persists rotated tokens; a `null` bundle means the server refused to
  /// refresh, which is a terminal session error.
  void _handleTokens(TokenBundle? tokens) {
    if (tokens == null) {
      _store.deleteRefreshToken().ignore();
      if (_stage == AuthStage.authenticated && !_explicitLogout) {
        _user = null;
        _subscription = null;
        _stage = AuthStage.unauthenticated;
        _error = 'Session expired. Please sign in again.';
        notifyListeners();
      }
      return;
    }
    if (tokens.refreshToken.isNotEmpty) {
      _store.writeRefreshToken(tokens.refreshToken).ignore();
    }
    if (tokens.deviceId != null) _deviceId = tokens.deviceId;
  }

  /// Restores a session on app start, if there is one.
  Future<void> bootstrap() async {
    _stage = AuthStage.restoring;
    notifyListeners();

    _deviceName = await _store.ensureDeviceName();
    _deviceId = await _store.readDeviceId();
    _devicePublicKey = await _store.readWgPublicKey();

    final String? refreshToken = await _store.readRefreshToken();
    if (refreshToken == null) {
      _stage = AuthStage.unauthenticated;
      notifyListeners();
      return;
    }

    final bool restored = await _api.restoreSession(refreshToken);
    if (!restored) {
      await _store.deleteRefreshToken();
      _stage = AuthStage.unauthenticated;
      notifyListeners();
      return;
    }

    try {
      await _loadMe();
      await ensureDeviceRegistered();
      _stage = AuthStage.authenticated;
    } on ApiException catch (error) {
      _error = error.message;
      _stage = AuthStage.unauthenticated;
    }
    notifyListeners();
  }

  Future<bool> login({required String username, required String password}) async {
    _error = null;
    _busy = true;
    notifyListeners();
    try {
      final LoginResult result =
          await _api.login(username: username.trim(), password: password);
      _user = result.user;
      _subscription = result.subscription;
      await _store.writeUsername(result.user.username);
      // Upgrades the session to device-scoped tokens, which /api/vpn/connect
      // requires, and registers our public key with the control plane.
      await ensureDeviceRegistered();
      _stage = AuthStage.authenticated;
      return true;
    } on ApiException catch (error) {
      _error = error.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Ensures this install has a WireGuard key pair and a registered device.
  ///
  /// Idempotent: re-registering the same public key returns the existing device
  /// row and simply re-issues device-scoped tokens.
  Future<void> ensureDeviceRegistered({bool forceNewKeys = false}) async {
    final String deviceName = _deviceName ?? await _store.ensureDeviceName();
    _deviceName = deviceName;

    String? privateKey = forceNewKeys ? null : await _store.readWgPrivateKey();
    String? publicKey = forceNewKeys ? null : await _store.readWgPublicKey();

    if (privateKey == null ||
        publicKey == null ||
        !WgKeys.isValidKey(privateKey) ||
        !WgKeys.isValidKey(publicKey)) {
      final WgKeyPair pair = await WgKeys.generate();
      await _store.writeWgKeyPair(
        privateKeyBase64: pair.privateKeyBase64,
        publicKeyBase64: pair.publicKeyBase64,
      );
      publicKey = pair.publicKeyBase64;
    } else {
      // Defensive check: if the stored pair ever disagreed, the node would hold
      // a peer for a key we cannot prove ownership of, and the handshake would
      // fail with no visible reason.
      final String derived = await WgKeys.publicKeyFor(privateKey);
      if (derived != publicKey) {
        final WgKeyPair pair = await WgKeys.generate();
        await _store.writeWgKeyPair(
          privateKeyBase64: pair.privateKeyBase64,
          publicKeyBase64: pair.publicKeyBase64,
        );
        publicKey = pair.publicKeyBase64;
      }
    }

    _devicePublicKey = publicKey;

    try {
      final DeviceRegistration registration = await _api.registerDevice(
        deviceName: deviceName,
        publicKeyBase64: publicKey,
      );
      _deviceId = registration.device.id;
      await _store.writeDeviceId(registration.device.id);
    } on ApiException catch (error) {
      // The key was revoked or belongs to another account: start over once with
      // a brand new pair instead of leaving the app unusable.
      if (!forceNewKeys && (error.isForbidden || error.isConflict)) {
        await _store.clearDeviceIdentity();
        _deviceId = null;
        return ensureDeviceRegistered(forceNewKeys: true);
      }
      rethrow;
    }
  }

  Future<void> refreshMe() async {
    try {
      await _loadMe();
      notifyListeners();
    } on ApiException {
      // Keep the previous snapshot; the UI stays usable.
    }
  }

  Future<void> _loadMe() async {
    final MeResult me = await _api.me();
    _user = me.user;
    _subscription = me.subscription;
    if (me.currentDeviceId != null) _deviceId = me.currentDeviceId;
  }

  Future<DevicesResult> loadDevices() => _api.devices();

  /// Revokes a device. Server-side this also closes its sessions and removes the
  /// WireGuard peer from the node.
  Future<void> revokeDevice(String deviceId) async {
    await _api.revokeDevice(deviceId);
    if (deviceId == _deviceId) {
      await _store.clearDeviceIdentity();
      _deviceId = null;
      _devicePublicKey = null;
    }
    notifyListeners();
  }

  /// Signs out. By default the device registration is revoked too, so the peer
  /// is removed from the node and test devices do not pile up against the
  /// per-user device limit.
  Future<void> logout({bool revokeThisDevice = true}) async {
    _explicitLogout = true;
    _busy = true;
    notifyListeners();
    try {
      final String? id = _deviceId;
      if (revokeThisDevice && id != null) {
        try {
          await _api.revokeDevice(id);
        } on ApiException {
          // Best effort: local logout must still complete.
        }
      }
      await _api.logout();
    } finally {
      await _store.wipe();
      _user = null;
      _subscription = null;
      _deviceId = null;
      _deviceName = null;
      _devicePublicKey = null;
      _error = null;
      _busy = false;
      _explicitLogout = false;
      _stage = AuthStage.unauthenticated;
      notifyListeners();
    }
  }

  /// The private key, read straight from secure storage for the tunnel config.
  /// Callers must not log or transmit it.
  Future<String?> readTunnelPrivateKey() => _store.readWgPrivateKey();
}
