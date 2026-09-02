/*
 * X25519 / WireGuard key generation for the browser.
 *
 * The private key is generated here, inside the extension, stored in
 * chrome.storage.local and never sent anywhere. Only the public key goes to
 * POST /api/devices/register - exactly the rule the Flutter client follows in
 * lib/services/wg_keys.dart, so the control plane never sees key material it
 * could use to impersonate this device.
 *
 * Implementation: the classic TweetNaCl curve25519 scalar multiplication
 * (public domain), ported to a module. Chrome's WebCrypto only learned X25519
 * in v133, and this extension supports Chrome 108+, so the arithmetic is
 * bundled instead of assumed.
 */

function gf(init) {
	const r = new Float64Array(16)
	if (init) for (let i = 0; i < init.length; i++) r[i] = init[i]
	return r
}

const _121665 = gf([0xdb41, 1])

function car25519(o) {
	let c = 1
	for (let i = 0; i < 16; i++) {
		const v = o[i] + c + 65535
		c = Math.floor(v / 65536)
		o[i] = v - c * 65536
	}
	o[0] += c - 1 + 37 * (c - 1)
}

function sel25519(p, q, b) {
	const c = ~(b - 1)
	for (let i = 0; i < 16; i++) {
		const t = c & (p[i] ^ q[i])
		p[i] ^= t
		q[i] ^= t
	}
}

function pack25519(o, n) {
	const m = gf()
	const t = gf()
	for (let i = 0; i < 16; i++) t[i] = n[i]
	car25519(t)
	car25519(t)
	car25519(t)
	for (let j = 0; j < 2; j++) {
		m[0] = t[0] - 0xffed
		for (let i = 1; i < 15; i++) {
			m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
			m[i - 1] &= 0xffff
		}
		m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
		const b = (m[15] >> 16) & 1
		m[14] &= 0xffff
		sel25519(t, m, 1 - b)
	}
	for (let i = 0; i < 16; i++) {
		o[2 * i] = t[i] & 0xff
		o[2 * i + 1] = t[i] >> 8
	}
}

function unpack25519(o, n) {
	for (let i = 0; i < 16; i++) o[i] = n[2 * i] + (n[2 * i + 1] << 8)
	o[15] &= 0x7fff
}

function A(o, a, b) {
	for (let i = 0; i < 16; i++) o[i] = a[i] + b[i]
}

function Z(o, a, b) {
	for (let i = 0; i < 16; i++) o[i] = a[i] - b[i]
}

function M(o, a, b) {
	const t = new Float64Array(31)
	for (let i = 0; i < 16; i++) {
		for (let j = 0; j < 16; j++) t[i + j] += a[i] * b[j]
	}
	// 2^256 === 38 (mod 2^255 - 19): fold the high limbs back down.
	for (let i = 0; i < 15; i++) t[i] += 38 * t[i + 16]
	for (let i = 0; i < 16; i++) o[i] = t[i]
	car25519(o)
	car25519(o)
}

function S(o, a) {
	M(o, a, a)
}

function inv25519(o, i) {
	const c = gf()
	for (let a = 0; a < 16; a++) c[a] = i[a]
	for (let a = 253; a >= 0; a--) {
		S(c, c)
		if (a !== 2 && a !== 4) M(c, c, i)
	}
	for (let a = 0; a < 16; a++) o[a] = c[a]
}

function scalarMult(n, p) {
	const q = new Uint8Array(32)
	const z = new Uint8Array(32)
	const x = new Float64Array(80)
	const a = gf()
	const b = gf()
	const c = gf()
	const d = gf()
	const e = gf()
	const f = gf()
	for (let i = 0; i < 31; i++) z[i] = n[i]
	z[31] = (n[31] & 127) | 64
	z[0] &= 248
	unpack25519(x, p)
	for (let i = 0; i < 16; i++) {
		b[i] = x[i]
		d[i] = a[i] = c[i] = 0
	}
	a[0] = d[0] = 1
	for (let i = 254; i >= 0; --i) {
		const r = (z[i >>> 3] >>> (i & 7)) & 1
		sel25519(a, b, r)
		sel25519(c, d, r)
		A(e, a, c)
		Z(a, a, c)
		A(c, b, d)
		Z(b, b, d)
		S(d, e)
		S(f, a)
		M(a, c, a)
		M(c, b, e)
		A(e, a, c)
		Z(a, a, c)
		S(b, a)
		Z(c, d, f)
		M(a, c, _121665)
		A(a, a, d)
		M(c, c, a)
		M(a, d, f)
		M(d, b, x)
		S(b, e)
		sel25519(a, b, r)
		sel25519(c, d, r)
	}
	for (let i = 0; i < 16; i++) {
		x[i + 16] = a[i]
		x[i + 32] = c[i]
		x[i + 48] = b[i]
		x[i + 64] = d[i]
	}
	const x32 = x.subarray(32)
	const x16 = x.subarray(16)
	inv25519(x32, x32)
	M(x16, x16, x32)
	pack25519(q, x16)
	return q
}

const BASE_POINT = new Uint8Array(32)
BASE_POINT[0] = 9

export function toBase64(bytes) {
	let s = ''
	for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i])
	return btoa(s)
}

export function fromBase64(value) {
	const raw = atob(value)
	const out = new Uint8Array(raw.length)
	for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i)
	return out
}

/** The scalar clamping `wg genkey` performs. Without it the public key we
 *  register would not match the key we hold, and the peer would never work. */
export function clamp(seed) {
	const k = Uint8Array.from(seed)
	k[0] &= 248
	k[31] &= 127
	k[31] |= 64
	return k
}

export function publicKeyFor(privateKeyBase64) {
	const priv = clamp(fromBase64(privateKeyBase64))
	return toBase64(scalarMult(priv, BASE_POINT))
}

/** Fresh WireGuard key pair, base64 like `wg genkey` / `wg pubkey`. */
export function generateKeyPair() {
	const seed = new Uint8Array(32)
	crypto.getRandomValues(seed)
	const priv = clamp(seed)
	return {
		privateKey: toBase64(priv),
		publicKey: toBase64(scalarMult(priv, BASE_POINT)),
	}
}

export function isValidKey(value) {
	try {
		return fromBase64(value).length === 32
	} catch {
		return false
	}
}
