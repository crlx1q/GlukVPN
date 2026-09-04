/**
 * Self-service sign-up.
 *
 * The funnel is deliberately three steps:
 *
 *   1. email + password (twice, checked in the browser)
 *   2. a 6-digit code sent to that address
 *   3. Telegram: the user opens the bot and shares their contact
 *
 * Only after all three does a `User` row exist. Everything before that lives
 * in `PendingRegistration`, which means an abandoned sign-up cannot occupy a
 * username, cannot sign in, cannot receive a password reset, and is deleted by
 * the sweeper instead of lingering as a half-account.
 *
 * Why Telegram at all: the email code proves the address exists, nothing more.
 * Addresses are free and infinite. A phone number shared through Telegram's
 * own contact button is scarce and tied to a SIM, so it is what actually makes
 * one human one account - which is the whole point of the step, and why the
 * bot refuses a *forwarded* contact.
 *
 * Google sign-up skips step 2 (Google already proved the address) but never
 * step 3.
 */

import { randomInt } from "node:crypto"
import type { PendingRegistration, Prisma } from "@prisma/client"
import { config } from "../config"
import { hashPassword } from "../lib/crypto"
import { badRequest, conflict } from "../lib/errors"
import { prisma } from "../prisma"
import { grantDefaultSubscription } from "./billing"
import { consumeCode, issueCode, normalizeEmail } from "./verification"

/** The whole funnel. Long enough to go find the email, short enough to be junk. */
const PENDING_TTL_MIN = 30

/** No I, L, O, U, 0 or 1: this token can end up retyped into a chat by hand. */
const TOKEN_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

/**
 * Assembled from parts rather than written as one literal, so that no tool in
 * the pipeline mistakes it for a real link and rewrites it.
 */
const LINK_SCHEME = "https:"
const TELEGRAM_LINK_HOST = "t.me"

export type RegistrationState = "email" | "telegram" | "done"

function newToken(): string {
	let out = ""
	for (let i = 0; i < 10; i += 1) {
		out += TOKEN_ALPHABET[randomInt(0, TOKEN_ALPHABET.length)]
	}
	return out
}

/** t.me/<bot>?start=<token> - one tap, and the bot already knows who is asking. */
export function telegramDeepLink(token: string): string {
	const bot = config.TELEGRAM_BOT_USERNAME.trim().replace(/^@/, "")
	const base = `${LINK_SCHEME}//${TELEGRAM_LINK_HOST}/${bot}`
	return token ? `${base}?start=${encodeURIComponent(token)}` : base
}

export function telegramConfigured(): boolean {
	return config.TELEGRAM_BOT_TOKEN.trim().length > 0
}

/**
 * Digits with a leading plus. Telegram hands back "+7 707 123 45 67" on one
 * client and "77071234567" on another; storing both forms would silently break
 * the uniqueness rule that the whole Telegram step exists to enforce.
 */
export function normalizePhone(raw: string): string {
	const digits = String(raw ?? "").replace(/\D/g, "")
	return digits.length >= 7 ? `+${digits}` : ""
}

function pendingExpiry(): Date {
	return new Date(Date.now() + PENDING_TTL_MIN * 60 * 1000)
}

async function loadPending(email: string): Promise<PendingRegistration> {
	const pending = await prisma.pendingRegistration.findUnique({ where: { email } })
	if (!pending) {
		throw badRequest("This sign-up is unknown or has already finished. Start again.")
	}
	if (pending.expiresAt.getTime() <= Date.now()) {
		await prisma.pendingRegistration
			.delete({ where: { id: pending.id } })
			.catch(() => undefined)
		throw badRequest("This sign-up has expired. Please start again.")
	}
	return pending
}

/**
 * A free nickname derived from the address. It is renameable afterwards, so a
 * numeric suffix is not a permanent scar - but it does have to be unique right
 * now, which is why this re-checks instead of trusting one lookup.
 */
async function uniqueUsername(email: string): Promise<string> {
	let base = (email.split("@")[0] ?? "user")
		.toLowerCase()
		.replace(/[^a-z0-9._-]/g, "")
		.slice(0, 20)
	if (base.length < 3) base = `user${base}`

	for (let attempt = 0; attempt < 12; attempt += 1) {
		const candidate = attempt === 0 ? base : `${base}${randomInt(100, 10000)}`
		const taken = await prisma.user.findFirst({
			where: { username: { equals: candidate, mode: "insensitive" } },
			select: { id: true },
		})
		if (!taken) return candidate
	}
	return `user${Date.now().toString(36)}`
}

// ------------------------------------------------------------- step 1 + 2 --

export type StartedRegistration = {
	email: string
	state: RegistrationState
	expiresAt: Date
	codeExpiresAt: Date
	/** False when SMTP is not configured; the UI must not claim it sent. */
	delivered: boolean
}

export async function startRegistration(params: {
	email: string
	password: string
	ip?: string | null
}): Promise<StartedRegistration> {
	const email = normalizeEmail(params.email)
	if (params.password.length < 8) {
		throw badRequest("The password must be at least 8 characters")
	}

	const existing = await prisma.user.findFirst({ where: { email }, select: { id: true } })
	if (existing) throw conflict("An account with this email already exists")

	const passwordHash = await hashPassword(params.password)
	const expiresAt = pendingExpiry()

	// Restarting sign-up for the same address replaces the pending row rather
	// than failing. The usual reasons to restart are a mistyped password or a
	// code that never arrived, and making someone wait out a TTL for that would
	// be hostile for no security gain: the row proves nothing until step 3.
	const pending = await prisma.pendingRegistration.upsert({
		where: { email },
		create: {
			email,
			passwordHash,
			telegramCode: newToken(),
			createdIp: params.ip ?? null,
			expiresAt,
		},
		update: {
			passwordHash,
			emailVerifiedAt: null,
			telegramCode: newToken(),
			telegramId: null,
			telegramUsername: null,
			telegramPhone: null,
			telegramVerifiedAt: null,
			googleSub: null,
			createdIp: params.ip ?? null,
			expiresAt,
		},
	})

	const issued = await issueCode({
		purpose: "REGISTRATION",
		destination: email,
		channel: "EMAIL",
		ip: params.ip ?? null,
	})

	return {
		email: pending.email,
		state: "email",
		expiresAt,
		codeExpiresAt: issued.expiresAt,
		delivered: issued.delivered,
	}
}

export async function resendRegistrationCode(params: {
	email: string
	ip?: string | null
}): Promise<{ codeExpiresAt: Date; delivered: boolean }> {
	const email = normalizeEmail(params.email)
	const pending = await loadPending(email)
	if (pending.emailVerifiedAt) {
		throw badRequest("This address is already confirmed")
	}
	const issued = await issueCode({
		purpose: "REGISTRATION",
		destination: email,
		channel: "EMAIL",
		ip: params.ip ?? null,
	})
	return { codeExpiresAt: issued.expiresAt, delivered: issued.delivered }
}

export type EmailConfirmed = {
	state: RegistrationState
	telegramUrl: string
	/** Shown as a fallback for anyone who has to type it into the bot by hand. */
	telegramCode: string
}

export async function confirmRegistrationEmail(params: {
	email: string
	code: string
}): Promise<EmailConfirmed> {
	const email = normalizeEmail(params.email)
	const pending = await loadPending(email)

	// Idempotent: a double-submitted form must not burn a second code and must
	// not push the user back a step.
	if (!pending.emailVerifiedAt) {
		await consumeCode({
			purpose: "REGISTRATION",
			destination: email,
			code: params.code,
		})
		await prisma.pendingRegistration.update({
			where: { id: pending.id },
			data: { emailVerifiedAt: new Date() },
		})
	}

	return {
		state: "telegram",
		telegramCode: pending.telegramCode,
		telegramUrl: telegramDeepLink(pending.telegramCode),
	}
}

/**
 * Google sign-up. The address is already proven, so step 2 is skipped - but
 * the row still stops at "telegram", never at "done".
 */
export async function startGoogleRegistration(params: {
	email: string
	googleSub: string
	ip?: string | null
}): Promise<EmailConfirmed> {
	const email = normalizeEmail(params.email)
	const existing = await prisma.user.findFirst({ where: { email }, select: { id: true } })
	if (existing) throw conflict("An account with this email already exists")

	// A random password nobody knows: the account is reachable through Google
	// and through "forgot password", and leaving the column nullable just to
	// express "no password yet" would weaken every query that reads it.
	const passwordHash = await hashPassword(`google:${params.googleSub}:${newToken()}${newToken()}`)
	const expiresAt = pendingExpiry()

	const pending = await prisma.pendingRegistration.upsert({
		where: { email },
		create: {
			email,
			passwordHash,
			emailVerifiedAt: new Date(),
			telegramCode: newToken(),
			googleSub: params.googleSub,
			createdIp: params.ip ?? null,
			expiresAt,
		},
		update: {
			emailVerifiedAt: new Date(),
			googleSub: params.googleSub,
			expiresAt,
		},
	})

	return {
		state: "telegram",
		telegramCode: pending.telegramCode,
		telegramUrl: telegramDeepLink(pending.telegramCode),
	}
}

/**
 * Instant Google account, used only when GOOGLE_REQUIRE_TELEGRAM=false: the
 * address is proven by Google, the operator has waived the phone step. The
 * account gets the same free subscription a Telegram-completed sign-up gets
 * (see `attachTelegram`), the Google link, and a random password nobody knows.
 */
export async function createUserFromGoogle(params: {
	email: string
	googleSub: string
	name?: string | null
}): Promise<import("@prisma/client").User> {
	const email = normalizeEmail(params.email)
	const existing = await prisma.user.findFirst({ where: { email } })
	if (existing) throw conflict("An account with this email already exists")

	const username = await uniqueUsername(email)
	const passwordHash = await hashPassword(`google:${params.googleSub}:${newToken()}${newToken()}`)
	const created = await prisma.user.create({
		data: {
			username,
			email,
			emailVerifiedAt: new Date(),
			passwordHash,
			maxDevices: config.MAX_DEVICES_PER_USER,
			maxSessions: config.MAX_CONCURRENT_SESSIONS,
			identityLinks: {
				create: [
					{
						provider: "GOOGLE",
						providerUserId: params.googleSub,
						providerEmail: email,
						providerName: params.name ?? null,
					},
				],
			},
		},
	})
	// A finished pending row for the same address (Google -> abandoned Telegram
	// step) must not keep the email reserved.
	await prisma.pendingRegistration.deleteMany({ where: { email } }).catch(() => undefined)
	await grantDefaultSubscription(created.id).catch(() => undefined)
	return created
}

export async function registrationStatus(email: string): Promise<{
	state: RegistrationState
	telegramUrl?: string
	username?: string
}> {
	const normalized = normalizeEmail(email)

	const user = await prisma.user.findFirst({
		where: { email: normalized },
		select: { username: true },
	})
	if (user) return { state: "done", username: user.username }

	const pending = await loadPending(normalized)
	if (!pending.emailVerifiedAt) return { state: "email" }
	return { state: "telegram", telegramUrl: telegramDeepLink(pending.telegramCode) }
}

// ----------------------------------------------------------------- step 3 --

/**
 * Start a Telegram re-bind for an account that already exists
 * (Settings -> Account -> "Change Telegram").
 *
 * The token is stored as a verification code so it inherits the 5-minute TTL,
 * the attempt counter and the sweeper. `destination` holds the token itself
 * because unlike an email flow there is no address to send to - the token *is*
 * the address, and the bot has to be able to find the row from it alone.
 */
export async function startTelegramRebind(userId: string): Promise<{
	token: string
	url: string
	expiresAt: Date
}> {
	const token = newToken()
	const issued = await issueCode({
		purpose: "TELEGRAM_LINK",
		destination: token,
		channel: "TELEGRAM",
		userId,
		// The token is the secret and it is already in the deep link, so there is
		// nothing to deliver.
		deliver: false,
	})
	return { token, url: telegramDeepLink(token), expiresAt: issued.expiresAt }
}

export type TelegramAttachOutcome =
	| { ok: true; kind: "registered"; username: string }
	| { ok: true; kind: "relinked"; username: string }
	| {
			ok: false
			reason: "unknown" | "email_pending" | "phone_taken" | "telegram_taken"
	  }

/**
 * The only entry point the bot needs. Takes a token and a *verified* contact,
 * and either finishes a sign-up or re-binds an existing account.
 */
export async function attachTelegram(params: {
	token: string
	telegramId: string
	telegramUsername?: string | null
	phone: string
}): Promise<TelegramAttachOutcome> {
	const token = params.token.trim().toUpperCase()
	const phone = normalizePhone(params.phone)
	if (!token || !phone) return { ok: false, reason: "unknown" }

	// --- re-bind on an existing account ------------------------------------
	const rebind = await prisma.verificationCode.findFirst({
		where: {
			purpose: "TELEGRAM_LINK",
			destination: token,
			consumedAt: null,
			expiresAt: { gt: new Date() },
		},
		orderBy: { createdAt: "desc" },
	})
	if (rebind?.userId) {
		const clash = await prisma.user.findFirst({
			where: { telegramId: params.telegramId, NOT: { id: rebind.userId } },
			select: { id: true },
		})
		if (clash) return { ok: false, reason: "telegram_taken" }

		const phoneClash = await prisma.user.findFirst({
			where: { telegramPhone: phone, NOT: { id: rebind.userId } },
			select: { id: true },
		})
		if (phoneClash) return { ok: false, reason: "phone_taken" }

		const updated = await prisma.user.update({
			where: { id: rebind.userId },
			data: {
				telegramId: params.telegramId,
				telegramUsername: params.telegramUsername ?? null,
				telegramPhone: phone,
				telegramVerifiedAt: new Date(),
			},
			select: { username: true },
		})
		await prisma.verificationCode.update({
			where: { id: rebind.id },
			data: { consumedAt: new Date() },
		})
		await prisma.identityLink.upsert({
			where: {
				provider_providerUserId: {
					provider: "TELEGRAM",
					providerUserId: params.telegramId,
				},
			},
			create: {
				userId: rebind.userId,
				provider: "TELEGRAM",
				providerUserId: params.telegramId,
				providerName: params.telegramUsername ?? null,
				providerPhone: phone,
			},
			update: {
				userId: rebind.userId,
				providerName: params.telegramUsername ?? null,
				providerPhone: phone,
			},
		})
		return { ok: true, kind: "relinked", username: updated.username }
	}

	// --- finish a sign-up ---------------------------------------------------
	const pending = await prisma.pendingRegistration.findUnique({
		where: { telegramCode: token },
	})
	if (!pending || pending.expiresAt.getTime() <= Date.now()) {
		return { ok: false, reason: "unknown" }
	}
	if (!pending.emailVerifiedAt) return { ok: false, reason: "email_pending" }

	const phoneTaken = await prisma.user.findFirst({
		where: { telegramPhone: phone },
		select: { id: true },
	})
	if (phoneTaken) return { ok: false, reason: "phone_taken" }

	const telegramTaken = await prisma.user.findFirst({
		where: { telegramId: params.telegramId },
		select: { id: true },
	})
	if (telegramTaken) return { ok: false, reason: "telegram_taken" }

	const username = await uniqueUsername(pending.email)
	const identityLinks: Prisma.IdentityLinkCreateWithoutUserInput[] = [
		{
			provider: "TELEGRAM",
			providerUserId: params.telegramId,
			providerName: params.telegramUsername ?? null,
			providerPhone: phone,
		},
	]
	if (pending.googleSub) {
		identityLinks.push({
			provider: "GOOGLE",
			providerUserId: pending.googleSub,
			providerEmail: pending.email,
		})
	}

	const created = await prisma.user.create({
		data: {
			username,
			email: pending.email,
			emailVerifiedAt: pending.emailVerifiedAt,
			passwordHash: pending.passwordHash,
			maxDevices: config.MAX_DEVICES_PER_USER,
			maxSessions: config.MAX_CONCURRENT_SESSIONS,
			telegramId: params.telegramId,
			telegramUsername: params.telegramUsername ?? null,
			telegramPhone: phone,
			telegramVerifiedAt: new Date(),
			identityLinks: { create: identityLinks },
		},
		select: { id: true, username: true },
	})
	// Every new account starts on the Free plan, so "connect" works right away
	// instead of answering "No active subscription" until an admin intervenes.
	await grantDefaultSubscription(created.id).catch(() => undefined)

	// The pending row has served its purpose. Deleting it here (rather than
	// leaving it to the sweeper) is what frees the address for the unique index
	// and makes a replayed contact hit "unknown" instead of a second account.
	await prisma.pendingRegistration
		.delete({ where: { id: pending.id } })
		.catch(() => undefined)

	return { ok: true, kind: "registered", username: created.username }
}

/** Housekeeping for the monitor tick. */
export async function sweepExpiredRegistrations(): Promise<number> {
	const result = await prisma.pendingRegistration.deleteMany({
		where: { expiresAt: { lt: new Date() } },
	})
	return result.count
}
