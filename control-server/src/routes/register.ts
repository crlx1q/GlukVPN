import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { hashPassword, verifyPassword } from "../lib/crypto"
import { badRequest, forbidden, serviceUnavailable } from "../lib/errors"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { verifyCaptcha } from "../services/captcha"
import {
	confirmRegistrationEmail,
	registrationStatus,
	resendRegistrationCode,
	startRegistration,
	startTelegramRebind,
	telegramConfigured,
	telegramDeepLink,
} from "../services/registration"
import { revokeRefreshTokens } from "../services/tokens"
import {
	consumeCode,
	issueCode,
	mailerReady,
	normalizeEmail,
} from "../services/verification"

/**
 * Sign-up, password recovery and the account-security actions that go with
 * them (change password, re-bind Telegram).
 *
 * The shape of every flow here is the same on purpose: an action that costs
 * the server real work is gated by a captcha, the secret is a short-lived
 * 6-digit code, and the answer to "does this account exist?" is always the
 * same whether it does or not. Account enumeration is the one thing a
 * recovery flow leaks by default, and it is worth spending a little UX
 * awkwardness to avoid.
 */

const StartBody = z.object({
	email: z.string().trim().min(5).max(190).email(),
	password: z.string().min(8).max(256),
	// The site checks the repeat field too, but a client-side check is a
	// convenience, not a rule - the rule lives here.
	passwordConfirm: z.string().min(8).max(256).optional(),
	captchaToken: z.string().max(4096).optional(),
})

const EmailOnlyBody = z.object({
	email: z.string().trim().min(5).max(190).email(),
})

const VerifyEmailBody = z.object({
	email: z.string().trim().min(5).max(190).email(),
	code: z.string().trim().min(4).max(12),
})

const ForgotBody = z.object({
	// Email or username: the same field the login form uses.
	identifier: z.string().trim().min(3).max(190),
	channel: z.enum(["email", "telegram"]).optional(),
	captchaToken: z.string().max(4096).optional(),
})

const ResetBody = z.object({
	identifier: z.string().trim().min(3).max(190),
	code: z.string().trim().min(4).max(12),
	password: z.string().min(8).max(256),
})

const ChangePasswordBody = z.object({
	currentPassword: z.string().min(8).max(256),
	password: z.string().min(8).max(256),
})

/** Email or username, exactly like /api/auth/login resolves it. */
async function findByIdentifier(identifier: string) {
	const trimmed = identifier.trim()
	if (trimmed.includes("@")) {
		return prisma.user.findFirst({ where: { email: normalizeEmail(trimmed) } })
	}
	return (
		(await prisma.user.findUnique({ where: { username: trimmed } })) ??
		(await prisma.user.findFirst({
			where: { username: { equals: trimmed, mode: "insensitive" } },
		}))
	)
}

export async function registrationRoutes(app: FastifyInstance): Promise<void> {
	// ---------------------------------------------------------------- config
	// One place for every client to learn what this deployment supports, so the
	// site, the app and the extension never hard-code a feature flag.
	app.get("/api/auth/config", async (_request, reply) =>
		reply.send({
			selfRegistration: config.SELF_REGISTRATION_ENABLED,
			emailDelivery: mailerReady(),
			telegram: {
				enabled: telegramConfigured(),
				username: config.TELEGRAM_BOT_USERNAME.trim().replace(/^@/, ""),
			},
			// The site renders the Google button only when a client id exists; the
			// id is public by design (it is embedded in every Google sign-in page).
			google: {
				enabled: config.googleEnabled,
				clientId: config.googleEnabled ? config.GOOGLE_CLIENT_ID.trim() : null,
				requireTelegram: config.GOOGLE_REQUIRE_TELEGRAM,
			},
			billing: {
				enabled: config.billingEnabled,
				provider: config.billingEnabled ? config.BILLING_PROVIDER : null,
				currency: config.BILLING_CURRENCY,
			},
			codeTtlMinutes: config.VERIFICATION_CODE_TTL_MIN,
			passwordMinLength: 8,
		}),
	)

	// ------------------------------------------------------------- sign-up --

	app.post(
		"/api/auth/register/start",
		// Every start costs an Argon2 hash and an SMTP connection. Three a minute
		// is generous for a human and useless for a script.
		{ config: { rateLimit: { max: 3, timeWindow: "1 minute" } } },
		async (request, reply) => {
			if (!config.SELF_REGISTRATION_ENABLED) {
				throw forbidden("Sign-up is closed on this server")
			}
			const parsed = StartBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest("A valid email and a password of at least 8 characters are required")
			}
			const { email, password, passwordConfirm, captchaToken } = parsed.data
			if (passwordConfirm !== undefined && passwordConfirm !== password) {
				throw badRequest("The two passwords do not match")
			}

			const ip = clientIp(request)
			const captcha = await verifyCaptcha(captchaToken, ip)
			if (!captcha.ok) throw badRequest("Please complete the anti-bot check")

			// Telegram is a required step, so starting a sign-up that can never
			// finish would be worse than refusing it.
			if (!telegramConfigured()) {
				throw serviceUnavailable("Sign-up is temporarily unavailable")
			}

			const started = await startRegistration({ email, password, ip })
			await writeAudit({
				action: "auth.register.started",
				ip,
				metadata: { email: started.email, captcha: captcha.reason },
			})

			return reply.send({
				state: started.state,
				email: started.email,
				delivered: started.delivered,
				codeExpiresAt: started.codeExpiresAt.toISOString(),
				expiresAt: started.expiresAt.toISOString(),
			})
		},
	)

	app.post(
		"/api/auth/register/resend",
		{ config: { rateLimit: { max: 3, timeWindow: "5 minutes" } } },
		async (request, reply) => {
			const parsed = EmailOnlyBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("A valid email address is required")

			const issued = await resendRegistrationCode({
				email: parsed.data.email,
				ip: clientIp(request),
			})
			return reply.send({
				delivered: issued.delivered,
				codeExpiresAt: issued.codeExpiresAt.toISOString(),
			})
		},
	)

	app.post(
		"/api/auth/register/verify-email",
		{ config: { rateLimit: { max: 10, timeWindow: "5 minutes" } } },
		async (request, reply) => {
			const parsed = VerifyEmailBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("A confirmation code is required")

			const confirmed = await confirmRegistrationEmail({
				email: parsed.data.email,
				code: parsed.data.code,
			})
			await writeAudit({
				action: "auth.register.email_confirmed",
				ip: clientIp(request),
				metadata: { email: normalizeEmail(parsed.data.email) },
			})

			return reply.send(confirmed)
		},
	)

	// The site polls this while the user is off in Telegram. It is the only way
	// the browser can learn that the bot finished the job.
	app.get(
		"/api/auth/register/status",
		{ config: { rateLimit: { max: 120, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const query = z
				.object({ email: z.string().trim().min(5).max(190).email() })
				.safeParse(request.query)
			if (!query.success) throw badRequest("A valid email address is required")
			return reply.send(await registrationStatus(query.data.email))
		},
	)

	// ------------------------------------------------------ password reset --

	app.post(
		"/api/auth/password/forgot",
		{ config: { rateLimit: { max: 5, timeWindow: "15 minutes" } } },
		async (request, reply) => {
			const parsed = ForgotBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("Enter your email or username")
			const ip = clientIp(request)

			const captcha = await verifyCaptcha(parsed.data.captchaToken, ip)
			if (!captcha.ok) throw badRequest("Please complete the anti-bot check")

			const user = await findByIdentifier(parsed.data.identifier)

			// Always the same answer. "No such account" here would turn this
			// endpoint into a free membership oracle for any address or nickname.
			const generic = {
				ok: true,
				message: "If the account exists, a code has been sent.",
			}

			if (!user || user.status !== "ACTIVE") return reply.send(generic)

			// Telegram when it is bound and asked for (or when there is no mail
			// transport); email otherwise.
			const wantsTelegram =
				parsed.data.channel === "telegram" || (!mailerReady() && Boolean(user.telegramId))
			const useTelegram = wantsTelegram && Boolean(user.telegramId)

			if (!useTelegram && !user.email) return reply.send(generic)

			await issueCode({
				userId: user.id,
				purpose: "PASSWORD_RESET",
				channel: useTelegram ? "TELEGRAM" : "EMAIL",
				destination: useTelegram ? (user.telegramId as string) : (user.email as string),
				ip,
			})
			await writeAudit({
				action: "auth.password.reset_requested",
				userId: user.id,
				ip,
				metadata: { channel: useTelegram ? "telegram" : "email" },
			})

			return reply.send({
				...generic,
				// Safe to reveal: the caller already had to name the account, and
				// the UI has to know which inbox to point at.
				channel: useTelegram ? "telegram" : "email",
			})
		},
	)

	app.post(
		"/api/auth/password/reset",
		{ config: { rateLimit: { max: 10, timeWindow: "15 minutes" } } },
		async (request, reply) => {
			const parsed = ResetBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest("A code and a new password of at least 8 characters are required")
			}
			const ip = clientIp(request)

			const user = await findByIdentifier(parsed.data.identifier)
			// Same wording the code layer uses for a wrong or expired code, so a
			// bad identifier is indistinguishable from a bad code.
			if (!user) throw badRequest("This code is no longer valid. Request a new one.")

			await consumeCode({
				userId: user.id,
				purpose: "PASSWORD_RESET",
				code: parsed.data.code,
			})

			await prisma.user.update({
				where: { id: user.id },
				data: { passwordHash: await hashPassword(parsed.data.password) },
			})
			// A reset is the response to "someone else may have my password", so
			// every existing session has to die with it.
			const revoked = await revokeRefreshTokens({ userId: user.id })
			await writeAudit({
				action: "auth.password.reset",
				userId: user.id,
				ip,
				metadata: { revokedTokens: revoked },
			})

			return reply.send({ ok: true, revokedTokens: revoked })
		},
	)

	// --------------------------------------------------- account security ---

	app.post(
		"/api/auth/password",
		{
			preHandler: requireUser,
			config: { rateLimit: { max: 5, timeWindow: "15 minutes" } },
		},
		async (request, reply) => {
			const { user, device } = getAuthUser(request)
			const parsed = ChangePasswordBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest("The new password must be at least 8 characters")
			}

			// Holding an access token is not the same as knowing the password; a
			// borrowed unlocked laptop must not be enough to take the account.
			const ok = await verifyPassword(user.passwordHash, parsed.data.currentPassword)
			if (!ok) throw badRequest("The current password is incorrect")

			await prisma.user.update({
				where: { id: user.id },
				data: { passwordHash: await hashPassword(parsed.data.password) },
			})
			// Keep this device signed in, drop everything else.
			const revoked = await revokeRefreshTokens({ userId: user.id })
			await writeAudit({
				action: "auth.password.changed",
				userId: user.id,
				deviceId: device?.id ?? null,
				ip: clientIp(request),
				metadata: { revokedTokens: revoked },
			})

			return reply.send({ ok: true, revokedTokens: revoked })
		},
	)

	// Re-bind Telegram from Settings. Returns a fresh deep link; the bot does
	// the rest, exactly as it does during sign-up.
	app.post(
		"/api/auth/telegram/link",
		{
			preHandler: requireUser,
			config: { rateLimit: { max: 5, timeWindow: "15 minutes" } },
		},
		async (request, reply) => {
			const { user } = getAuthUser(request)
			if (!telegramConfigured()) {
				throw serviceUnavailable("Telegram is not available on this server")
			}

			const started = await startTelegramRebind(user.id)
			await writeAudit({
				action: "auth.telegram.link_requested",
				userId: user.id,
				ip: clientIp(request),
			})

			return reply.send({
				url: started.url,
				// A fallback for anyone who has to type it into the bot by hand.
				code: started.token,
				expiresAt: started.expiresAt.toISOString(),
			})
		},
	)

	app.get("/api/auth/telegram", { preHandler: requireUser }, async (request, reply) => {
		const { user } = getAuthUser(request)
		return reply.send({
			linked: Boolean(user.telegramId),
			username: user.telegramUsername,
			// Last four digits only. The full number is a stronger identifier than
			// anything else on the account and never needs to be echoed back.
			phoneTail: user.telegramPhone ? user.telegramPhone.slice(-4) : null,
			verifiedAt: user.telegramVerifiedAt?.toISOString() ?? null,
			botUrl: telegramConfigured() ? telegramDeepLink("") : null,
		})
	})
}
