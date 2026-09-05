import { randomUUID } from "node:crypto"
import { deviceLimitReached, effectiveDeviceLimit } from "../lib/deviceLimit"
import { badRequest, conflict, forbidden, notFound } from "../lib/errors"
import { prisma } from "../prisma"
import { closeSessionsInTransaction, SERVICE_GATE_LOCK } from "./serviceControl"

/** Serialize slot allocation per account, not per process: two simultaneous
 * installs cannot both consume the last slot. No network calls under the lock. */
export async function registerDeviceSlot(userId: string, input: { deviceName: string; publicKey: string; platform?: string }) {
	return prisma.$transaction(async (tx) => {
		await tx.$queryRaw`SELECT id FROM users WHERE id = ${userId}::uuid FOR UPDATE`
		const user = await tx.user.findUnique({ where: { id: userId } })
		if (!user || user.status !== "ACTIVE") throw forbidden("User is disabled")
		if (await tx.vpnNode.findFirst({ where: { wireguardPublicKey: input.publicKey }, select: { id: true } })) throw badRequest("This public key belongs to a VPN node")
		const existing = await tx.device.findUnique({ where: { publicKey: input.publicKey } })
		if (existing && existing.userId !== userId) throw conflict("This public key is already registered")
		const reactivating = existing !== null && existing.status !== "ACTIVE"
		const maxDevices = effectiveDeviceLimit(user)
		if (!existing || reactivating) {
			const active = await tx.device.findMany({
				where: { userId, status: "ACTIVE" }, orderBy: [{ lastSeen: "desc" }, { createdAt: "desc" }],
				select: { id: true, deviceName: true, platform: true, lastSeen: true, sessions: {
					where: { status: { in: ["PENDING", "ACTIVE"] } }, orderBy: { connectedAt: "desc" }, take: 1,
					select: { node: { select: { id: true, name: true, country: true, countryCode: true, city: true } } },
				} },
			})
			if (active.length >= maxDevices) throw deviceLimitReached({ maxDevices, activeDevices: active.length,
				devices: active.map((d) => ({ id: d.id, deviceName: d.deviceName, platform: d.platform, lastSeen: d.lastSeen?.toISOString() ?? null, connected: d.sessions.length > 0, connectedNode: d.sessions[0]?.node ?? null })),
			})
		}
		const needsPolicySync = !existing || reactivating || !existing.vlessUuid
		const device = existing ? await tx.device.update({ where: { id: existing.id }, data: {
			deviceName: input.deviceName, platform: input.platform ?? existing.platform, lastSeen: new Date(),
			...(needsPolicySync ? { vlessUuid: randomUUID() } : {}),
			...(reactivating ? { status: "ACTIVE", revokedAt: null, tokenVersion: { increment: 1 } } : {}),
		} }) : await tx.device.create({ data: {
			userId, deviceName: input.deviceName, publicKey: input.publicKey, platform: input.platform ?? null,
			vlessUuid: randomUUID(), lastSeen: new Date(),
		} })
		return { device, maxDevices, existed: existing !== null, reactivating, needsPolicySync }
	})
}

/** Revoke atomically, retaining the graph until node REMOVE_PEER acknowledgement.
 * Hard-deleting Device would cascade Session and release its IP lease BEFORE
 * the node removes the peer. Tombstones are never returned/counted as slots. */
export async function revokeDeviceAccess(userId: string, deviceId: string) {
	return prisma.$transaction(async (tx) => {
		await tx.$queryRaw`SELECT pg_advisory_xact_lock_shared(${SERVICE_GATE_LOCK})::text`
		await tx.$queryRaw`SELECT id FROM users WHERE id = ${userId}::uuid FOR UPDATE`
		const device = await tx.device.findUnique({ where: { id: deviceId } })
		if (!device) return { alreadyRemoved: true, removed: true, revoked: true, closedSessions: 0, revokedTokens: 0 }
		if (device.userId !== userId) throw notFound("Device not found")
		if (device.status === "ACTIVE") await tx.device.update({ where: { id: deviceId }, data: {
			status: "REVOKED", revokedAt: new Date(), tokenVersion: { increment: 1 }, vlessUuid: null,
		} })
		const revoked = await tx.refreshToken.updateMany({ where: { userId, deviceId, revokedAt: null }, data: { revokedAt: new Date(), replacedById: null } })
		const closedSessions = await closeSessionsInTransaction(tx, { deviceId }, "device_revoked")
		return { alreadyRemoved: device.status !== "ACTIVE", removed: false, revoked: true, closedSessions, revokedTokens: revoked.count }
	})
}
