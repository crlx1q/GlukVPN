/**
 * Traffic attribution from sing-box's Clash API.
 *
 * `GET /connections` returns every live connection with cumulative upload /
 * download counters and the outbound chain it took. The agent samples it every
 * few seconds and turns the samples into *deltas per user*:
 *
 *   - a connection is attributed to the user whose private outbound
 *     (`u_<user>`, see singbox.ts) appears in its chain;
 *   - the delta for a connection is its counter now minus the counter at the
 *     previous sample (or the whole counter when it is new);
 *   - a connection that vanished between samples has already been counted up
 *     to the last time it was seen, which is where sing-box stops counting too.
 *
 * Direction: Clash "upload" is client -> destination, i.e. bytes the node
 * *received* from the client, so it lands in `deltaRx`; "download" lands in
 * `deltaTx`. That is the WireGuard convention the control plane already uses.
 *
 * `drain()` hands the accumulated report to the caller and resets; if the
 * report cannot be delivered, `restore()` puts it back so nothing is lost.
 */
import type { VlessDomainReport, VlessUserReport } from "./api"
import { userFromOutboundTag } from "./singbox"

export type ClashConnection = {
	id: string
	upload: number
	download: number
	start?: string
	chains?: string[]
	rule?: string
	metadata?: {
		network?: string
		type?: string
		host?: string
		destinationIP?: string
		destinationPort?: string
		sourceIP?: string
	}
}

export type ClashSnapshot = {
	downloadTotal?: number
	uploadTotal?: number
	connections?: ClashConnection[] | null
}

type DomainAccumulator = { bytesRx: number; bytesTx: number; connections: number; lastSeenAt: number }

type UserAccumulator = {
	deltaRx: number
	deltaTx: number
	lastSeenAt: number
	activeConnections: number
	domains: Map<string, DomainAccumulator>
}

type Seen = { upload: number; download: number; user: string | null; domain: string }

const MAX_DOMAINS_PER_USER = 200

function clashHeaders(secret: string): Record<string, string> {
	return {
		accept: "application/json",
		...(secret ? { authorization: `Bearer ${secret}` } : {}),
	}
}

export async function fetchConnections(apiBase: string, secret: string, timeoutMs = 4000): Promise<ClashSnapshot> {
	const response = await fetch(`http://${apiBase}/connections`, {
		headers: clashHeaders(secret),
		signal: AbortSignal.timeout(timeoutMs),
	})
	if (!response.ok) throw new Error(`clash api answered ${response.status}`)
	return (await response.json()) as ClashSnapshot
}

/** Clash-compatible API: close one connection, never the global collection. */
export async function closeConnection(
	apiBase: string,
	secret: string,
	connectionId: string,
	timeoutMs = 4000,
): Promise<boolean> {
	const response = await fetch(`http://${apiBase}/connections/${encodeURIComponent(connectionId)}`, {
		method: "DELETE",
		headers: clashHeaders(secret),
		signal: AbortSignal.timeout(timeoutMs),
	})
	if (response.status === 404) return false
	if (!response.ok) throw new Error(`clash api close answered ${response.status}`)
	return true
}

/** Which user a connection belongs to, from its outbound chain or rule text. */
export function attributeConnection(connection: ClashConnection): string | null {
	for (const tag of connection.chains ?? []) {
		const user = userFromOutboundTag(String(tag))
		if (user) return user
	}
	const rule = connection.rule ?? ""
	const match = /auth_user=([^\s=>]+)/.exec(rule)
	if (match) return match[1] ?? null
	const tagInRule = /\(u_([^)]+)\)/.exec(rule)
	if (tagInRule) return tagInRule[1] ?? null
	return null
}

export function domainOf(connection: ClashConnection): string {
	const host = (connection.metadata?.host ?? "").trim().toLowerCase()
	if (host) return host
	const ip = (connection.metadata?.destinationIP ?? "").trim()
	return ip
}

export class ConnectionTracker {
	private readonly seen = new Map<string, Seen>()
	private readonly users = new Map<string, UserAccumulator>()
	private readonly reportDomains: boolean

	constructor(options: { reportDomains: boolean }) {
		this.reportDomains = options.reportDomains
	}

	private accumulator(user: string): UserAccumulator {
		let entry = this.users.get(user)
		if (!entry) {
			entry = { deltaRx: 0, deltaTx: 0, lastSeenAt: 0, activeConnections: 0, domains: new Map() }
			this.users.set(user, entry)
		}
		return entry
	}

	/** Folds one snapshot into the accumulators. */
	ingest(snapshot: ClashSnapshot, now: number = Date.now()): void {
		const connections = snapshot.connections ?? []
		const active = new Map<string, number>()
		const live = new Set<string>()

		for (const connection of connections) {
			if (!connection || typeof connection.id !== "string") continue
			live.add(connection.id)
			const upload = Math.max(0, Number(connection.upload) || 0)
			const download = Math.max(0, Number(connection.download) || 0)
			const previous = this.seen.get(connection.id)
			const user = previous?.user ?? attributeConnection(connection)
			const domain = previous?.domain ?? domainOf(connection)

			const deltaUp = previous ? Math.max(0, upload - previous.upload) : upload
			const deltaDown = previous ? Math.max(0, download - previous.download) : download
			this.seen.set(connection.id, { upload, download, user, domain })

			if (!user) continue
			active.set(user, (active.get(user) ?? 0) + 1)
			const entry = this.accumulator(user)
			entry.deltaRx += deltaUp
			entry.deltaTx += deltaDown
			entry.lastSeenAt = now

			if (this.reportDomains && domain) {
				let record = entry.domains.get(domain)
				if (!record) {
					if (entry.domains.size >= MAX_DOMAINS_PER_USER) continue
					record = { bytesRx: 0, bytesTx: 0, connections: 0, lastSeenAt: now }
					entry.domains.set(domain, record)
				}
				record.bytesRx += deltaUp
				record.bytesTx += deltaDown
				record.lastSeenAt = now
				if (!previous) record.connections += 1
			}
		}

		// Forget connections sing-box closed; their bytes were counted already.
		for (const id of [...this.seen.keys()]) {
			if (!live.has(id)) this.seen.delete(id)
		}
		for (const [user, entry] of this.users) entry.activeConnections = active.get(user) ?? 0
		// Users with nothing to report and no live connection need no entry.
		for (const [user, entry] of this.users) {
			if (entry.deltaRx === 0 && entry.deltaTx === 0 && entry.activeConnections === 0 && entry.domains.size === 0) {
				this.users.delete(user)
			}
		}
	}

	/** Live connection count per user, for logs and the heartbeat. */
	activeConnectionCount(): number {
		let total = 0
		for (const entry of this.users.values()) total += entry.activeConnections
		return total
	}

	/** Takes the accumulated report and resets the counters (not the seen set). */
	drain(): VlessUserReport[] {
		const report: VlessUserReport[] = []
		for (const [user, entry] of this.users) {
			const domains: VlessDomainReport[] = [...entry.domains.entries()]
				.map(([host, record]) => ({
					host,
					bytesRx: record.bytesRx,
					bytesTx: record.bytesTx,
					connections: record.connections,
					lastSeenAt: new Date(record.lastSeenAt).toISOString(),
				}))
				.sort((a, b) => b.bytesRx + b.bytesTx - (a.bytesRx + a.bytesTx))
			report.push({
				name: user,
				deltaRx: entry.deltaRx,
				deltaTx: entry.deltaTx,
				activeConnections: entry.activeConnections,
				lastSeenAt: entry.lastSeenAt ? new Date(entry.lastSeenAt).toISOString() : null,
				...(this.reportDomains && domains.length > 0 ? { domains } : {}),
			})
			entry.deltaRx = 0
			entry.deltaTx = 0
			entry.domains = new Map()
		}
		return report
	}

	/** Puts an undelivered report back so the next attempt carries it. */
	restore(report: VlessUserReport[]): void {
		for (const item of report) {
			const entry = this.accumulator(item.name)
			entry.deltaRx += item.deltaRx
			entry.deltaTx += item.deltaTx
			if (item.lastSeenAt) entry.lastSeenAt = Math.max(entry.lastSeenAt, Date.parse(item.lastSeenAt) || 0)
			for (const domain of item.domains ?? []) {
				const record = entry.domains.get(domain.host) ?? {
					bytesRx: 0,
					bytesTx: 0,
					connections: 0,
					lastSeenAt: 0,
				}
				record.bytesRx += domain.bytesRx
				record.bytesTx += domain.bytesTx
				record.connections += domain.connections
				record.lastSeenAt = Math.max(record.lastSeenAt, Date.parse(domain.lastSeenAt ?? "") || 0)
				entry.domains.set(domain.host, record)
			}
		}
	}
}
