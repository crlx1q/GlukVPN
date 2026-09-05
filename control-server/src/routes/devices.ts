import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { writeAudit } from "../lib/audit"
import { effectiveDeviceLimit } from "../lib/deviceLimit"
import { badRequest } from "../lib/errors"
import { wireGuardKeySchema } from "../lib/wg"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { registerDeviceSlot, revokeDeviceAccess } from "../services/deviceAccess"
import { requestPolicySync } from "../services/policy"
import { findLiveSessionForDevice } from "../services/sessions"
import { issueTokens } from "../services/tokens"

const RegisterBody = z.object({
	deviceName: z.string().trim().min(1).max(64),
	// Only the PUBLIC key is accepted. Private keys never leave the device.
	publicKey: wireGuardKeySchema,
	platform: z.string().trim().max(32).optional(),
})
const IdParams = z.object({ id: z.string().uuid("Invalid device id") })

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
	app.post("/api/devices/register", {
		preHandler: requireUser, config: { rateLimit: { max: 20, timeWindow: "1 minute" } },
	}, async (request, reply) => {
		const parsed = RegisterBody.safeParse(request.body)
		if (!parsed.success) throw badRequest("Invalid device payload", parsed.error.flatten().fieldErrors)
		const { user } = getAuthUser(request)
		const result = await registerDeviceSlot(user.id, parsed.data)
		const { device, maxDevices, existed, reactivating } = result
		if (result.needsPolicySync) await requestPolicySync().catch(() => 0)
		const tokens = await issueTokens(app, user, device)
		await writeAudit({
			action: existed ? reactivating ? "device.reactivate" : "device.reregister" : "device.register",
			userId: user.id, deviceId: device.id, ip: clientIp(request),
			metadata: { deviceName: parsed.data.deviceName, platform: parsed.data.platform ?? null },
		})
		return reply.code(existed ? 200 : 201).send({
			device: { id: device.id, deviceName: device.deviceName, platform: device.platform,
				status: device.status, createdAt: device.createdAt.toISOString() },
			maxDevices, tokenType: "Bearer", accessToken: tokens.accessToken,
			expiresIn: tokens.accessTokenExpiresInSec, refreshToken: tokens.refreshToken,
			refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
		})
	})

	app.get("/api/devices", { preHandler: requireUser }, async (request, reply) => {
		const { user, device: currentDevice } = getAuthUser(request)
		const devices = await prisma.device.findMany({
			where: { userId: user.id, status: "ACTIVE" }, orderBy: [{ createdAt: "desc" }],
		})
		const items = await Promise.all(devices.map(async (device) => {
			const live = await findLiveSessionForDevice(device.id)
			return {
				id: device.id, deviceName: device.deviceName, platform: device.platform,
				status: device.status, createdAt: device.createdAt.toISOString(),
				lastSeen: device.lastSeen?.toISOString() ?? null, isCurrent: currentDevice?.id === device.id,
				connected: live !== null,
				connectedNode: live ? { id: live.node.id, name: live.node.name, country: live.node.country,
					countryCode: live.node.countryCode, city: live.node.city } : null,
			}
		}))
		return reply.header("Cache-Control", "private, no-store").send({ devices: items, maxDevices: effectiveDeviceLimit(user) })
	})

	// Sign-out removes the slot immediately. Retain the revoked graph until node
	// acknowledgement instead of cascading sessions and prematurely reusing IPs.
	app.delete("/api/devices/:id", { preHandler: requireUser, config: { rateLimit: { max: 30, timeWindow: "1 minute" } } }, async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid device id")
		const { user } = getAuthUser(request)
		const result = await revokeDeviceAccess(user.id, parsed.data.id)
		await requestPolicySync().catch(() => 0)
		if (!result.alreadyRemoved) await writeAudit({
			action: "device.remove", userId: user.id, deviceId: parsed.data.id, ip: clientIp(request),
			metadata: { by: "user", closedSessions: result.closedSessions, revokedTokens: result.revokedTokens },
		})
		return reply.send({ ok: true, ...result })
	})
}
