import type { Prisma } from "@prisma/client"
import { config } from "../config"
import { HttpError, notFound } from "../lib/errors"
import { prisma } from "../prisma"

// Shared by session creation and exclusive by maintenance changes. Transaction-scoped,
// so a failed request or process exit can never leave a lock behind.
export const SERVICE_GATE_LOCK = 73482001
export const MAINTENANCE_RETRY_SEC = 30
const LIVE = ["PENDING", "ACTIVE"] as const
type SettingsReader = Pick<Prisma.TransactionClient, "serviceSettings">

export async function serviceSettings(db: SettingsReader = prisma) {
	const row = await db.serviceSettings.findUnique({ where: { id: "global" } })
	return {
		registrationEnabled: row?.registrationEnabled ?? config.SELF_REGISTRATION_ENABLED,
		maintenance: row?.maintenance ?? false,
		version: row?.version ?? 0,
		updatedAt: row?.updatedAt.toISOString() ?? null,
		analyticsSince: row?.analyticsSince.toISOString() ?? null,
	}
}
export async function serviceStatus(db: SettingsReader = prisma) {
	const value = await serviceSettings(db)
	return { registrationEnabled: value.registrationEnabled, maintenance: value.maintenance, retryAfterSec: MAINTENANCE_RETRY_SEC }
}
export function maintenanceError(nodeId?: string): HttpError {
	return new HttpError(503, "maintenance", "The service is undergoing maintenance. We will be back shortly.", {
		retryAfterSec: MAINTENANCE_RETRY_SEC, ...(nodeId ? { nodeId } : {}),
	})
}
export async function requireRegistrationEnabled(db: SettingsReader = prisma): Promise<void> {
	if (!(await serviceSettings(db)).registrationEnabled) {
		throw new HttpError(403, "registration_disabled", "Registration is temporarily paused.")
	}
}
export async function requireVpnAvailable(node?: { id: string; maintenance: boolean } | null, db: SettingsReader = prisma): Promise<void> {
	if ((await serviceSettings(db)).maintenance) throw maintenanceError()
	if (node?.maintenance) throw maintenanceError(node.id)
}

/** Closing rows and queuing removals commit together, including VLESS/browser.
 * Agents acknowledge actual data-plane cutoff on their next poll; the UI must
 * not claim synchronous physical cutoff. Leases remain until the node's ACK. */
export async function closeSessionsInTransaction(tx: Prisma.TransactionClient, scope: { nodeId?: string; deviceId?: string }, reason: string): Promise<number> {
	const sessions = await tx.session.findMany({
		where: { status: { in: [...LIVE] }, ...scope },
		select: { id: true, nodeId: true, deviceId: true, peerPublicKey: true },
	})
	if (!sessions.length) return 0
	await tx.session.updateMany({
		where: { id: { in: sessions.map((s) => s.id) }, status: { in: [...LIVE] } },
		data: { status: "CLOSED", disconnectedAt: new Date(), closeReason: reason },
	})
	// Do not deliver an unclaimed setup command after the session was closed.
	await tx.nodeCommand.updateMany({
		where: { sessionId: { in: sessions.map((s) => s.id) }, type: "ADD_PEER", status: "PENDING" },
		data: { status: "FAILED", result: { reason: "session_closed_before_delivery" } },
	})
	await tx.nodeCommand.createMany({
		data: sessions.map((s) => ({
			nodeId: s.nodeId, sessionId: s.id, type: "REMOVE_PEER" as const,
			payload: { sessionId: s.id, publicKey: s.peerPublicKey, deviceId: s.deviceId },
		})),
	})
	return sessions.length
}
export async function updateServiceSettings(input: { registrationEnabled?: boolean; maintenance?: boolean; expectedVersion: number }) {
	return prisma.$transaction(async (tx) => {
		await tx.$queryRaw`SELECT pg_advisory_xact_lock(${SERVICE_GATE_LOCK})::text`
		const before = await serviceSettings(tx)
		if (before.version !== input.expectedVersion) throw new HttpError(409, "settings_conflict", "Service settings changed. Refresh and try again.")
		const changes = { ...(input.registrationEnabled !== undefined ? { registrationEnabled: input.registrationEnabled } : {}), ...(input.maintenance !== undefined ? { maintenance: input.maintenance } : {}) }
		await tx.serviceSettings.upsert({
			where: { id: "global" },
			create: { id: "global", ...changes, version: 1 },
			update: { ...changes, version: { increment: 1 } },
		})
		const closedSessions = input.maintenance === true ? await closeSessionsInTransaction(tx, {}, "maintenance") : 0
		return { ...(await serviceSettings(tx)), closedSessions }
	}, { timeout: 15000 })
}
export async function updateNodeMaintenance(nodeId: string, enabled: boolean) {
	return prisma.$transaction(async (tx) => {
		await tx.$queryRaw`SELECT pg_advisory_xact_lock(${SERVICE_GATE_LOCK})::text`
		const node = await tx.vpnNode.findUnique({ where: { id: nodeId } })
		if (!node) throw notFound("Node not found")
		await tx.vpnNode.update({ where: { id: nodeId }, data: { maintenance: enabled } })
		return { maintenance: enabled, closedSessions: enabled ? await closeSessionsInTransaction(tx, { nodeId }, "maintenance") : 0 }
	}, { timeout: 15000 })
}
export async function withRegistrationGate<T>(work: (tx: Prisma.TransactionClient) => Promise<T>): Promise<T> {
	return prisma.$transaction(async (tx) => {
		await tx.$queryRaw`SELECT pg_advisory_xact_lock_shared(${SERVICE_GATE_LOCK})::text`
		await requireRegistrationEnabled(tx)
		return work(tx)
	})
}
