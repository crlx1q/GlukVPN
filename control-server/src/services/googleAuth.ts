/**
 * "Continue with Google" for the website.
 *
 * The browser gets an ID token from Google Identity Services and posts it to
 * `/api/auth/google`. This module verifies that token the way Google's own
 * libraries do - signature against Google's published JWKS, issuer, audience
 * (our client id), expiry - with nothing but node:crypto, so no dependency
 * carries a private key or a network call we did not write.
 *
 * What comes out is a verified `{ sub, email, emailVerified, name, picture }`.
 * Deciding what to do with it (sign in, link, register) belongs to the route.
 */
import { createPublicKey, verify as verifySignature, type KeyObject } from "node:crypto"
import { config } from "../config"
import { badRequest, serviceUnavailable } from "../lib/errors"

const JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
const ISSUERS = new Set(["accounts.google.com", "https://accounts.google.com"])
/** Google rotates keys roughly daily; six hours is well inside their cache-control. */
const JWKS_TTL_MS = 6 * 60 * 60 * 1000
/** Tolerate a little clock drift, as Google's verifier does. */
const CLOCK_SKEW_SEC = 60

type Jwk = { kid: string; kty: string; alg?: string; n: string; e: string; use?: string }

export type GoogleIdentity = {
	sub: string
	email: string
	emailVerified: boolean
	name: string | null
	picture: string | null
	/** Google Workspace domain, when the account belongs to one. */
	hostedDomain: string | null
}

type Cache = { keys: Map<string, KeyObject>; fetchedAt: number }
let cache: Cache | null = null

/** Test hook: preload keys so verification runs without the network. */
export function __setGoogleJwksForTests(keys: Jwk[] | null): void {
	cache = keys ? { keys: toKeyObjects(keys), fetchedAt: Date.now() } : null
}

function toKeyObjects(keys: Jwk[]): Map<string, KeyObject> {
	const map = new Map<string, KeyObject>()
	for (const jwk of keys) {
		if (jwk.kty !== "RSA" || !jwk.kid) continue
		try {
			map.set(jwk.kid, createPublicKey({ key: { kty: "RSA", n: jwk.n, e: jwk.e }, format: "jwk" }))
		} catch {
			// A malformed key in the set must not take the others down.
		}
	}
	return map
}

async function loadKeys(force = false): Promise<Map<string, KeyObject>> {
	if (!force && cache && Date.now() - cache.fetchedAt < JWKS_TTL_MS) return cache.keys
	let response: Response
	try {
		response = await fetch(JWKS_URL, {
			headers: { accept: "application/json" },
			signal: AbortSignal.timeout(5000),
		})
	} catch {
		if (cache) return cache.keys
		throw serviceUnavailable("Google sign-in is temporarily unavailable")
	}
	if (!response.ok) {
		if (cache) return cache.keys
		throw serviceUnavailable("Google sign-in is temporarily unavailable")
	}
	const body = (await response.json()) as { keys?: Jwk[] }
	cache = { keys: toKeyObjects(body.keys ?? []), fetchedAt: Date.now() }
	return cache.keys
}

function decodeSegment(segment: string): Record<string, unknown> {
	try {
		return JSON.parse(Buffer.from(segment, "base64url").toString("utf8")) as Record<string, unknown>
	} catch {
		throw badRequest("Invalid Google token")
	}
}

export function googleConfigured(): boolean {
	return config.GOOGLE_CLIENT_ID.trim().length > 0
}

/**
 * Verifies a Google ID token and returns the identity it asserts.
 * Throws a 400 for anything that is not a valid, current token *for us*.
 */
export async function verifyGoogleIdToken(credential: string): Promise<GoogleIdentity> {
	if (!googleConfigured()) throw serviceUnavailable("Google sign-in is not enabled on this server")
	const parts = String(credential ?? "").trim().split(".")
	if (parts.length !== 3) throw badRequest("Invalid Google token")
	const [headerB64, payloadB64, signatureB64] = parts as [string, string, string]

	const header = decodeSegment(headerB64)
	if (header.alg !== "RS256" || typeof header.kid !== "string") {
		throw badRequest("Unsupported Google token")
	}

	let keys = await loadKeys()
	let key = keys.get(header.kid)
	if (!key) {
		// Unknown kid: Google may have rotated since our last fetch.
		keys = await loadKeys(true)
		key = keys.get(header.kid)
	}
	if (!key) throw badRequest("Google token signed with an unknown key")

	const signed = Buffer.from(`${headerB64}.${payloadB64}`, "utf8")
	const signature = Buffer.from(signatureB64, "base64url")
	const valid = verifySignature("RSA-SHA256", signed, key, signature)
	if (!valid) throw badRequest("Google token signature does not verify")

	const payload = decodeSegment(payloadB64)
	const now = Math.floor(Date.now() / 1000)
	const exp = Number(payload.exp)
	const iat = Number(payload.iat)
	if (!Number.isFinite(exp) || exp + CLOCK_SKEW_SEC < now) throw badRequest("Google token has expired")
	if (Number.isFinite(iat) && iat - CLOCK_SKEW_SEC > now) throw badRequest("Google token is not valid yet")
	if (typeof payload.iss !== "string" || !ISSUERS.has(payload.iss)) {
		throw badRequest("Google token issuer is not Google")
	}
	const audience = Array.isArray(payload.aud) ? payload.aud : [payload.aud]
	if (!audience.includes(config.GOOGLE_CLIENT_ID.trim())) {
		throw badRequest("Google token was issued for another application")
	}
	if (typeof payload.sub !== "string" || !payload.sub) throw badRequest("Google token has no subject")

	const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : ""
	const emailVerified = payload.email_verified === true || payload.email_verified === "true"
	if (!email) throw badRequest("Google did not share an email address")

	return {
		sub: payload.sub,
		email,
		emailVerified,
		name: typeof payload.name === "string" ? payload.name : null,
		picture: typeof payload.picture === "string" ? payload.picture : null,
		hostedDomain: typeof payload.hd === "string" ? payload.hd : null,
	}
}
