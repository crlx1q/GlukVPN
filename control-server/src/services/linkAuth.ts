import { randomBytes, randomInt, timingSafeEqual } from "node:crypto"

/**
 * Sign-in by link - the flow the desktop client and the extension now share.
 *
 * The old "sign in on the website" button was a dead end: it opened
 * vpn.gluk.tech and left the user to type the same password again into the
 * client. The extension worked around it with its own storage bridge, which is
 * the "костыль" this replaces.
 *
 * This is the OAuth device-authorization grant, shaped like GeForce Now's:
 *
 *   1. client  -> POST /api/auth/link/start
 *                 gets { userCode, verifyUrl, pollSecret }
 *   2. client  -> opens verifyUrl in the system browser
 *   3. user    -> already signed in on the site, presses "Разрешить"
 *      site    -> POST /api/auth/link/:userCode/approve   (needs a session)
 *   4. client  -> POST /api/auth/link/poll every 2s, and the first call after
 *                 approval returns real tokens. One time only.
 *
 * Two secrets, two different jobs:
 *
 *  - `userCode` is short enough to read out loud and travels in a URL. It only
 *    ever identifies a *request*, never authorises anything: approving it
 *    requires a signed-in session on the site.
 *  - `pollSecret` is 32 random bytes and never leaves the requesting client.
 *    It is what proves the poller is the same process that started the flow,
 *    so knowing a userCode is not enough to steal the tokens.
 *
 * Storage is in-memory on purpose. These records live for ten minutes, are
 * single-use, and are worthless after a restart - persisting them would mean a
 * Prisma migration for data that is by definition throwaway. If the control
 * server is ever scaled past one instance this needs Redis (or a `LinkRequest`
 * model); until then a Map is the honest choice.
 */

export type LinkStatus = "pending" | "approved" | "denied" | "expired" | "used"

export type LinkClientKind = "windows" | "android" | "extension" | "web"

export type LinkTokenPayload = {
	tokenType: "Bearer"
	accessToken: string
	expiresIn: number
	refreshToken: string
	refreshTokenExpiresAt: string
	user: Record<string, unknown>
	subscription: Record<string, unknown> | null
}

type LinkRecord = {
	id: string
	userCode: string
	pollSecretHash: Buffer
	client: LinkClientKind
	/** What the site shows the user: "GlukVPN на Windows", the PC name, and so on. */
	deviceName: string | null
	ip: string | null
	userAgent: string | null
	createdAt: number
	expiresAt: number
	status: LinkStatus
	userId: string | null
	tokens: LinkTokenPayload | null
	/** Guards against a client hammering poll faster than the advertised interval. */
	lastPollAt: number
}

/** Ten minutes is long enough to find the browser window, short enough to be safe. */
const TTL_MS = 10 * 60 * 1000
const POLL_INTERVAL_SEC = 2
/** A client that never comes back must not pin memory forever. */
const MAX_RECORDS = 5000

// Crockford-style alphabet: no I, L, O, U, 0 or 1, so a code read off a screen
// cannot be mistyped into a different valid code.
const ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

const byCode = new Map<string, LinkRecord>()
const byId = new Map<string, LinkRecord>()

function sha256(value: string): Buffer {
	// Local import keeps the module tree small; this is the only hash we need.
	// eslint-disable-next-line @typescript-eslint/no-var-requires
	const { createHash } = require("node:crypto") as typeof import("node:crypto")
	return createHash("sha256").update(value, "utf8").digest()
}

function makeCode(): string {
	let code = ""
	for (let i = 0; i < 8; i += 1) {
		code += ALPHABET[randomInt(0, ALPHABET.length)]
	}
	// GLUK-XXXX-XXXX reads as one token and is obviously ours in a URL bar.
	return `${code.slice(0, 4)}-${code.slice(4)}`
}

function expire(record: LinkRecord, now: number): void {
	if (record.status === "pending" && record.expiresAt <= now) {
		record.status = "expired"
	}
}

function sweep(now: number): void {
	for (const [code, record] of byCode) {
		// Keep a finished record around for one extra TTL so the client gets a
		// truthful "denied"/"expired" instead of a confusing "unknown code".
		if (record.expiresAt + TTL_MS <= now) {
			byCode.delete(code)
			byId.delete(record.id)
		}
	}
}

export type StartedLink = {
	requestId: string
	userCode: string
	pollSecret: string
	expiresAt: Date
	intervalSec: number
}

export function startLink(input: {
	client: LinkClientKind
	deviceName?: string | null
	ip?: string | null
	userAgent?: string | null
}): StartedLink {
	const now = Date.now()
	sweep(now)
	if (byCode.size >= MAX_RECORDS) {
		// Drop the oldest pending record rather than refusing honest clients.
		const oldest = [...byCode.values()].sort((a, b) => a.createdAt - b.createdAt)[0]
		if (oldest) {
			byCode.delete(oldest.userCode)
			byId.delete(oldest.id)
		}
	}

	let userCode = makeCode()
	while (byCode.has(userCode)) userCode = makeCode()

	const pollSecret = randomBytes(32).toString("base64url")
	const record: LinkRecord = {
		id: randomBytes(16).toString("hex"),
		userCode,
		pollSecretHash: sha256(pollSecret),
		client: input.client,
		deviceName: input.deviceName?.slice(0, 64) ?? null,
		ip: input.ip ?? null,
		userAgent: input.userAgent?.slice(0, 190) ?? null,
		createdAt: now,
		expiresAt: now + TTL_MS,
		status: "pending",
		userId: null,
		tokens: null,
		lastPollAt: 0,
	}

	byCode.set(userCode, record)
	byId.set(record.id, record)

	return {
		requestId: record.id,
		userCode,
		pollSecret,
		expiresAt: new Date(record.expiresAt),
		intervalSec: POLL_INTERVAL_SEC,
	}
}

export type LinkDescription = {
	requestId: string
	userCode: string
	client: LinkClientKind
	deviceName: string | null
	ip: string | null
	status: LinkStatus
	expiresAt: string
}

/** What the website needs to render "allow this device?" honestly. */
export function describeLink(userCode: string): LinkDescription | null {
	const record = byCode.get(normalizeCode(userCode))
	if (!record) return null
	expire(record, Date.now())
	return {
		requestId: record.id,
		userCode: record.userCode,
		client: record.client,
		deviceName: record.deviceName,
		ip: record.ip,
		status: record.status,
		expiresAt: new Date(record.expiresAt).toISOString(),
	}
}

export function normalizeCode(raw: string): string {
	const clean = raw.trim().toUpperCase().replace(/[^A-Z0-9]/g, "")
	return clean.length === 8 ? `${clean.slice(0, 4)}-${clean.slice(4)}` : clean
}

export type ApproveOutcome =
	| { ok: true; record: LinkDescription }
	| { ok: false; reason: "unknown" | "expired" | "already" }

/**
 * Called by the *site*, with a signed-in user. The tokens are minted by the
 * caller (which owns `issueTokens`) and handed over here for pickup.
 */
export function approveLink(input: {
	userCode: string
	userId: string
	tokens: LinkTokenPayload
}): ApproveOutcome {
	const record = byCode.get(normalizeCode(input.userCode))
	if (!record) return { ok: false, reason: "unknown" }

	expire(record, Date.now())
	if (record.status === "expired") return { ok: false, reason: "expired" }
	if (record.status !== "pending") return { ok: false, reason: "already" }

	record.status = "approved"
	record.userId = input.userId
	record.tokens = input.tokens
	return { ok: true, record: describeLink(record.userCode)! }
}

export function denyLink(userCode: string): ApproveOutcome {
	const record = byCode.get(normalizeCode(userCode))
	if (!record) return { ok: false, reason: "unknown" }
	expire(record, Date.now())
	if (record.status !== "pending") return { ok: false, reason: "already" }
	record.status = "denied"
	return { ok: true, record: describeLink(record.userCode)! }
}

export type PollOutcome =
	| { status: "pending"; intervalSec: number }
	| { status: "denied" | "expired" | "unknown" | "slow_down" }
	| { status: "approved"; tokens: LinkTokenPayload }

/**
 * The client side of the flow. Approved tokens are handed out exactly once:
 * a replayed poll gets "used", not a second copy of the credentials.
 */
export function pollLink(input: { requestId: string; pollSecret: string }): PollOutcome {
	const record = byId.get(input.requestId)
	if (!record) return { status: "unknown" }

	// Constant-time comparison: the secret is the only thing standing between a
	// guessed request id and someone else's session.
	const offered = sha256(input.pollSecret)
	if (
		offered.length !== record.pollSecretHash.length ||
		!timingSafeEqual(offered, record.pollSecretHash)
	) {
		return { status: "unknown" }
	}

	const now = Date.now()
	expire(record, now)

	// Politely push back instead of letting a tight loop melt the endpoint.
	if (record.status === "pending" && now - record.lastPollAt < (POLL_INTERVAL_SEC * 1000) / 2) {
		return { status: "slow_down" }
	}
	record.lastPollAt = now

	if (record.status === "pending") return { status: "pending", intervalSec: POLL_INTERVAL_SEC }
	if (record.status === "approved" && record.tokens) {
		const tokens = record.tokens
		record.tokens = null
		record.status = "used"
		return { status: "approved", tokens }
	}
	if (record.status === "used") return { status: "expired" }
	return { status: record.status === "denied" ? "denied" : "expired" }
}

/** Test helper: the module keeps process-wide state. */
export function __resetLinkStore(): void {
	byCode.clear()
	byId.clear()
}
