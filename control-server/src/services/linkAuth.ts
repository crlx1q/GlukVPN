import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto"
import type { LinkRequest, LinkRequestStatus } from "@prisma/client"
import { prisma } from "../prisma"

/**
 * Sign-in by link - the flow the desktop client, the extension and the website
 * share.
 *
 * This is the OAuth device-authorization grant, shaped like GeForce Now's:
 *
 *   1. client  -> POST /api/auth/link/start
 *                 gets { userCode, verifyUrl, telegramUrl, pollSecret }
 *   2. client  -> opens verifyUrl (or the Telegram deep link)
 *   3. user    -> already signed in on the site (or in the bot), presses "Allow"
 *      site    -> POST /api/auth/link/:userCode/approve   (needs a session)
 *   4. client  -> POST /api/auth/link/poll every 2s, and the first call after
 *                 approval returns real tokens. One time only.
 *
 * Two secrets, two different jobs:
 *
 *  - `userCode` is short enough to read out loud and travels in a URL. It only
 *    ever identifies a *request*, never authorises anything: approving it
 *    requires a signed-in session on the site or a phone-verified Telegram chat.
 *  - `pollSecret` is 32 random bytes and never leaves the requesting client.
 *    It is what proves the poller is the same process that started the flow,
 *    so knowing a userCode is not enough to steal the tokens.
 *
 * ROUND 26: records live in the `link_requests` table instead of a Map. An API
 * restart mid-flow no longer strands the client on "unknown code", prod and
 * beta each keep their own table rather than their own RAM, and the Telegram
 * bot can approve a request whichever process it happens to run in.
 *
 * No token is persisted: approval records the user id, and the tokens are
 * minted by the poll route at the moment the client collects them (`mint` is
 * passed in by the caller because signing needs the Fastify JWT instance).
 * That keeps the standing rule - raw tokens never touch the database.
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

/**
 * Five minutes: long enough to switch to the browser and press a button, short
 * enough that an abandoned request does not sit around holding a code that
 * still works. Deliberately the same number as VERIFICATION_CODE_TTL_MIN, so
 * every code in the product expires on one clock rather than three.
 */
const TTL_MS = 5 * 60 * 1000
const POLL_INTERVAL_SEC = 2

// Crockford-style alphabet: no I, L, O, U, 0 or 1, so a code read off a screen
// cannot be mistyped into a different valid code.
const ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

function sha256Hex(value: string): string {
	return createHash("sha256").update(value, "utf8").digest("hex")
}

function makeCode(): string {
	let code = ""
	for (let i = 0; i < 8; i += 1) {
		code += ALPHABET[randomInt(0, ALPHABET.length)]
	}
	// GLUK-XXXX-XXXX reads as one token and is obviously ours in a URL bar.
	return `${code.slice(0, 4)}-${code.slice(4)}`
}

export function normalizeCode(raw: string): string {
	const clean = raw.trim().toUpperCase().replace(/[^A-Z0-9]/g, "")
	return clean.length === 8 ? `${clean.slice(0, 4)}-${clean.slice(4)}` : clean
}

function toStatus(record: LinkRequest, now: number): LinkStatus {
	if (record.status === "PENDING" && record.expiresAt.getTime() <= now) return "expired"
	return record.status.toLowerCase() as LinkStatus
}

/** Marks a request expired in the table when its TTL passed while PENDING. */
async function settleExpiry(record: LinkRequest, now: number): Promise<LinkRequest> {
	if (record.status === "PENDING" && record.expiresAt.getTime() <= now) {
		return prisma.linkRequest.update({
			where: { id: record.id },
			data: { status: "EXPIRED" },
		})
	}
	return record
}

export type StartedLink = {
	requestId: string
	userCode: string
	pollSecret: string
	expiresAt: Date
	intervalSec: number
}

export async function startLink(input: {
	client: LinkClientKind
	deviceName?: string | null
	ip?: string | null
	userAgent?: string | null
}): Promise<StartedLink> {
	const now = Date.now()
	const pollSecret = randomBytes(32).toString("base64url")

	// The code space is 30^8; a collision is a retry, not a failure.
	for (let attempt = 0; attempt < 5; attempt += 1) {
		const userCode = makeCode()
		const taken = await prisma.linkRequest.findUnique({
			where: { userCode },
			select: { id: true },
		})
		if (taken) continue
		const record = await prisma.linkRequest.create({
			data: {
				userCode,
				pollSecretHash: sha256Hex(pollSecret),
				client: input.client,
				deviceName: input.deviceName?.slice(0, 64) ?? null,
				ip: input.ip ?? null,
				userAgent: input.userAgent?.slice(0, 190) ?? null,
				expiresAt: new Date(now + TTL_MS),
			},
		})
		return {
			requestId: record.id,
			userCode,
			pollSecret,
			expiresAt: record.expiresAt,
			intervalSec: POLL_INTERVAL_SEC,
		}
	}
	throw new Error("could not allocate a sign-in code")
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

function describe(record: LinkRequest, now: number): LinkDescription {
	return {
		requestId: record.id,
		userCode: record.userCode,
		client: record.client as LinkClientKind,
		deviceName: record.deviceName,
		ip: record.ip,
		status: toStatus(record, now),
		expiresAt: record.expiresAt.toISOString(),
	}
}

/** What the website (or the bot) needs to render "allow this device?" honestly. */
export async function describeLink(userCode: string): Promise<LinkDescription | null> {
	const record = await prisma.linkRequest.findUnique({
		where: { userCode: normalizeCode(userCode) },
	})
	if (!record) return null
	const now = Date.now()
	return describe(await settleExpiry(record, now), now)
}

export type ApproveOutcome =
	| { ok: true; record: LinkDescription }
	| { ok: false; reason: "unknown" | "expired" | "already" }

/**
 * Called by the *site* or the *bot*, with a proven user. Only the user id is
 * recorded; the poller mints the tokens when it collects them.
 */
export async function approveLink(input: {
	userCode: string
	userId: string
	via: "web" | "telegram"
}): Promise<ApproveOutcome> {
	const record = await prisma.linkRequest.findUnique({
		where: { userCode: normalizeCode(input.userCode) },
	})
	if (!record) return { ok: false, reason: "unknown" }

	const now = Date.now()
	const current = toStatus(record, now)
	if (current === "expired") {
		await settleExpiry(record, now)
		return { ok: false, reason: "expired" }
	}
	if (current !== "pending") return { ok: false, reason: "already" }

	// Conditional update: two approvals racing can only win once.
	const claimed = await prisma.linkRequest.updateMany({
		where: { id: record.id, status: "PENDING" },
		data: {
			status: "APPROVED",
			userId: input.userId,
			approvedVia: input.via,
			approvedAt: new Date(now),
		},
	})
	if (claimed.count !== 1) return { ok: false, reason: "already" }

	const updated = await prisma.linkRequest.findUniqueOrThrow({ where: { id: record.id } })
	return { ok: true, record: describe(updated, now) }
}

export async function denyLink(userCode: string): Promise<ApproveOutcome> {
	const record = await prisma.linkRequest.findUnique({
		where: { userCode: normalizeCode(userCode) },
	})
	if (!record) return { ok: false, reason: "unknown" }
	const now = Date.now()
	if (toStatus(record, now) !== "pending") return { ok: false, reason: "already" }

	const claimed = await prisma.linkRequest.updateMany({
		where: { id: record.id, status: "PENDING" },
		data: { status: "DENIED" },
	})
	if (claimed.count !== 1) return { ok: false, reason: "already" }
	const updated = await prisma.linkRequest.findUniqueOrThrow({ where: { id: record.id } })
	return { ok: true, record: describe(updated, now) }
}

export type PollOutcome =
	| { status: "pending"; intervalSec: number }
	| { status: "denied" | "expired" | "unknown" | "slow_down" }
	| { status: "approved"; tokens: LinkTokenPayload }

/**
 * The client side of the flow. Approved tokens are handed out exactly once: a
 * replayed poll gets "expired", not a second copy of the credentials. `mint`
 * is only invoked for the single poll that wins the APPROVED -> USED update.
 */
export async function pollLink(input: {
	requestId: string
	pollSecret: string
	mint: (userId: string) => Promise<LinkTokenPayload | null>
}): Promise<PollOutcome> {
	const record = await prisma.linkRequest.findUnique({ where: { id: input.requestId } })
	if (!record) return { status: "unknown" }

	// Constant-time comparison: the secret is the only thing standing between a
	// guessed request id and someone else's session.
	const offered = Buffer.from(sha256Hex(input.pollSecret), "hex")
	const stored = Buffer.from(record.pollSecretHash, "hex")
	if (offered.length !== stored.length || !timingSafeEqual(offered, stored)) {
		return { status: "unknown" }
	}

	const now = Date.now()
	const status = toStatus(record, now)

	if (status === "pending") {
		// Politely push back instead of letting a tight loop melt the endpoint.
		const last = record.lastPollAt?.getTime() ?? 0
		if (now - last < (POLL_INTERVAL_SEC * 1000) / 2) return { status: "slow_down" }
		await prisma.linkRequest.update({
			where: { id: record.id },
			data: { lastPollAt: new Date(now) },
		})
		return { status: "pending", intervalSec: POLL_INTERVAL_SEC }
	}

	if (status === "approved" && record.userId) {
		// APPROVED -> USED is the single-use gate; whoever flips it gets tokens.
		const won = await prisma.linkRequest.updateMany({
			where: { id: record.id, status: "APPROVED" },
			data: { status: "USED", usedAt: new Date(now), lastPollAt: new Date(now) },
		})
		if (won.count !== 1) return { status: "expired" }
		const tokens = await input.mint(record.userId)
		if (!tokens) return { status: "denied" }
		return { status: "approved", tokens }
	}

	if (status === "expired") {
		await settleExpiry(record, now)
		return { status: "expired" }
	}
	if (status === "used") return { status: "expired" }
	return { status: status === "denied" ? "denied" : "expired" }
}

/**
 * Housekeeping for the monitor: finished and expired requests are worthless
 * after one extra TTL (kept that long so a late client gets a truthful
 * "expired" instead of "unknown").
 */
export async function purgeLinkRequests(): Promise<number> {
	const cutoff = new Date(Date.now() - TTL_MS)
	const result = await prisma.linkRequest.deleteMany({
		where: {
			OR: [
				{ status: { in: ["USED", "DENIED", "EXPIRED"] as LinkRequestStatus[] }, expiresAt: { lt: cutoff } },
				{ status: { in: ["PENDING", "APPROVED"] as LinkRequestStatus[] }, expiresAt: { lt: new Date(Date.now() - 2 * TTL_MS) } },
			],
		},
	})
	return result.count
}
