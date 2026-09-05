import type { User } from "@prisma/client"
import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { writeAudit } from "../lib/audit"
import { verifyPassword } from "../lib/crypto"
import {
	badRequest,
	conflict,
	forbidden,
	serviceUnavailable,
	tooManyRequests,
	unauthorized,
} from "../lib/errors"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { config } from "../config"
import { requireRegistrationEnabled } from "../services/serviceControl"
import { latestSubscription, subscriptionPayload, userPayload } from "../services/accountView"
import { refreshUserOrigin } from "../services/geo"
import { googleConfigured, verifyGoogleIdToken } from "../services/googleAuth"
import { startGoogleRegistration, telegramConfigured } from "../services/registration"
import { closeSessionsForDevice } from "../services/sessions"
import { checkLoginThrottle, recordLoginAttempt } from "../services/loginThrottle"
import {
	consumeCode,
	issueCode,
	mailerReady,
	normalizeEmail,
} from "../services/verification"
import {
	issueTokens,
	revokeRefreshTokens,
	rotateRefreshToken,
} from "../services/tokens"

// Login accepts either identity. `identifier` is what the app sends; the
// legacy `username` field is still honoured so an older build keeps working
// through a rollout.
const LoginBody = z
	.object({
		identifier: z.string().trim().min(3).max(190).optional(),
		username: z.string().trim().min(3).max(190).optional(),
		password: z.string().min(8).max(256),
	})
	.refine((body) => Boolean(body.identifier ?? body.username), {
		message: "identifier is required",
	})

const EmailBody = z.object({
	email: z.string().trim().min(5).max(190).email(),
})

const EmailConfirmBody = z.object({
	code: z.string().trim().min(4).max(12),
})

// The nickname is renameable; the public account number never is.
const ChangeUsernameBody = z.object({
	username: z
		.string()
		.trim()
		.min(3)
		.max(32)
		.regex(/^[a-z0-9._@-]+$/i, "Use letters, digits, dot, dash, at-sign or underscore"),
})

const RefreshBody = z.object({
	refreshToken: z.string().min(20).max(512),
})

const GoogleBody = z.object({
	// The ID token Google Identity Services hands to the page.
	credential: z.string().min(20).max(4096),
	mode: z.enum(["login", "register"]).optional(),
})

/** Wording for a refused account: blocked is said out loud, disabled stays neutral. */
export function accountRefusedMessage(status: string): string {
	return status === "BLOCKED"
		? "This account has been blocked. Contact support."
		: "User is disabled"
}

const LogoutBody = z
	.object({
		refreshToken: z.string().min(20).max(512).optional(),
		allDevices: z.boolean().optional(),
	})
	.optional()

export async function authRoutes(app: FastifyInstance): Promise<void> {
	app.post(
		"/api/auth/login",
		// Tighter limit than the global one: login is the main brute-force target.
		{ config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = LoginBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest("Username or email and password are required")
			}
			const { password } = parsed.data
			const identifier = (parsed.data.identifier ?? parsed.data.username ?? "").trim()
			// Throttle on the normalised identity so "Bob" and "bob" share a counter.
			const throttleKey = identifier.toLowerCase()
			const looksLikeEmail = identifier.includes("@")
			const ip = clientIp(request)

			const throttle = await checkLoginThrottle(throttleKey, ip)
			if (throttle.locked) {
				await writeAudit({
					action: "auth.login.throttled",
					ip,
					metadata: { identifier: throttleKey },
				})
				throw tooManyRequests(
					"Too many failed login attempts. Please try again later.",
					throttle.retryAfterSec,
				)
			}

			// Email is matched on its normalised form; a username is matched exactly
			// first, then case-insensitively, so existing accounts keep working while
			// "TestUser" and "testuser" both get in.
			const user = looksLikeEmail
				? await prisma.user.findFirst({ where: { email: normalizeEmail(identifier) } })
				: ((await prisma.user.findUnique({ where: { username: identifier } })) ??
					(await prisma.user.findFirst({
						where: { username: { equals: identifier, mode: "insensitive" } },
					})))
			const passwordOk = user
				? await verifyPassword(user.passwordHash, password)
				: false

			if (!user || !passwordOk) {
				await recordLoginAttempt(throttleKey, ip, false)
				await writeAudit({
					action: "auth.login.failed",
					userId: user?.id ?? null,
					ip,
					metadata: { identifier: throttleKey },
				})
				// Same message for unknown account and wrong password (no enumeration).
				throw unauthorized("Invalid username or password")
			}

			if (user.status !== "ACTIVE") {
				await recordLoginAttempt(throttleKey, ip, false)
				await writeAudit({ action: "auth.login.disabled_user", userId: user.id, ip })
				throw forbidden(accountRefusedMessage(user.status))
			}

			await recordLoginAttempt(throttleKey, ip, true)
			const tokens = await issueTokens(app, user, null)
			await writeAudit({ action: "auth.login.success", userId: user.id, ip })

			// Approximate origin for the map marker: country/region only, resolved
			// from this request's IP. Fired without await so a slow provider cannot
			// delay the login, and it never throws.
			void refreshUserOrigin({
				userId: user.id,
				ip,
				knownCountryCode: user.lastCountryCode,
				geoUpdatedAt: user.geoUpdatedAt,
			})

			const subscription = await latestSubscription(user.id)

			return reply.send({
				tokenType: "Bearer",
				accessToken: tokens.accessToken,
				expiresIn: tokens.accessTokenExpiresInSec,
				refreshToken: tokens.refreshToken,
				refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
				user: userPayload(user),
				subscription: subscriptionPayload(subscription),
			})
		},
	)

	/**
	 * "Continue with Google" (website). The browser posts the ID token that
	 * Google Identity Services produced; we verify it against Google's keys and
	 * then, in order:
	 *
	 *   1. an existing Google link -> sign that account in;
	 *   2. an account with the same (verified) email -> link Google to it and
	 *      sign in, so "I registered with a password, now I press Google" just
	 *      works and never creates a duplicate;
	 *   3. nobody -> start a registration. The address is already proven, so the
	 *      code step is skipped; the Telegram contact step still applies unless
	 *      GOOGLE_REQUIRE_TELEGRAM=false, in which case the account is created
	 *      right here and signed in.
	 */
	app.post(
		"/api/auth/google",
		{ config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
		async (request, reply) => {
			if (!googleConfigured()) {
				throw serviceUnavailable("Google sign-in is not enabled on this server")
			}
			const parsed = GoogleBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("A Google credential is required")
			const ip = clientIp(request)

			const identity = await verifyGoogleIdToken(parsed.data.credential)
			if (!identity.emailVerified) {
				throw badRequest("Google reports this email as unverified")
			}

			const signIn = async (user: User) => {
				if (user.status !== "ACTIVE") throw forbidden(accountRefusedMessage(user.status))
				const tokens = await issueTokens(app, user, null)
				void refreshUserOrigin({
					userId: user.id,
					ip,
					knownCountryCode: user.lastCountryCode,
					geoUpdatedAt: user.geoUpdatedAt,
				})
				const subscription = await latestSubscription(user.id)
				return reply.send({
					outcome: "signed_in",
					tokenType: "Bearer",
					accessToken: tokens.accessToken,
					expiresIn: tokens.accessTokenExpiresInSec,
					refreshToken: tokens.refreshToken,
					refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
					user: userPayload(user),
					subscription: subscriptionPayload(subscription),
				})
			}

			// 1. Already linked.
			const link = await prisma.identityLink.findUnique({
				where: { provider_providerUserId: { provider: "GOOGLE", providerUserId: identity.sub } },
				include: { user: true },
			})
			const linked = link?.user ?? null
			if (linked) {
				await writeAudit({ action: "auth.login.google", userId: linked.id, ip })
				return signIn(linked)
			}

			// 2. Same email -> link and sign in.
			const byEmail = await prisma.user.findFirst({
				where: { email: normalizeEmail(identity.email) },
			})
			if (byEmail) {
				await prisma.identityLink.create({
					data: {
						userId: byEmail.id,
						provider: "GOOGLE",
						providerUserId: identity.sub,
						providerEmail: identity.email,
						providerName: identity.name,
					},
				})
				// Google vouched for the address; a pending "verify your email" nag
				// is now pointless.
				const user = byEmail.emailVerifiedAt
					? byEmail
					: await prisma.user.update({
							where: { id: byEmail.id },
							data: { emailVerifiedAt: new Date() },
						})
				await writeAudit({
					action: "auth.google.linked",
					userId: user.id,
					ip,
					metadata: { email: identity.email },
				})
				return signIn(user)
			}

			// 3. New person.
			await requireRegistrationEnabled()
			if (config.GOOGLE_REQUIRE_TELEGRAM) {
				if (!telegramConfigured()) throw serviceUnavailable("Sign-up is temporarily unavailable")
				const started = await startGoogleRegistration({
					email: identity.email,
					googleSub: identity.sub,
					ip,
				})
				await writeAudit({
					action: "auth.register.google_started",
					ip,
					metadata: { email: identity.email },
				})
				return reply.send({
					outcome: "registration",
					state: started.state,
					email: identity.email,
					telegramUrl: started.telegramUrl,
					telegramCode: started.telegramCode,
				})
			}

			// Instant account: Google proved the address, the operator waived Telegram.
			const { createUserFromGoogle } = await import("../services/registration")
			const created = await createUserFromGoogle({
				email: identity.email,
				googleSub: identity.sub,
				name: identity.name,
			})
			await writeAudit({
				action: "auth.register.google_completed",
				userId: created.id,
				ip,
				metadata: { email: identity.email },
			})
			return signIn(created)
		},
	)

	app.post(
		"/api/auth/refresh",
		{ config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = RefreshBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("refreshToken is required")

			const tokens = await rotateRefreshToken(app, parsed.data.refreshToken)
			return reply.send({
				tokenType: "Bearer",
				accessToken: tokens.accessToken,
				expiresIn: tokens.accessTokenExpiresInSec,
				refreshToken: tokens.refreshToken,
				refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
				deviceId: tokens.deviceId,
			})
		},
	)

	app.post(
		"/api/auth/logout",
		{ preHandler: requireUser },
		async (request, reply) => {
			const { user, device } = getAuthUser(request)
			const parsed = LogoutBody.safeParse(request.body ?? {})
			const allDevices = parsed.success ? parsed.data?.allDevices === true : false

			const revoked = await revokeRefreshTokens({
				userId: user.id,
				...(allDevices ? {} : { deviceId: device?.id ?? null }),
			})
			await writeAudit({
				action: "auth.logout",
				userId: user.id,
				deviceId: device?.id ?? null,
				ip: clientIp(request),
				metadata: { allDevices, revokedTokens: revoked },
			})
			// Devices are no longer kept as tombstones. Signing out deletes the
			// row, so an account cannot accumulate dozens of dead entries and the
			// device limit always reflects machines that are actually signed in.
			// Sessions and refresh tokens cascade off the device, so nothing can
			// outlive the record.
			let removedDevices = 0
			try {
				if (allDevices) {
					const wiped = await prisma.device.deleteMany({
						where: { userId: user.id },
					})
					removedDevices = wiped.count
				} else if (device) {
					// Close the tunnel while the row still exists, so the node is
					// told to drop the peer before the record disappears.
					await closeSessionsForDevice(device.id, "device_revoked")
					await prisma.device.delete({ where: { id: device.id } })
					removedDevices = 1
				}
			} catch (err) {
				// A foreign key outside this transaction can refuse the delete.
				// Falling back to REVOKED still leaves the tokens useless, which is
				// the part that matters for security.
				request.log.warn({ err }, "logout could not delete device rows")
				const marked = await prisma.device.updateMany({
					where: allDevices ? { userId: user.id } : { id: device?.id ?? "" },
					data: { status: "REVOKED", revokedAt: new Date() },
				})
				removedDevices = marked.count
			}

			return reply.send({ ok: true, revokedTokens: revoked, removedDevices })
		},
	)

	// Rename the account nickname. `publicId` stays untouched — it is the stable
	// handle for support, search and bans, and the database rejects changes to it.
	app.post(
		"/api/auth/username",
		{
			preHandler: requireUser,
			// Renaming is rare; a tight limit stops username-squatting sweeps.
			config: { rateLimit: { max: 5, timeWindow: "1 hour" } },
		},
		async (request, reply) => {
			const { user } = getAuthUser(request)
			const parsed = ChangeUsernameBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest(
					parsed.error.issues[0]?.message ?? "Invalid username",
				)
			}
			const nextUsername = parsed.data.username
			const ip = clientIp(request)

			if (nextUsername === user.username) {
				return reply.send({
					user: {
						id: user.id,
						publicId: user.publicId,
						username: user.username,
					},
					changed: false,
				})
			}

			const taken = await prisma.user.findFirst({
				where: { username: nextUsername, NOT: { id: user.id } },
				select: { id: true },
			})
			if (taken) throw conflict("This username is already taken")

			const updated = await prisma.user.update({
				where: { id: user.id },
				data: { username: nextUsername },
				select: { id: true, publicId: true, username: true },
			})

			await writeAudit({
				action: "auth.username.changed",
				userId: user.id,
				ip,
				metadata: { from: user.username, to: nextUsername },
			})

			return reply.send({ user: updated, changed: true })
		},
	)

	// ------------------------------- email ----------------------------------
	// Email is a *second* login identity, never the account itself: the UUID
	// primary key and the public account number are untouched by these routes.
	//
	// A new address only replaces the old one after the owner proves control of
	// it with a code, so a stolen access token cannot quietly redirect account
	// recovery to an attacker's mailbox.
	app.post(
		"/api/auth/email",
		{
			preHandler: requireUser,
			config: { rateLimit: { max: 5, timeWindow: "1 hour" } },
		},
		async (request, reply) => {
			const { user } = getAuthUser(request)
			// Better an honest 503 than issuing codes that can never arrive.
			if (!mailerReady()) {
				throw serviceUnavailable("Email confirmation is not available yet")
			}

			const parsed = EmailBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("A valid email address is required")
			const email = normalizeEmail(parsed.data.email)
			const ip = clientIp(request)

			const taken = await prisma.user.findFirst({
				where: { email, NOT: { id: user.id } },
				select: { id: true },
			})
			if (taken) throw conflict("This email is already in use")

			const issued = await issueCode({
				userId: user.id,
				purpose: "EMAIL_CHANGE",
				destination: email,
				ip,
			})
			await writeAudit({
				action: "auth.email.change_requested",
				userId: user.id,
				ip,
				metadata: { destination: email },
			})

			return reply.send({
				pendingEmail: email,
				expiresAt: issued.expiresAt.toISOString(),
				delivered: issued.delivered,
			})
		},
	)

	app.post(
		"/api/auth/email/confirm",
		{
			preHandler: requireUser,
			config: { rateLimit: { max: 10, timeWindow: "1 hour" } },
		},
		async (request, reply) => {
			const { user } = getAuthUser(request)
			const parsed = EmailConfirmBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("A confirmation code is required")
			const ip = clientIp(request)

			// The address lives on the code record, so the client cannot swap it
			// between request and confirmation.
			const record = await consumeCode({
				userId: user.id,
				purpose: "EMAIL_CHANGE",
				code: parsed.data.code,
			})

			const updated = await prisma.user.update({
				where: { id: user.id },
				data: { email: record.destination, emailVerifiedAt: new Date() },
				select: { id: true, publicId: true, username: true, email: true },
			})
			await writeAudit({
				action: "auth.email.changed",
				userId: user.id,
				ip,
				metadata: { destination: record.destination },
			})

			return reply.send({ user: { ...updated, emailVerified: true } })
		},
	)

	app.get("/api/auth/me", { preHandler: requireUser }, async (request, reply) => {
		const { user, device } = getAuthUser(request)
		const [deviceCount, subscription] = await Promise.all([
			prisma.device.count({ where: { userId: user.id, status: "ACTIVE" } }),
			latestSubscription(user.id),
		])
		return reply.send({
			user: userPayload(user),
			activeDevices: deviceCount,
			currentDeviceId: device?.id ?? null,
			subscription: subscriptionPayload(subscription),
		})
	})
}
