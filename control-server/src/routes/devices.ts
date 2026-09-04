import { randomUUID } from "node:crypto"
import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { writeAudit } from "../lib/audit"
import { deviceLimitReached, effectiveDeviceLimit } from "../lib/deviceLimit"
import { badRequest, conflict, notFound } from "../lib/errors"
import { wireGuardKeySchema } from "../lib/wg"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { requestPolicySync } from "../services/policy"
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
			const maxDevices = effectiveDeviceLimit(user)
			// A brand-new key and a returning revoked key both take up a slot.
			if (!existing || reactivating) {
				// ROUND 28: the list, not just the count. The client turns this into
				// the "Device limit" picker, so the 409 has to carry the rows it will
				// show - a bare count could only ever become a dead end, which is
				// precisely what all three clients were doing with it.
				const active = await prisma.device.findMany({
					where: {
						userId: user.id,
						status: "ACTIVE",
						...(existing ? { NOT: { id: existing.id } } : {}),
					},
					// Most recently used first: the device you are least likely to want
					// to sign out ends up at the top, and the stale one at the bottom.
					orderBy: [{ lastSeen: "desc" }, { createdAt: "desc" }],
					select: { id: true, deviceName: true, platform: true, lastSeen: true },
				})
				if (active.length >= maxDevices) {
					const devices = await Promise.all(
						active.map(async (candidate) => ({
							id: candidate.id,
							deviceName: candidate.deviceName,
							platform: candidate.platform,
							lastSeen: candidate.lastSeen?.toISOString() ?? null,
							connected: (await findLiveSessionForDevice(candidate.id)) !== null,
						})),
					)
					throw deviceLimitReached({
						maxDevices,
						activeDevices: active.length,
						devices,
					})
				}
			}

			const device = existing
				? await prisma.device.update({
						where: { id: existing.id },
						data: {
							deviceName,
							platform: platform ?? existing.platform,
							lastSeen: new Date(),
							// Rows from before the column get their personal credential here.
							...(existing.vlessUuid ? {} : { vlessUuid: randomUUID() }),
							...(reactivating ? { status: "ACTIVE", revokedAt: null } : {}),
						},
					})
				: await prisma.device.create({
						data: {
							userId: user.id,
							deviceName,
							publicKey,
							// One VLESS credential per device, minted here and never shared.
							vlessUuid: randomUUID(),
							platform: platform ?? null,
							lastSeen: new Date(),
						},
					})

			// A new or re-activated credential has to reach sing-box on the nodes
			// before this device tries to connect through it.
			if (!existing || reactivating || !existing.vlessUuid) {
				await requestPolicySync().catch(() => 0)
			}

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
			maxDevices: effectiveDeviceLimit(user),
		})
	})

	// Sign a device out and REMOVE it.
	//
	// ROUND 6: this used to flip the row to REVOKED and keep it forever, which is
	// how one account ended up showing 48 devices - every reinstall left a
	// tombstone the user could not clear, and the UI had to explain the
	// difference between "revoked" and "gone". A device is a session, not a
	// permanent asset: signing it out deletes it, and the next sign-in registers
	// it again. Sessions and refresh tokens both cascade from the row, so the
	// delete cannot leave a live tunnel or a usable token behind.
	app.delete("/api/devices/:id", { preHandler: requireUser }, async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid device id")
		const { user } = getAuthUser(request)

		const device = await prisma.device.findUnique({ where: { id: parsed.data.id } })
		// Already gone is a success: the caller wanted it off the list.
		if (!device) return reply.send({ ok: true, alreadyRemoved: true, closedSessions: 0 })
		if (device.userId !== user.id) throw notFound("Device not found")

		// Order matters: close the tunnel and kill the tokens while the row still
		// exists, so a node can be told to drop the peer before the record goes.
		const closedSessions = await closeSessionsForDevice(device.id, "device_revoked")
		const revokedTokens = await revokeRefreshTokens({
			userId: user.id,
			deviceId: device.id,
		})

		// Audit first: the log row references the device, and writing it after the
		// delete would either fail or lose the reference.
		await writeAudit({
			action: "device.remove",
			userId: user.id,
			deviceId: device.id,
			ip: clientIp(request),
			metadata: { by: "user", closedSessions, revokedTokens },
		})

		let removed = true
		try {
			await prisma.device.delete({ where: { id: device.id } })
			// Its VLESS credential must stop working on the nodes as well.
			await requestPolicySync().catch(() => 0)
		} catch {
			// A foreign key outside this transaction's control (retained audit
			// history) can refuse the delete. Never fail the user's request over
			// bookkeeping - fall back to the old REVOKED marker, which the clients
			// still filter out of the active list.
			removed = false
			await prisma.device.update({
				where: { id: device.id },
				data: { status: "REVOKED", revokedAt: new Date() },
			})
			await requestPolicySync().catch(() => 0)
		}

		return reply.send({ ok: true, removed, closedSessions, revokedTokens })
	})
}
