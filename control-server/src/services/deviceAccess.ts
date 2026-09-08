import { randomUUID } from "node:crypto"
import { deviceLimitReached, effectiveDeviceLimit } from "../lib/deviceLimit"
import { badRequest, conflict, forbidden, notFound } from "../lib/errors"
import { prisma } from "../prisma"
import { FREE_PLAN_CODE, planShape } from "./entitlements"
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
		// «1 в 1 название и ОС» — это одно и то же устройство после переустановки:
		// новая пара ключей создавала вторую строку Device, и в списке висело два
		// «Chrome 152 - Windows», а слоты тарифа выедались впустую. Забираем прежнюю
		// строку себе (ротация ключа) — но только если на ней нет живого туннеля:
		// подключённое устройство с таким же именем — это точно другая машина.
		const twin = existing
			? null
			: await tx.device.findFirst({
					where: {
						userId,
						status: "ACTIVE",
						deviceName: input.deviceName,
						platform: input.platform ?? null,
						sessions: { none: { status: { in: ["PENDING", "ACTIVE"] } } },
					},
					orderBy: [{ lastSeen: "desc" }, { createdAt: "desc" }],
				})
		if (twin) {
			const device = await tx.device.update({
				where: { id: twin.id },
				data: {
					publicKey: input.publicKey,
					vlessUuid: randomUUID(),
					lastSeen: new Date(),
					// Ключ сменился — старые токены этой строки оживить нельзя.
					tokenVersion: { increment: 1 },
				},
			})
			await tx.refreshToken.updateMany({
				where: { userId, deviceId: twin.id, revokedAt: null },
				data: { revokedAt: new Date(), replacedById: null },
			})
			return { device, maxDevices, existed: true, reactivating: false, needsPolicySync: true }
		}
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

/**
 * Принудительное отключение лишних устройств (Kick/Disconnect).
 *
 * Подписка кончилась — тариф давал 3–5 слотов, Free даёт один. Доступ
 * остаётся на одном устройстве (самом первом зарегистрированном), остальные
 * разлогиниваются: статус REVOKED, tokenVersion++, refresh-токены отозваны,
 * живые туннели закрыты. Клиент на следующем же запросе получает 401 /
 * device_revoked и выходит из аккаунта сам — эта ветка уже реализована на
 * телефоне, ПК и в расширении.
 *
 * «Первое подключённое» = самая старая живая строка Device (createdAt asc):
 * человек, который перестал платить, сохраняет то устройство, с которого
 * начал, а не случайное последнее.
 */
export async function enforceDeviceAllowance(params: {
	userId: string
	allowance: number
	reason?: string
}): Promise<{ allowance: number; kept: number; revoked: number; closedSessions: number }> {
	const allowance = Math.max(1, Math.trunc(params.allowance))
	const reason = params.reason ?? "subscription_expired"
	return prisma.$transaction(
		async (tx) => {
			await tx.$queryRaw`SELECT pg_advisory_xact_lock_shared(${SERVICE_GATE_LOCK})::text`
			await tx.$queryRaw`SELECT id FROM users WHERE id = ${params.userId}::uuid FOR UPDATE`
			const active = await tx.device.findMany({
				where: { userId: params.userId, status: "ACTIVE" },
				orderBy: [{ createdAt: "asc" }],
				select: { id: true },
			})
			if (active.length <= allowance) {
				return { allowance, kept: active.length, revoked: 0, closedSessions: 0 }
			}
			let closedSessions = 0
			const extra = active.slice(allowance)
			for (const device of extra) {
				await tx.device.update({
					where: { id: device.id },
					data: {
						status: "REVOKED",
						revokedAt: new Date(),
						tokenVersion: { increment: 1 },
						vlessUuid: null,
					},
				})
				await tx.refreshToken.updateMany({
					where: { userId: params.userId, deviceId: device.id, revokedAt: null },
					data: { revokedAt: new Date(), replacedById: null },
				})
				closedSessions += await closeSessionsInTransaction(tx, { deviceId: device.id }, reason)
			}
			return { allowance, kept: allowance, revoked: extra.length, closedSessions }
		},
		{ timeout: 15000 },
	)
}

/**
 * Опустить лимиты аккаунта до того тарифа, который у него реально остался,
 * и выкинуть лишние устройства.
 *
 * Вызывается при истечении подписки (монитор) и при её ручном отключении в
 * админке. `billing.ts` поднимает `user.maxDevices` при активации и никогда
 * не опускает — без этой функции аккаунт после окончания месяца продолжал
 * жить с пятью залогиненными устройствами.
 *
 * Если у человека осталась ещё одна активная подписка (перекрывающиеся
 * выдачи), применяются её лимиты, а не Free.
 */
export async function downgradeToPlanAllowance(
	userId: string,
	reason = "subscription_expired",
): Promise<{ plan: string; allowance: number; kept: number; revoked: number; closedSessions: number }> {
	const active = await prisma.subscription.findFirst({
		where: {
			userId,
			status: "ACTIVE",
			expiresAt: { gt: new Date() },
			plan: { not: FREE_PLAN_CODE },
		},
		orderBy: [{ tier: "desc" }, { expiresAt: "desc" }],
		select: { plan: true },
	})
	const shape = planShape(active?.plan ?? FREE_PLAN_CODE)
	// Таблица `plans` главнее матрицы в коде — как в resolveEntitlement.
	const row = await prisma.plan.findFirst({ where: { code: shape.code } })
	const maxDevices = row?.maxDevices ?? shape.maxDevices
	const maxSessions = row?.maxSessions ?? shape.maxSessions
	await prisma.user.update({ where: { id: userId }, data: { maxDevices, maxSessions } })
	const kicked = await enforceDeviceAllowance({ userId, allowance: maxDevices, reason })
	return { plan: shape.code, ...kicked }
}
