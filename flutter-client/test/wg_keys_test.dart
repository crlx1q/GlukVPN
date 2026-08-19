import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/services/wg_keys.dart';

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('clampSeed', () {
    test('applies the X25519 scalar clamping wg genkey performs', () {
      final List<int> clamped = WgKeys.clampSeed(List<int>.filled(32, 0xFF));
      expect(clamped[0], 0xF8, reason: 'low three bits must be cleared');
      expect(clamped[31], 0x7F, reason: 'top bit cleared, bit 254 set');
    });

    test('sets bit 254 even on an all-zero seed', () {
      final List<int> clamped = WgKeys.clampSeed(List<int>.filled(32, 0x00));
      expect(clamped[0], 0x00);
      expect(clamped[31], 0x40);
    });

    test('is idempotent', () {
      final List<int> once = WgKeys.clampSeed(List<int>.generate(32, (int i) => i * 7 % 256));
      final List<int> twice = WgKeys.clampSeed(once);
      expect(twice, once);
    });

    test('rejects keys that are not 32 bytes', () {
      expect(() => WgKeys.clampSeed(List<int>.filled(31, 0)), throwsArgumentError);
      expect(() => WgKeys.clampSeed(List<int>.filled(33, 0)), throwsArgumentError);
    });
  });

  group('key derivation', () {
    // RFC 7748 section 6.1 test vector. If the derivation or the clamping ever
    // drifts, the node would install a peer for a public key the phone cannot
    // prove ownership of and the handshake would silently never complete.
    const List<int> rfcSeed = <int>[
      0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, //
      0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
      0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
      0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
    ];
    const String rfcPublicHex =
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a';

    test('matches the RFC 7748 public key', () async {
      final WgKeyPair pair = await WgKeys.fromSeed(rfcSeed);
      expect(_hex(base64.decode(pair.publicKeyBase64)), rfcPublicHex);
    });

    test('stores the clamped private key, not the raw seed', () async {
      final WgKeyPair pair = await WgKeys.fromSeed(rfcSeed);
      final List<int> stored = base64.decode(pair.privateKeyBase64);
      expect(stored, WgKeys.clampSeed(rfcSeed));
      expect(stored.length, 32);
    });

    test('publicKeyFor recomputes the same public key', () async {
      final WgKeyPair pair = await WgKeys.generate();
      expect(await WgKeys.publicKeyFor(pair.privateKeyBase64), pair.publicKeyBase64);
    });

    test('generate produces distinct, valid keys', () async {
      final WgKeyPair a = await WgKeys.generate();
      final WgKeyPair b = await WgKeys.generate();
      expect(a.privateKeyBase64, isNot(b.privateKeyBase64));
      expect(a.publicKeyBase64, isNot(b.publicKeyBase64));
      expect(WgKeys.isValidKey(a.publicKeyBase64), isTrue);
      expect(WgKeys.isValidKey(a.privateKeyBase64), isTrue);
      expect(base64.decode(a.publicKeyBase64).length, 32);
    });

    test('never leaks the private key through toString', () async {
      final WgKeyPair pair = await WgKeys.generate();
      expect(pair.toString(), contains(pair.publicKeyBase64));
      expect(pair.toString(), isNot(contains(pair.privateKeyBase64)));
      expect(pair.toString(), contains('redacted'));
    });
  });

  group('isValidKey', () {
    test('rejects wrong lengths and non-base64 input', () {
      expect(WgKeys.isValidKey(''), isFalse);
      expect(WgKeys.isValidKey('not-a-key'), isFalse);
      expect(WgKeys.isValidKey(base64.encode(List<int>.filled(16, 1))), isFalse);
      expect(WgKeys.isValidKey(base64.encode(List<int>.filled(32, 1))), isTrue);
    });
  });
}
