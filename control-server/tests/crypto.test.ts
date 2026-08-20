import { describe, expect, it } from "vitest"
import {
	generatePassword,
	generateSecret,
	hashPassword,
	hashSecret,
	safeEqualHex,
	verifyPassword,
} from "../src/lib/crypto"

describe("password hashing (Argon2id)", () => {
	it("produces an Argon2id hash that never contains the password", async () => {
		const password = "correct horse battery staple"
		const hash = await hashPassword(password)
		expect(hash.startsWith("$argon2id$")).toBe(true)
		expect(hash).not.toContain(password)
	})

	it("verifies the right password and rejects the wrong one", async () => {
		const hash = await hashPassword("s3cret-passphrase")
		await expect(verifyPassword(hash, "s3cret-passphrase")).resolves.toBe(true)
		await expect(verifyPassword(hash, "s3cret-passphras")).resolves.toBe(false)
		await expect(verifyPassword(hash, "")).resolves.toBe(false)
	})

	it("salts every hash, so the same password hashes differently", async () => {
		const [a, b] = await Promise.all([
			hashPassword("same-password"),
			hashPassword("same-password"),
		])
		expect(a).not.toBe(b)
		await expect(verifyPassword(a, "same-password")).resolves.toBe(true)
		await expect(verifyPassword(b, "same-password")).resolves.toBe(true)
	})

	it("returns false instead of throwing on a malformed stored hash", async () => {
		await expect(verifyPassword("not-a-hash", "whatever")).resolves.toBe(false)
		await expect(verifyPassword("", "whatever")).resolves.toBe(false)
	})
})

describe("token hashing", () => {
	it("is deterministic and returns a 32-byte hex digest", () => {
		const raw = generateSecret()
		const digest = hashSecret(raw)
		expect(digest).toMatch(/^[0-9a-f]{64}$/)
		expect(hashSecret(raw)).toBe(digest)
	})

	it("never reveals the raw token and changes with the input", () => {
		const raw = generateSecret()
		const digest = hashSecret(raw)
		expect(digest).not.toContain(raw)
		expect(hashSecret(`${raw}x`)).not.toBe(digest)
	})
})

describe("safeEqualHex", () => {
	it("compares equal digests", () => {
		const digest = hashSecret("token-a")
		expect(safeEqualHex(digest, digest)).toBe(true)
	})

	it("rejects different, empty and mismatched-length values", () => {
		expect(safeEqualHex(hashSecret("token-a"), hashSecret("token-b"))).toBe(false)
		expect(safeEqualHex("", "")).toBe(false)
		expect(safeEqualHex(hashSecret("token-a"), "ab")).toBe(false)
		expect(safeEqualHex("ab", hashSecret("token-a"))).toBe(false)
	})
})

describe("secret generation", () => {
	it("emits URL-safe, unique, high-entropy tokens", () => {
		const tokens = new Set<string>()
		for (let i = 0; i < 50; i += 1) {
			const token = generateSecret()
			expect(token).toMatch(/^[A-Za-z0-9_-]+$/)
			expect(token).toHaveLength(43) // 32 random bytes, base64url, no padding
			tokens.add(token)
		}
		expect(tokens.size).toBe(50)
	})

	it("honours a custom byte length", () => {
		expect(generateSecret(16)).toHaveLength(22)
		expect(generateSecret(48)).toHaveLength(64)
	})

	it("generates distinct seed passwords", () => {
		const a = generatePassword()
		const b = generatePassword()
		expect(a).toMatch(/^[A-Za-z0-9_-]+$/)
		expect(a).toHaveLength(24) // 18 random bytes, base64url
		expect(a).not.toBe(b)
	})
})
