import { createHmac, randomBytes, timingSafeEqual } from "node:crypto"
import { Algorithm, hash as argon2Hash, verify as argon2Verify } from "@node-rs/argon2"
import { config } from "../config"

// OWASP-recommended Argon2id baseline (19 MiB, t=2, p=1).
const ARGON2_OPTIONS = {
	algorithm: Algorithm.Argon2id,
	memoryCost: 19456,
	timeCost: 2,
	parallelism: 1,
}

/** Cryptographically secure opaque token (URL-safe, no padding). */
export function generateSecret(byteLength = 32): string {
	return randomBytes(byteLength).toString("base64url")
}

/**
 * Keyed hash used to store refresh tokens, node tokens and enrollment tokens.
 * The raw token is never persisted: the DB only holds HMAC-SHA256(pepper, raw).
 */
export function hashSecret(raw: string): string {
	return createHmac("sha256", config.TOKEN_HASH_PEPPER).update(raw, "utf8").digest("hex")
}

/** Constant-time comparison of two hex digests. */
export function safeEqualHex(a: string, b: string): boolean {
	const bufferA = Buffer.from(a, "hex")
	const bufferB = Buffer.from(b, "hex")
	if (bufferA.length === 0 || bufferA.length !== bufferB.length) return false
	return timingSafeEqual(bufferA, bufferB)
}

export async function hashPassword(password: string): Promise<string> {
	return argon2Hash(password, ARGON2_OPTIONS)
}

/** Never throws on malformed hashes — returns false instead. */
export async function verifyPassword(
	storedHash: string,
	password: string,
): Promise<boolean> {
	try {
		return await argon2Verify(storedHash, password)
	} catch {
		return false
	}
}

/** Random human-typable password, used by the seed script only. */
export function generatePassword(byteLength = 18): string {
	return randomBytes(byteLength).toString("base64url")
}
