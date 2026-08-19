import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// A WireGuard key pair, base64-encoded exactly like `wg genkey` / `wg pubkey`.
class WgKeyPair {
  const WgKeyPair({required this.privateKeyBase64, required this.publicKeyBase64});

  final String privateKeyBase64;
  final String publicKeyBase64;

  /// Only the public key is ever safe to print.
  @override
  String toString() => 'WgKeyPair(public: $publicKeyBase64, private: <redacted>)';
}

/// On-device WireGuard key generation.
///
/// This is the whole point of the design: the private key is created here, on
/// the phone, stored in the Android Keystore-backed store, and never sent to the
/// control plane or the node. Only [WgKeyPair.publicKeyBase64] is uploaded.
class WgKeys {
  const WgKeys._();

  static const int keyLength = 32;

  /// Applies the X25519 scalar clamping that `wg genkey` performs.
  ///
  /// This matters for correctness, not just style: wireguard-go clamps the
  /// private key before deriving the public key, so an unclamped key stored on
  /// the device would produce a different public key than the one we registered,
  /// and the handshake would silently never complete.
  static List<int> clampSeed(List<int> seed) {
    if (seed.length != keyLength) {
      throw ArgumentError('WireGuard keys are $keyLength bytes, got ${seed.length}');
    }
    final List<int> clamped = List<int>.of(seed);
    clamped[0] &= 248;
    clamped[31] &= 127;
    clamped[31] |= 64;
    return clamped;
  }

  /// Fresh key pair from a cryptographically secure RNG.
  static Future<WgKeyPair> generate({Random? random}) {
    final Random rng = random ?? Random.secure();
    final List<int> seed = List<int>.generate(keyLength, (_) => rng.nextInt(256));
    return fromSeed(seed);
  }

  /// Deterministic derivation, used by the unit tests.
  static Future<WgKeyPair> fromSeed(List<int> seed) async {
    final List<int> privateKey = clampSeed(seed);
    final SimpleKeyPair keyPair = await X25519().newKeyPairFromSeed(privateKey);
    final SimplePublicKey publicKey = await keyPair.extractPublicKey();
    return WgKeyPair(
      privateKeyBase64: base64.encode(privateKey),
      publicKeyBase64: base64.encode(publicKey.bytes),
    );
  }

  /// Recomputes the public key for a stored private key, so the app can verify
  /// that what it registered still matches what it holds.
  static Future<String> publicKeyFor(String privateKeyBase64) async {
    final List<int> bytes = base64.decode(privateKeyBase64);
    final WgKeyPair pair = await fromSeed(bytes);
    return pair.publicKeyBase64;
  }

  /// True for a syntactically valid WireGuard key (32 bytes, base64).
  static bool isValidKey(String value) {
    try {
      return base64.decode(value).length == keyLength;
    } catch (_) {
      return false;
    }
  }
}
