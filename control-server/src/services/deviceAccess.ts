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

/**
 * Убирает кеш старых устройств.
 *
 * Каждая переустановка клиента создаёт новую пару ключей, а значит и новую
 * строку Device; при исчерпании лимита прежние помечаются REVOKED и остаются
 * в базе навсегда. Из-за этого в админке светилось «58 / 5» — счётчик считал
 * надгробия. Активные устройства не трогаем никогда.
 *
 * Строки без единой сессии удаляем сразу — терять нечего. Остальные только
 * когда вся их история закрыта и старше окна хранения: удаление Device
 * каскадом уносит его сессии и статистику трафика.
 */
export async function purgeStaleDevices(
	options: { retentionDays?: number; userId?: string } = {},
): Promise<number> {
	const retentionDays = Math.max(0, options.retentionDays ?? 0)
	const cutoff = new Date(Date.now() - retentionDays * 86_400_000)
	const scope = options.userId ? { userId: options.userId } : {}
	const empty = await prisma.device.deleteMany({
		where: { ...scope, status: { not: "ACTIVE" }, sessions: { none: {} } },
	})
	const aged = await prisma.device.deleteMany({
		where: {
			...scope,
			status: { not: "ACTIVE" },
			OR: [
				{ revokedAt: { lt: cutoff } },
				{ revokedAt: null, lastSeen: { lt: cutoff } },
				{ revokedAt: null, lastSeen: null, createdAt: { lt: cutoff } },
			],
			// Открытая сессия (disconnectedAt = null) не проходит проверку `lt`,
			// поэтому живые туннели удалить нельзя даже с нулевым окном.
			sessions: { every: { status: "CLOSED", disconnectedAt: { lt: cutoff } } },
		},
	})
	return empty.count + aged.count
}
