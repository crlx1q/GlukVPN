import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const String _kRefreshToken = 'refresh_token';
  static const String _kDeviceId = 'device_id';
  static const String _kDeviceName = 'device_name';
  static const String _kWgPrivateKey = 'wg_private_key';
  static const String _kWgPublicKey = 'wg_public_key';
  static const String _kUsername = 'username';

  Future<String?> _read(String key) async {
    final String? value = await _storage.read(key: key);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  // --- session -------------------------------------------------------------

  Future<String?> readRefreshToken() => _read(_kRefreshToken);

  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _kRefreshToken, value: token);

  Future<void> deleteRefreshToken() => _storage.delete(key: _kRefreshToken);

  Future<String?> readUsername() => _read(_kUsername);

  Future<void> writeUsername(String username) =>
      _storage.write(key: _kUsername, value: username);

  // --- device identity -----------------------------------------------------

  Future<String?> readDeviceId() => _read(_kDeviceId);

  Future<DeviceIdentity?> readDeviceIdentity() async {
    final String? id = await _read(_kDeviceId);
    final String? name = await _read(_kDeviceName);
    final String? publicKey = await _read(_kWgPublicKey);
    if (id == null || name == null || publicKey == null) return null;
    return DeviceIdentity(deviceId: id, deviceName: name, publicKeyBase64: publicKey);
  }

  Future<void> writeDeviceId(String deviceId) =>
      _storage.write(key: _kDeviceId, value: deviceId);

  /// Stable, human-readable name shown in the admin panel and in Settings.
  /// Generated once per install; the random suffix keeps two test phones apart.
  Future<String> ensureDeviceName() async {
    final String? existing = await _read(_kDeviceName);
    if (existing != null) return existing;
    final Random random = Random.secure();
    final String suffix = List<String>.generate(
      4,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    final String name = 'android-$suffix';
    await _storage.write(key: _kDeviceName, value: name);
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
    await _storage.write(key: _kWgPrivateKey, value: privateKeyBase64);
    await _storage.write(key: _kWgPublicKey, value: publicKeyBase64);
  }

  /// Drops the key pair and the device id, e.g. after the device was revoked
  /// server-side: the next connect attempt then registers a fresh key pair.
  Future<void> clearDeviceIdentity() async {
    await _storage.delete(key: _kWgPrivateKey);
    await _storage.delete(key: _kWgPublicKey);
    await _storage.delete(key: _kDeviceId);
  }

  /// Full logout: nothing about the previous account stays behind.
  Future<void> wipe() async {
    await _storage.delete(key: _kRefreshToken);
    await _storage.delete(key: _kUsername);
    await clearDeviceIdentity();
    await _storage.delete(key: _kDeviceName);
  }
}
