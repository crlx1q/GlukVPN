import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/platform_target.dart';

/// Local identity of this device.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.deviceName,
    required this.publicKeyBase64,
  });

  final String deviceId;
  final String deviceName;
  final String publicKeyBase64;

  @override
  String toString() => 'DeviceIdentity($deviceName, id: $deviceId)';
}

/// Keystore-backed storage for everything that must survive an app restart but
/// must never leave the phone in plaintext.
///
/// What lives here:
///  * the WireGuard **private** key of this device (never uploaded, never logged)
///  * the refresh token
///  * the device id / device name issued by the control plane
///
/// On Android this is backed by EncryptedSharedPreferences (AES key held in the
/// Android Keystore), so a plain filesystem dump of the app data does not reveal
/// the key material.
///
/// ## Channels
///
/// PROD and BETA are two separate control planes with separate databases, so a
/// PROD refresh token, device id and WireGuard key pair mean nothing on BETA and
/// must never be sent there. Every entry is therefore scoped by [channelId]:
///
///  * `prod` keeps the original, unsuffixed key names, so an app that updates
///    from the pre-channel build stays logged in and keeps its registered
///    device instead of silently registering a second one;
///  * every other channel appends `_<channelId>` (`refresh_token_beta`, ...).
///
/// Switching channels therefore parks the other channel's session instead of
/// destroying it: flipping BETA on and back off returns to the same PROD login.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage, String channelId = 'prod'})
      : _storage = storage ??
            FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
        _channelId = channelId.isEmpty ? 'prod' : channelId;

  final FlutterSecureStorage _storage;

  String _channelId;

  /// Channel the reads and writes below belong to (`prod` or `beta`).
  String get channelId => _channelId;

  /// Repointed by ChannelController before any request is made on the new
  /// channel. Nothing is copied between channels.
  set channelId(String value) {
    _channelId = value.isEmpty ? 'prod' : value;
  }

  static const String _kRefreshToken = 'refresh_token';
  static const String _kDeviceId = 'device_id';
  static const String _kDeviceName = 'device_name';
  static const String _kWgPrivateKey = 'wg_private_key';
  static const String _kWgPublicKey = 'wg_public_key';
  static const String _kUsername = 'username';

  /// The channel pointer itself is deliberately NOT channel-scoped: it is what
  /// decides which scope everything else uses, so it must be readable before a
  /// channel is known.
  static const String _kActiveChannel = 'active_channel';

  /// All base keys, used by the per-channel [wipe].
  static const List<String> _allKeys = <String>[
    _kRefreshToken,
    _kDeviceId,
    _kDeviceName,
    _kWgPrivateKey,
    _kWgPublicKey,
    _kUsername,
  ];

  /// `prod` keeps the legacy names; other channels get a suffix.
  String _key(String base) =>
      _channelId == 'prod' ? base : '${base}_$_channelId';

  Future<String?> _read(String base) async {
    final String? value = await _storage.read(key: _key(base));
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> _write(String base, String value) =>
      _storage.write(key: _key(base), value: value);

  Future<void> _delete(String base) => _storage.delete(key: _key(base));

  // --- channel selection ---------------------------------------------------

  Future<String?> readActiveChannel() async {
    final String? value = await _storage.read(key: _kActiveChannel);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> writeActiveChannel(String channelId) =>
      _storage.write(key: _kActiveChannel, value: channelId);

  // --- session -------------------------------------------------------------

  Future<String?> readRefreshToken() => _read(_kRefreshToken);

  Future<void> writeRefreshToken(String token) =>
      _write(_kRefreshToken, token);

  Future<void> deleteRefreshToken() => _delete(_kRefreshToken);

  Future<String?> readUsername() => _read(_kUsername);

  Future<void> writeUsername(String username) => _write(_kUsername, username);

  // --- device identity -----------------------------------------------------

  Future<String?> readDeviceId() => _read(_kDeviceId);

  Future<DeviceIdentity?> readDeviceIdentity() async {
    final String? id = await _read(_kDeviceId);
    final String? name = await _read(_kDeviceName);
    final String? publicKey = await _read(_kWgPublicKey);
    if (id == null || name == null || publicKey == null) return null;
    return DeviceIdentity(deviceId: id, deviceName: name, publicKeyBase64: publicKey);
  }

  Future<void> writeDeviceId(String deviceId) => _write(_kDeviceId, deviceId);

  /// Stable, human-readable name shown in the admin panel and in Settings.
  /// Generated once per install; the random suffix keeps two test phones apart.
  ///
  /// BETA gets its own name so that one phone testing both channels shows up as
  /// two clearly different devices in the two admin panels.
  Future<String> ensureDeviceName() async {
    final String? existing = await _read(_kDeviceName);
    if (existing != null) return existing;
    final Random random = Random.secure();
    final String suffix = List<String>.generate(
      4,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    // Android and Windows must never collide in the devices list, so the name
    // follows the platform. Android keeps its historical 'android-<hex>' form,
    // which means existing installs are completely unaffected.
    final String name;
    if (currentPlatformTarget == PlatformTarget.windows) {
      // A human label here reads better next to the phone and the browser
      // extension: "Windows · Desktop", "android-4f2a", "Chrome · Windows".
      name = _channelId == 'prod'
          ? 'Windows · Desktop'
          : 'Windows · Desktop (${_channelId.toUpperCase()})';
    } else {
      name = _channelId == 'prod'
          ? 'android-$suffix'
          : 'android-$_channelId-$suffix';
    }
    await _write(_kDeviceName, name);
    return name;
  }

  // --- WireGuard key material ---------------------------------------------

  /// The private key. Callers must only pass it straight into the tunnel config
  /// and never into a log, an API call or an error message.
  Future<String?> readWgPrivateKey() => _read(_kWgPrivateKey);

  Future<String?> readWgPublicKey() => _read(_kWgPublicKey);

  Future<void> writeWgKeyPair({
    required String privateKeyBase64,
    required String publicKeyBase64,
  }) async {
    await _write(_kWgPrivateKey, privateKeyBase64);
    await _write(_kWgPublicKey, publicKeyBase64);
  }

  /// Drops the key pair and the device id, e.g. after the device was revoked
  /// server-side: the next connect attempt then registers a fresh key pair.
  Future<void> clearDeviceIdentity() async {
    await _delete(_kWgPrivateKey);
    await _delete(_kWgPublicKey);
    await _delete(_kDeviceId);
  }

  /// Full logout **for the current channel only**: nothing about the previous
  /// account stays behind, while the other channel's parked session survives.
  Future<void> wipe() async {
    for (final String base in _allKeys) {
      await _delete(base);
    }
  }
}
