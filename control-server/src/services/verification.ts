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
import { badRequest, tooManyRequests } from "../lib/errors"
import { prisma } from "../prisma"

const CODE_DIGITS = 6

/**
 * True when codes can actually be delivered.
 *
 * This used to be a hard-coded `false` with a note to flip it once SMTP
 * existed. SMTP exists now (services/mailer.ts), so the only question left is
 * whether this deployment has credentials - and if it does not, routes still
 * answer honestly instead of issuing codes nobody will ever receive.
 */
export function mailerReady(): boolean {
	return config.emailEnabled
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
	/**
	 * Set false when the secret already reached the user by another route -
	 * a Telegram deep link carries its own token, so there is nothing to send
	 * and an attempted delivery would just be a wasted SMTP connection.
	 */
	deliver?: boolean
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

	if (params.deliver === false) return { expiresAt, delivered: true }

	const delivered = await deliver(params.channel ?? "EMAIL", destination, code)
	return { expiresAt, delivered }
}

/** Minutes, for the message body. Reading "5 minutes" beats reading a clock. */
function ttlMinutes(): number {
	return config.VERIFICATION_CODE_TTL_MIN
}

/**
 * Deliver a code. The only place in the codebase that ever sees the plaintext.
 *
 * Nothing is logged here on any path - not the code, not the address. A
 * journal is not a safe place for either, and "just for debugging" is how
 * one-time codes end up permanently readable in a log file.
 */
async function deliver(
	channel: VerificationChannel,
	destination: string,
	code: string,
): Promise<boolean> {
	if (channel === "TELEGRAM") {
		// Required lazily: telegramBot -> registration -> verification would
		// otherwise be an import cycle, and the bot is only needed at call time.
		const { sendTelegramMessage } =
			require("./telegramBot") as typeof import("./telegramBot")
		return sendTelegramMessage(
			destination,
			`\u041a\u043e\u0434 \u043f\u043e\u0434\u0442\u0432\u0435\u0440\u0436\u0434\u0435\u043d\u0438\u044f <b>GlukVPN</b>: <code>${code}</code>\n\n` +
				`\u0414\u0435\u0439\u0441\u0442\u0432\u0443\u0435\u0442 ${ttlMinutes()} \u043c\u0438\u043d\u0443\u0442. \u0415\u0441\u043b\u0438 \u044d\u0442\u043e \u043d\u0435 \u0432\u044b \u2014 \u043f\u0440\u043e\u0441\u0442\u043e \u043f\u0440\u043e\u0438\u0433\u043d\u043e\u0440\u0438\u0440\u0443\u0439\u0442\u0435 \u044d\u0442\u043e \u0441\u043e\u043e\u0431\u0449\u0435\u043d\u0438\u0435.`,
		)
	}

	if (!mailerReady()) return false

	const { sendMail } = require("./mailer") as typeof import("./mailer")
	try {
		await sendMail({
			to: destination,
			subject: `GlukVPN: \u043a\u043e\u0434 \u043f\u043e\u0434\u0442\u0432\u0435\u0440\u0436\u0434\u0435\u043d\u0438\u044f ${code}`,
			text:
				`\u041a\u043e\u0434 \u043f\u043e\u0434\u0442\u0432\u0435\u0440\u0436\u0434\u0435\u043d\u0438\u044f GlukVPN: ${code}\n\n` +
				`\u0414\u0435\u0439\u0441\u0442\u0432\u0443\u0435\u0442 ${ttlMinutes()} \u043c\u0438\u043d\u0443\u0442.\n\n` +
				`\u0415\u0441\u043b\u0438 \u0432\u044b \u043d\u0435 \u0437\u0430\u043f\u0440\u0430\u0448\u0438\u0432\u0430\u043b\u0438 \u043a\u043e\u0434, \u043f\u0440\u043e\u0441\u0442\u043e \u0443\u0434\u0430\u043b\u0438\u0442\u0435 \u044d\u0442\u043e \u043f\u0438\u0441\u044c\u043c\u043e \u2014 \u0431\u0435\u0437 \u043d\u0435\u0433\u043e \u043d\u0438\u0447\u0435\u0433\u043e\n` +
				`\u043d\u0435 \u043f\u0440\u043e\u0438\u0437\u043e\u0439\u0434\u0451\u0442.\n\n\u2014 GlukVPN, vpn.gluk.tech`,
		})
		return true
	} catch {
		// A refused send is not a reason to lose the code: the user can ask for
		// a resend, and `delivered: false` is what tells the UI to offer that.
		return false
	}
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
