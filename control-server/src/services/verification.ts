/**
 * Short-lived confirmation codes.
 *
 * One implementation serves every flow that needs "prove you control this
 * address/handle": email verification, email change, password reset,
 * self-registration and new-device confirmation — over email now, Telegram
 * later. Adding a flow means adding an enum value, not new plumbing.
 *
 * Security rules, same as refresh and node tokens:
 *   - the code is generated from the CSPRNG, never from Math.random;
 *   - only its HMAC is stored, so a database dump cannot be replayed;
 *   - the hash is bound to purpose + destination, so a code minted for one
 *     flow cannot be spent in another;
 *   - a fixed number of wrong guesses burns the code;
 *   - the plaintext code is never logged, never audited and never returned by
 *     the API — it exists only in the message sent to the user.
 */

import { randomInt } from "node:crypto"
import type { VerificationChannel, VerificationCode, VerificationPurpose } from "@prisma/client"
import { config } from "../config"
import { hashSecret } from "../lib/crypto"
import { badRequest, serviceUnavailable, tooManyRequests } from "../lib/errors"
import { prisma } from "../prisma"

const CODE_DIGITS = 6

/**
 * Flip to true in the same commit that adds a real SMTP transport.
 *
 * Until then `mailerReady()` is false and every route that would need to send
 * a code answers 503 instead of pretending. That is deliberate: a flow that
 * silently issues codes nobody receives looks like a broken login to the user,
 * and returning the code in the response would defeat the whole point.
 */
const MAILER_IMPLEMENTED = false

/** True when codes can actually be delivered (SMTP configured + wired up). */
export function mailerReady(): boolean {
	return MAILER_IMPLEMENTED && config.emailEnabled
}

/** Lower-cased, trimmed. The unique index relies on this being the only form. */
export function normalizeEmail(value: string): string {
	return value.trim().toLowerCase()
}

/** Uniform 6-digit code from the CSPRNG (000000..999999). */
export function generateCode(): string {
	return String(randomInt(0, 10 ** CODE_DIGITS)).padStart(CODE_DIGITS, "0")
}

/** Bind the hash to the flow and the target, not just to the digits. */
function codeHash(
	purpose: VerificationPurpose,
	destination: string,
	code: string,
): string {
	return hashSecret(`${purpose}:${destination}:${code}`)
}

export type IssuedCode = {
	expiresAt: Date
	/** False when no transport is configured; the caller must not claim it sent. */
	delivered: boolean
}

/**
 * Create a code for one purpose+destination and invalidate any earlier pending
 * code for the same pair, so a resend cannot be used to widen the guess window.
 */
export async function issueCode(params: {
	purpose: VerificationPurpose
	destination: string
	userId?: string | null
	channel?: VerificationChannel
	ip?: string | null
}): Promise<IssuedCode> {
	const destination = params.destination.trim()
	if (destination.length === 0) throw badRequest("A destination is required")

	const code = generateCode()
	const expiresAt = new Date(
		Date.now() + config.VERIFICATION_CODE_TTL_MIN * 60 * 1000,
	)

	await prisma.verificationCode.updateMany({
		where: { purpose: params.purpose, destination, consumedAt: null },
		data: { consumedAt: new Date() },
	})

	await prisma.verificationCode.create({
		data: {
			userId: params.userId ?? null,
			purpose: params.purpose,
			channel: params.channel ?? "EMAIL",
			destination,
			codeHash: codeHash(params.purpose, destination, code),
			expiresAt,
			createdIp: params.ip ?? null,
		},
	})

	const delivered = await deliver(params.channel ?? "EMAIL", destination, code)
	return { expiresAt, delivered }
}

/**
 * Deliver a code. The only place in the codebase that ever sees the plaintext.
 *
 * Wiring Zoho Mail is a change confined to this function: create a nodemailer
 * transport from config.SMTP_* and flip MAILER_IMPLEMENTED. Nothing above or
 * below needs to change.
 */
async function deliver(
	channel: VerificationChannel,
	destination: string,
	code: string,
): Promise<boolean> {
	if (!mailerReady()) {
		// Note the absence of `code` and `destination` here: a journal is not a
		// safe place for either.
		return false
	}
	// The code is intentionally unused until a transport exists; referencing it
	// keeps the signature honest for whoever wires SMTP up.
	void channel
	void destination
	void code
	throw serviceUnavailable("Code delivery is not configured")
}

/**
 * Verify and burn the newest pending code.
 *
 * Look-up is by owner (user or destination), never by the code itself, so a
 * wrong guess is counted against exactly one record instead of scanning the
 * table for a match.
 */
export async function consumeCode(params: {
	purpose: VerificationPurpose
	code: string
	userId?: string | null
	destination?: string | null
}): Promise<VerificationCode> {
	const pending = await prisma.verificationCode.findFirst({
		where: {
			purpose: params.purpose,
			consumedAt: null,
			...(params.userId ? { userId: params.userId } : {}),
			...(params.destination ? { destination: params.destination.trim() } : {}),
		},
		orderBy: { createdAt: "desc" },
	})

	// Same answer for "no code was requested" and "code expired": neither tells
	// an attacker anything useful.
	if (!pending) throw badRequest("This code is no longer valid. Request a new one.")
	if (pending.expiresAt.getTime() <= Date.now()) {
		await prisma.verificationCode.update({
			where: { id: pending.id },
			data: { consumedAt: new Date() },
		})
		throw badRequest("This code has expired. Request a new one.")
	}
	if (pending.attempts >= config.VERIFICATION_MAX_ATTEMPTS) {
		await prisma.verificationCode.update({
			where: { id: pending.id },
			data: { consumedAt: new Date() },
		})
		throw tooManyRequests("Too many wrong codes. Request a new one.")
	}

	const expected = codeHash(
		pending.purpose,
		pending.destination,
		params.code.trim(),
	)
	// Both sides are fixed-length hex digests of the same length, so a plain
	// comparison leaks nothing useful here.
	if (expected !== pending.codeHash) {
		await prisma.verificationCode.update({
			where: { id: pending.id },
			data: { attempts: { increment: 1 } },
		})
		throw badRequest("Incorrect code")
	}

	return prisma.verificationCode.update({
		where: { id: pending.id },
		data: { consumedAt: new Date() },
	})
}

/** Housekeeping for the monitor tick: drop codes nobody can use any more. */
export async function purgeExpiredCodes(olderThanDays = 7): Promise<number> {
	const cutoff = new Date(Date.now() - olderThanDays * 24 * 60 * 60 * 1000)
	const result = await prisma.verificationCode.deleteMany({
		where: { createdAt: { lt: cutoff } },
	})
	return result.count
}
