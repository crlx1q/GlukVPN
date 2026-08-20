import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { writeAudit } from "../lib/audit"
import { verifyPassword } from "../lib/crypto"
import { badRequest, conflict, forbidden, tooManyRequests, unauthorized } from "../lib/errors"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { checkLoginThrottle, recordLoginAttempt } from "../services/loginThrottle"
import {
	issueTokens,
	revokeRefreshTokens,
	rotateRefreshToken,
} from "../services/tokens"

const LoginBody = z.object({
	username: z.string().trim().min(3).max(64),
	password: z.string().min(8).max(256),
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
			if (!parsed.success) throw badRequest("username and password are required")
			const { username, password } = parsed.data
			const ip = clientIp(request)

			const throttle = await checkLoginThrottle(username, ip)
			if (throttle.locked) {
				await writeAudit({ action: "auth.login.throttled", ip, metadata: { username } })
				throw tooManyRequests(
					"Too many failed login attempts. Please try again later.",
					throttle.retryAfterSec,
				)
			}

			const user = await prisma.user.findUnique({ where: { username } })
			const passwordOk = user
				? await verifyPassword(user.passwordHash, password)
				: false

			if (!user || !passwordOk) {
				await recordLoginAttempt(username, ip, false)
				await writeAudit({
					action: "auth.login.failed",
					userId: user?.id ?? null,
					ip,
					metadata: { username },
				})
				// Same message for unknown user and wrong password (no user enumeration).
				throw unauthorized("Invalid username or password")
			}

			if (user.status !== "ACTIVE") {
				await recordLoginAttempt(username, ip, false)
				await writeAudit({ action: "auth.login.disabled_user", userId: user.id, ip })
				throw forbidden("User is disabled")
			}

			await recordLoginAttempt(username, ip, true)
			const tokens = await issueTokens(app, user, null)
			await writeAudit({ action: "auth.login.success", userId: user.id, ip })

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
					isAdmin: user.isAdmin,
					status: user.status,
					maxDevices: user.maxDevices,
					maxConcurrentSessions: user.maxSessions,
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
				status: user.status,
				isAdmin: user.isAdmin,
				maxDevices: user.maxDevices,
				maxConcurrentSessions: user.maxSessions,
				createdAt: user.createdAt.toISOString(),
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
