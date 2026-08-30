import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { badRequest, conflict, notFound } from "../lib/errors"
import { wireGuardKeySchema } from "../lib/wg"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { closeSessionsForDevice, findLiveSessionForDevice } from "../services/sessions"
import { issueTokens, revokeRefreshTokens } from "../services/tokens"

const RegisterBody = z.object({
	deviceName: z.string().trim().min(1).max(64),
	// Only the PUBLIC key is ever accepted. The private key stays on the phone.
	publicKey: wireGuardKeySchema,
	platform: z.string().trim().max(32).optional(),
})

const IdParams = z.object({ id: z.string().uuid("Invalid device id") })

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
	app.post(
		"/api/devices/register",
		{ preHandler: requireUser, config: { rateLimit: { max: 20, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = RegisterBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest("Invalid device payload", parsed.error.flatten().fieldErrors)
			}
			const { user } = getAuthUser(request)
			const { deviceName, publicKey, platform } = parsed.data
			const ip = clientIp(request)

			// A node's own key must never be accepted as a device key.
			const nodeWithSameKey = await prisma.vpnNode.findFirst({
				where: { wireguardPublicKey: publicKey },
				select: { id: true },
			})
			if (nodeWithSameKey) throw badRequest("This public key belongs to a VPN node")

			const existing = await prisma.device.findUnique({ where: { publicKey } })
			// A key still never moves between accounts. But refusing the owner's
			// *own* revoked key was a dead end: clients keep their keypair for the
			// life of the install, so once every device had been revoked the account
			// could never register again - it kept seeing "already registered" while
			// the UI honestly reported "0 of 3 devices". Re-enrolling your own key is
			// now an ordinary re-activation, still bounded by the device limit.
			if (existing && existing.userId !== user.id) {
				throw conflict("This public key is already registered")
			}

			const reactivating = existing !== null && existing.status !== "ACTIVE"
			const maxDevices = Math.min(user.maxDevices, config.MAX_DEVICES_PER_USER)
			// A brand-new key and a returning revoked key both take up a slot.
			if (!existing || reactivating) {
				const activeDevices = await prisma.device.count({
					where: {
						userId: user.id,
						status: "ACTIVE",
						...(existing ? { NOT: { id: existing.id } } : {}),
					},
				})
				if (activeDevices >= maxDevices) {
					throw conflict(
						`Device limit reached (${maxDevices}). Revoke another device first.`,
					)
				}
			}

			const device = existing
				? await prisma.device.update({
						where: { id: existing.id },
						data: {
							deviceName,
							platform: platform ?? existing.platform,
							lastSeen: new Date(),
							...(reactivating ? { status: "ACTIVE", revokedAt: null } : {}),
						},
					})
				: await prisma.device.create({
						data: {
							userId: user.id,
							deviceName,
							publicKey,
							platform: platform ?? null,
							lastSeen: new Date(),
						},
					})

			// Device-scoped tokens: /api/vpn/* accepts only these.
			const tokens = await issueTokens(app, user, device)
			await writeAudit({
				action: existing
					? reactivating
						? "device.reactivate"
						: "device.reregister"
					: "device.register",
				userId: user.id,
				deviceId: device.id,
				ip,
				metadata: { deviceName, platform: platform ?? null },
			})

			return reply.code(existing ? 200 : 201).send({
				device: {
					id: device.id,
					deviceName: device.deviceName,
					platform: device.platform,
					status: device.status,
					createdAt: device.createdAt.toISOString(),
				},
				maxDevices,
				tokenType: "Bearer",
				accessToken: tokens.accessToken,
				expiresIn: tokens.accessTokenExpiresInSec,
				refreshToken: tokens.refreshToken,
				refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
			})
		},
	)

	app.get("/api/devices", { preHandler: requireUser }, async (request, reply) => {
		const { user, device: currentDevice } = getAuthUser(request)
		const devices = await prisma.device.findMany({
			where: { userId: user.id },
			orderBy: [{ status: "asc" }, { createdAt: "desc" }],
		})

		const items = await Promise.all(
			devices.map(async (device) => {
				const live = await findLiveSessionForDevice(device.id)
				return {
					id: device.id,
					deviceName: device.deviceName,
					platform: device.platform,
					status: device.status,
					createdAt: device.createdAt.toISOString(),
					lastSeen: device.lastSeen?.toISOString() ?? null,
					isCurrent: currentDevice?.id === device.id,
					// Public keys are not secret, but there is no reason to expose them here.
					connected: live !== null,
					connectedNode: live ? { id: live.node.id, name: live.node.name } : null,
				}
			}),
		)

		return reply.send({
			devices: items,
			maxDevices: Math.min(user.maxDevices, config.MAX_DEVICES_PER_USER),
		})
	})

	// Self-service revoke: closes the session, drops the peer, kills refresh tokens.
	app.delete("/api/devices/:id", { preHandler: requireUser }, async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid device id")
		const { user } = getAuthUser(request)

		const device = await prisma.device.findUnique({ where: { id: parsed.data.id } })
		if (!device || device.userId !== user.id) throw notFound("Device not found")

		if (device.status === "REVOKED") {
			return reply.send({ ok: true, alreadyRevoked: true, closedSessions: 0 })
		}

		const closedSessions = await closeSessionsForDevice(device.id, "device_revoked")
		await prisma.device.update({
			where: { id: device.id },
			data: { status: "REVOKED", revokedAt: new Date() },
		})
		const revokedTokens = await revokeRefreshTokens({
			userId: user.id,
			deviceId: device.id,
		})

		await writeAudit({
			action: "device.revoke",
			userId: user.id,
			deviceId: device.id,
			ip: clientIp(request),
			metadata: { by: "user", closedSessions, revokedTokens },
		})
		return reply.send({ ok: true, closedSessions, revokedTokens })
	})
}
