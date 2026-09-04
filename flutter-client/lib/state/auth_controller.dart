import 'package:flutter/foundation.dart';

import '../models/device_limit.dart';
import '../models/models.dart';
import '../platform/platform_target.dart';
import '../services/api_client.dart';
import '../services/connectivity_service.dart';
import '../services/secure_store.dart';
import '../services/wg_keys.dart';

enum AuthStage { unknown, restoring, unauthenticated, authenticated }

/// How a link sign-in ended. Distinct from a plain bool because "the user said
/// no in the browser", "the link ran out" and "the network died" need different
/// words on screen.
enum LinkSignInOutcome { signedIn, denied, expired, cancelled, failed }

/// Owns the account session and this device's WireGuard identity.
///
/// Key invariant: the private key is generated here, stored in [SecureStore],
/// and only its public half is ever handed to [ApiClient.registerDevice].
class AuthController extends ChangeNotifier {
  AuthController({
    required ApiClient api,
    required SecureStore store,
    ConnectivityService? connectivity,
  })  : _api = api,
        _store = store,
        _connectivity = connectivity {
    _api.onTokensChanged = _handleTokens;
  }

  final ApiClient _api;
  final SecureStore _store;
  final ConnectivityService? _connectivity;

  AuthStage _stage = AuthStage.unknown;
  AuthUser? _user;
  SubscriptionInfo? _subscription;
  String? _error;
  bool _busy = false;
  bool _explicitLogout = false;

  String? _deviceId;
  String? _deviceName;
  String? _devicePublicKey;

  /// The session was restored from storage but the control plane has not
  /// confirmed it yet (started with no internet). The user stays signed in and
  /// the UI shows the offline state instead of a login screen.
  bool _unconfirmed = false;

  /// Set when device registration was refused because every slot on the plan
  /// is taken. Kept rather than discarded so the UI can offer the list of
  /// devices to free instead of a dead-end error message.
  DeviceLimitDetails? _deviceLimit;

  ApiClient get api => _api;
  AuthStage get stage => _stage;
  AuthUser? get user => _user;
  SubscriptionInfo? get subscription => _subscription;
  String? get error => _error;
  bool get busy => _busy;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;
  String? get devicePublicKey => _devicePublicKey;

  /// Non-null when the last registration attempt hit the plan's device ceiling.
  DeviceLimitDetails? get deviceLimit => _deviceLimit;

  void clearDeviceLimit() {
    if (_deviceLimit == null) return;
    _deviceLimit = null;
    notifyListeners();
  }
  bool get isAuthenticated => _stage == AuthStage.authenticated;
  bool get subscriptionActive => _subscription?.isActive ?? false;

  /// True while signed in with a session the server has not re-confirmed yet.
  bool get sessionUnconfirmed => _unconfirmed;

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

    final SessionRefreshOutcome outcome = await _api.restoreSession(refreshToken);
    if (outcome == SessionRefreshOutcome.revoked) {
      // The server explicitly refused this token: this is the only case that
      // sends the user back to the login screen.
      await _store.deleteRefreshToken();
      _stage = AuthStage.unauthenticated;
      notifyListeners();
      return;
    }
    if (outcome == SessionRefreshOutcome.offline) {
      // No internet at start-up. Keep the stored token and stay signed in;
      // [resumeSession] finishes the job once the network is back.
      _unconfirmed = true;
      _stage = AuthStage.authenticated;
      _connectivity?.reportNetworkFailure();
      notifyListeners();
      return;
    }

    try {
      await _loadMe();
      await ensureDeviceRegistered();
      _unconfirmed = false;
      _stage = AuthStage.authenticated;
      _connectivity?.reportSuccess();
    } on ApiException catch (error) {
      if (error.isNetwork) {
        // Reachable a second ago, gone now. Still not a reason to log out.
        _unconfirmed = true;
        _stage = AuthStage.authenticated;
        _connectivity?.reportNetworkFailure();
      } else if (error.isUnauthorized || error.isForbidden) {
        _error = error.message;
        _stage = AuthStage.unauthenticated;
      } else {
        // A server-side hiccup: keep the session, show the offline state.
        _unconfirmed = true;
        _stage = AuthStage.authenticated;
      }
    }
    notifyListeners();
  }

  /// Completes a session that was restored while offline, or re-validates one
  /// after the network came back. Safe to call at any time.
  Future<void> resumeSession() async {
    if (_stage != AuthStage.authenticated) return;
    final SessionRefreshOutcome outcome = await _api.resumeSession();
    if (outcome == SessionRefreshOutcome.revoked) {
      await _store.deleteRefreshToken();
      _user = null;
      _subscription = null;
      _unconfirmed = false;
      _stage = AuthStage.unauthenticated;
      _error = 'Your session has ended. Please sign in again.';
      notifyListeners();
      return;
    }
    if (outcome == SessionRefreshOutcome.offline) {
      _unconfirmed = true;
      notifyListeners();
      return;
    }
    try {
      await _loadMe();
      await ensureDeviceRegistered();
      _unconfirmed = false;
      _connectivity?.reportSuccess();
    } on ApiException catch (error) {
      if (error.isUnauthorized || error.isForbidden) {
        _error = error.message;
        _stage = AuthStage.unauthenticated;
      }
      // Anything else: stay signed in, keep showing the offline state.
    }
    notifyListeners();
  }

  /// Signs in with a username **or** an email address.
  Future<bool> login({required String identifier, required String password}) async {
    _error = null;
    _busy = true;
    notifyListeners();
    try {
      final LoginResult result =
          await _api.login(identifier: identifier.trim(), password: password);
      _user = result.user;
      _subscription = result.subscription;
      _unconfirmed = false;
      _connectivity?.reportSuccess();
      await _store.writeUsername(result.user.username);
      // Upgrades the session to device-scoped tokens, which /api/vpn/connect
      // requires, and registers our public key with the control plane.
      await ensureDeviceRegistered();
      _stage = AuthStage.authenticated;
      return true;
    } on ApiException catch (error) {
      if (error.isNetwork) _connectivity?.reportNetworkFailure();
      _error = error.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Signs in by link, so this client never has to own a password field.
  ///
  /// The device-authorization grant, same as GeForce NOW: the server issues a
  /// request, [onStarted] fires so the caller can open the browser and show the
  /// code, and this method polls until the user confirms. The desktop client and
  /// the extension both call it, which is what replaces the three different
  /// improvised sign-in paths with one.
  ///
  /// Cancellation is cooperative through [isCancelled]: a user who changes their
  /// mind must not leave a poll running for the link's full ten minutes.
  Future<LinkSignInOutcome> signInWithLink({
    required String client,
    required void Function(LinkAuthStart start) onStarted,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    _error = null;
    _busy = true;
    notifyListeners();
    try {
      final LinkAuthStart start = await _api.linkStart(
        client: client,
        // Named up front so the confirmation page can say *which* machine is
        // asking. Confirming a request you cannot identify is not consent.
        deviceName: await resolvePhysicalDeviceName(),
      );
      if (!start.isValid) {
        _error = 'The server did not return a sign-in link.';
        return LinkSignInOutcome.failed;
      }
      onStarted(start);

      Duration wait = Duration(seconds: start.intervalSec.clamp(1, 10));
      while (DateTime.now().isBefore(start.expiresAt)) {
        if (cancelled()) return LinkSignInOutcome.cancelled;
        await Future<void>.delayed(wait);
        if (cancelled()) return LinkSignInOutcome.cancelled;

        final LinkAuthPoll poll = await _api.linkPoll(
          requestId: start.requestId,
          pollSecret: start.pollSecret,
        );

        // The server asks for back-pressure rather than punishing the client,
        // so honour it instead of hammering on at the original interval.
        if (poll.status == LinkAuthStatus.slowDown) {
          wait += const Duration(seconds: 1);
          continue;
        }
        if (poll.status == LinkAuthStatus.pending) continue;
        if (poll.status == LinkAuthStatus.denied) {
          _error = 'The sign-in request was declined in the browser.';
          return LinkSignInOutcome.denied;
        }
        if (poll.status != LinkAuthStatus.approved) {
          _error = 'This sign-in link is no longer valid. Please try again.';
          return LinkSignInOutcome.expired;
        }

        final LoginResult? result = poll.result;
        if (result == null) {
          _error = 'The link was approved but no session came back.';
          return LinkSignInOutcome.failed;
        }

        // From here the flow is identical to a password login, deliberately:
        // one code path owns "what it means to become signed in".
        _user = result.user;
        _subscription = result.subscription;
        _unconfirmed = false;
        _connectivity?.reportSuccess();
        await _store.writeUsername(result.user.username);
        await ensureDeviceRegistered();
        _stage = AuthStage.authenticated;
        return LinkSignInOutcome.signedIn;
      }
      _error = 'The sign-in link expired. Please try again.';
      return LinkSignInOutcome.expired;
    } on ApiException catch (error) {
      if (error.isNetwork) _connectivity?.reportNetworkFailure();
      _error = error.message;
      return LinkSignInOutcome.failed;
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
    // ROUND 6: the row in the account's device list should say what this
    // machine is actually called, not "Windows · Desktop" for every PC. The
    // resolver already falls back to the generic label, so this cannot end up
    // empty and block registration.
    final String physical = await resolvePhysicalDeviceName();
    final String deviceName = physical.isNotEmpty
        ? physical
        : (_deviceName ?? await _store.ensureDeviceName());
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
        // Lets the control plane tell an Android phone apart from a Windows
        // PC. registerDevice already defaults to 'android', so the mobile
        // build keeps sending exactly what it sent before.
        platform: devicePlatformTag,
      );
      _deviceId = registration.device.id;
      await _store.writeDeviceId(registration.device.id);
    } on ApiException catch (error) {
      // Running out of device slots is a 409, but it is not a key problem and
      // regenerating the pair cannot cure it: the retry is refused for exactly
      // the same reason, and the install has meanwhile thrown away the identity
      // the node holds a peer for. Record the device list and stop instead.
      if (error.isDeviceLimit) {
        _deviceLimit = DeviceLimitDetails.fromJson(error.details);
        notifyListeners();
        rethrow;
      }
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
      _unconfirmed = false;
      _connectivity?.reportSuccess();
      notifyListeners();
    } on ApiException catch (error) {
      // Keep the previous snapshot; the UI stays usable and signed in.
      if (error.isNetwork) {
        _unconfirmed = true;
        _connectivity?.reportNetworkFailure();
        notifyListeners();
      }
    }
  }

  /// Starts an email change. The address only moves once the code is confirmed.
  Future<DateTime?> requestEmailChange(String email) =>
      _api.requestEmailChange(email.trim());

  Future<void> confirmEmailChange(String code) async {
    final AuthUser updated = await _api.confirmEmailChange(code.trim());
    final AuthUser? current = _user;
    _user = current == null
        ? updated
        : current.copyWith(email: updated.email, emailVerified: true);
    notifyListeners();
  }

  Future<void> _loadMe() async {
    final MeResult me = await _api.me();
    _user = me.user;
    _subscription = me.subscription;
    if (me.currentDeviceId != null) _deviceId = me.currentDeviceId;
  }

  Future<DevicesResult> loadDevices() => _api.devices();

  /// Frees one device slot and registers this install into it.
  ///
  /// Backs the device-limit dialog: revoking the chosen device closes its
  /// sessions and drops its peer server-side, and only then is registration
  /// retried. The limit state is cleared last, so a failure anywhere leaves the
  /// dialog on screen instead of silently doing nothing.
  Future<void> freeDeviceSlot(String deviceId) async {
    await revokeDevice(deviceId);
    await ensureDeviceRegistered();
    _deviceLimit = null;
    notifyListeners();
  }

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
