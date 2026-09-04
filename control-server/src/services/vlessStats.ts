/**
 * Traffic attribution for the sing-box (VLESS) data plane.
 *
 * WireGuard sessions are accounted by peer public key from `wg show dump`. A
 * VLESS session has no peer: the node agent samples sing-box's Clash API,
 * groups connections by the authenticated user (one per device, see
 * `policy.ts`) and sends *deltas since the last acknowledged report*:
 *
 *   vless.users[]: { name, deltaRx, deltaTx, activeConnections, lastSeenAt,
 *                    domains[]: { host, bytesRx, bytesTx, connections, lastSeenAt } }
 *
 * Deltas, not totals, because sing-box forgets a connection the moment it
 * closes; the agent is the only party that saw every sample, so it does the
 * subtraction and the control plane just adds.
 *
 * Direction follows the WireGuard convention already used everywhere in the
 * schema: `bytesRx` = bytes the node received from the client (its upload),
 * `bytesTx` = bytes the node sent to the client (its download).
 */
import type { VpnNode } from "@prisma/client"
import { config } from "../config"
import { prisma } from "../prisma"
import { categorize, registrableDomain } from "./domainCategories"
import { deviceIdFromUserName } from "./policy"

export type VlessDomainReport = {
	host: string
	bytesRx: number
	bytesTx: number
	connections: number
	lastSeenAt?: string | null
}

export type VlessUserReport = {
	name: string
	deltaRx: number
	deltaTx: number
	activeConnections: number
	lastSeenAt?: string | null
	domains?: VlessDomainReport[]
}

export type VlessReportOutcome = {
	sessionsUpdated: number
	domainsUpdated: number
	/** User names the node reported that map to no live session here. */
	unknownUsers: string[]
	/** Bytes the legacy shared credential moved - attributable to nobody. */
	legacyBytes: { rx: number; tx: number }
}

const MAX_DOMAINS_PER_USER = 60

function parseDate(value: string | null | undefined): Date | null {
	if (!value) return null
	const parsed = new Date(value)
	return Number.isNaN(parsed.getTime()) ? null : parsed
}

function later(a: Date | null, b: Date | null): Date | null {
	if (!a) return b
	if (!b) return a
	return a.getTime() >= b.getTime() ? a : b
}

export async function applyVlessReport(
	node: VpnNode,
	users: VlessUserReport[],
): Promise<VlessReportOutcome> {
	const outcome: VlessReportOutcome = {
		sessionsUpdated: 0,
		domainsUpdated: 0,
		unknownUsers: [],
		legacyBytes: { rx: 0, tx: 0 },
	}
	if (users.length === 0) return outcome

	const liveSessions = await prisma.session.findMany({
		where: { nodeId: node.id, status: { in: ["PENDING", "ACTIVE"] } },
		orderBy: { connectedAt: "desc" },
	})
	// Newest live session per device wins; a reconnect closes the older one
	// anyway, this only guards the race between the two.
	const byDevice = new Map<string, (typeof liveSessions)[number]>()
	for (const session of liveSessions) {
		if (!byDevice.has(session.deviceId)) byDevice.set(session.deviceId, session)
	}

	for (const entry of users) {
		const deviceId = deviceIdFromUserName(entry.name)
		if (!deviceId) {
			if (entry.name === "gluk") {
				outcome.legacyBytes.rx += Math.max(0, entry.deltaRx)
				outcome.legacyBytes.tx += Math.max(0, entry.deltaTx)
			} else {
				outcome.unknownUsers.push(entry.name)
			}
			continue
		}
		const session = byDevice.get(deviceId)
		if (!session) {
			outcome.unknownUsers.push(entry.name)
			continue
		}

		const deltaRx = Math.max(0, Math.floor(entry.deltaRx))
		const deltaTx = Math.max(0, Math.floor(entry.deltaTx))
		const seenAt = later(parseDate(entry.lastSeenAt), null)
		const hadActivity = deltaRx > 0 || deltaTx > 0 || entry.activeConnections > 0

		await prisma.session.update({
			where: { id: session.id },
			data: {
				bytesRx: { increment: BigInt(deltaRx) },
				bytesTx: { increment: BigInt(deltaTx) },
				...(hadActivity ? { transport: "vless" } : {}),
				...(seenAt
					? { lastHandshakeAt: later(session.lastHandshakeAt, seenAt) ?? seenAt }
					: {}),
			},
		})
		if (seenAt) {
			await prisma.device.update({
				where: { id: deviceId },
				data: { lastSeen: seenAt },
			})
		}
		outcome.sessionsUpdated += 1

		if (!config.DOMAIN_STATS_ENABLED || !entry.domains?.length) continue

		// Collapse hosts onto registrable domains first, so "a.cdn.example.com"
		// and "b.cdn.example.com" become one row before the upsert loop.
		const merged = new Map<string, VlessDomainReport & { domain: string }>()
		for (const item of entry.domains) {
			const domain = registrableDomain(item.host)
			if (!domain) continue
			const current = merged.get(domain)
			const seen = parseDate(item.lastSeenAt)
			if (current) {
				current.bytesRx += Math.max(0, item.bytesRx)
				current.bytesTx += Math.max(0, item.bytesTx)
				current.connections += Math.max(0, item.connections)
				const currentSeen = parseDate(current.lastSeenAt)
				current.lastSeenAt = (later(currentSeen, seen) ?? seen)?.toISOString() ?? null
			} else {
				merged.set(domain, {
					domain,
					host: item.host,
					bytesRx: Math.max(0, item.bytesRx),
					bytesTx: Math.max(0, item.bytesTx),
					connections: Math.max(0, item.connections),
					lastSeenAt: seen?.toISOString() ?? null,
				})
			}
		}

		const top = [...merged.values()]
			.sort((a, b) => b.bytesRx + b.bytesTx - (a.bytesRx + a.bytesTx))
			.slice(0, MAX_DOMAINS_PER_USER)

		for (const item of top) {
			const lastSeenAt = parseDate(item.lastSeenAt) ?? seenAt ?? new Date()
			await prisma.trafficDomainStat.upsert({
				where: { sessionId_domain: { sessionId: session.id, domain: item.domain } },
				create: {
					userId: session.userId,
					deviceId: session.deviceId,
					sessionId: session.id,
					nodeId: node.id,
					domain: item.domain,
					category: categorize(item.domain),
					bytesRx: BigInt(Math.floor(item.bytesRx)),
					bytesTx: BigInt(Math.floor(item.bytesTx)),
					connections: Math.floor(item.connections),
					firstSeenAt: lastSeenAt,
					lastSeenAt,
				},
				update: {
					bytesRx: { increment: BigInt(Math.floor(item.bytesRx)) },
					bytesTx: { increment: BigInt(Math.floor(item.bytesTx)) },
					connections: { increment: Math.floor(item.connections) },
					lastSeenAt,
				},
			})
			outcome.domainsUpdated += 1
		}
	}

	return outcome
}

/** Housekeeping for the monitor: drop domain rows past the retention window. */
export async function purgeOldDomainStats(): Promise<number> {
	const cutoff = new Date(Date.now() - config.DOMAIN_STATS_RETENTION_DAYS * 24 * 60 * 60 * 1000)
	const result = await prisma.trafficDomainStat.deleteMany({
		where: { lastSeenAt: { lt: cutoff } },
	})
	return result.count
}
