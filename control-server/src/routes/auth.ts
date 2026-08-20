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
import { refreshUserOrigin } from "../services/geo"
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
				throw forbidden("User is disabled")
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

			const subscription = await prisma.subscription.findFirst({
				where: { userId: user.id },
				orderBy: { expiresAt: "desc" },
			})

			return reply.send({
				tokenType: "Bearer",
				accessToken: tokens.accessToken,
				expiresIn: tokens.accessTokenExpiresInSec,
				refreshToken: tokens.refreshToken,
				refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
				user: {
					id: user.id,
					publicId: user.publicId,
					username: user.username,
					email: user.email,
					emailVerified: user.emailVerifiedAt !== null,
					isAdmin: user.isAdmin,
					status: user.status,
					maxDevices: user.maxDevices,
					maxConcurrentSessions: user.maxSessions,
					origin: {
						country: user.lastCountry,
						countryCode: user.lastCountryCode,
						region: user.lastRegion,
					},
				},
				subscription: subscription
					? {
							status: subscription.status,
							expiresAt: subscription.expiresAt.toISOString(),
						}
					: null,
			})
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
			return reply.send({ ok: true, revokedTokens: revoked })
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
			prisma.subscription.findFirst({
				where: { userId: user.id },
				orderBy: { expiresAt: "desc" },
			}),
		])
		return reply.send({
			user: {
				id: user.id,
				publicId: user.publicId,
				username: user.username,
				email: user.email,
				emailVerified: user.emailVerifiedAt !== null,
				status: user.status,
				isAdmin: user.isAdmin,
				maxDevices: user.maxDevices,
				maxConcurrentSessions: user.maxSessions,
				createdAt: user.createdAt.toISOString(),
				// Country/region only — the app draws the marker at a country centre.
				origin: {
					country: user.lastCountry,
					countryCode: user.lastCountryCode,
					region: user.lastRegion,
				},
			},
			activeDevices: deviceCount,
			currentDeviceId: device?.id ?? null,
			subscription: subscription
				? {
						status: subscription.status,
						expiresAt: subscription.expiresAt.toISOString(),
					}
				: null,
		})
	})
}
