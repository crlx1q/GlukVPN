import type { User } from "@prisma/client"
import { config } from "../config"
import { effectiveDeviceLimit } from "../lib/deviceLimit"
import { bytesToNumber, prisma } from "../prisma"
import { egressBudgetView } from "./egressBudget"
import { lookupOrigin } from "./geo"
import { countryPoint, usageBucket, usageWindow, type UsagePeriod } from "./insightMath"
import { loadPublicNodes } from "./nodes"
import { serviceSettings, serviceStatus } from "./serviceControl"

type Origin = { lat: number; lon: number; countryCode: string | null; country: string | null; source: "ip-country"; approximate: true }
// Cache by session, not account or caller IP. A phone and PC must never inherit
// each other's position. No IPs or credentials appear in the response or cache key.
const origins = new Map<string, { expires: number; value: Promise<Origin | null> }>()
async function sessionOrigin(id: string, ip: string | null): Promise<Origin | null> {
	if (!ip || !config.GEOIP_ENABLED) return null
	const cached = origins.get(id)
	if (cached && cached.expires > Date.now()) return cached.value
	if (origins.size >= 10000) origins.delete(origins.keys().next().value as string)
	const value = lookupOrigin(ip).then((geo): Origin | null => {
		const point = countryPoint(geo?.countryCode)
		return point && geo ? { lat: point[0], lon: point[1], countryCode: geo.countryCode, country: geo.country, source: "ip-country", approximate: true } : null
	})
	const entry = { expires: Date.now() + 3600000, value }
	origins.set(id, entry)
	const result = await value
	if (!result) entry.expires = Date.now() + 60000
	return result
}
export async function accountActiveMap(user: User, currentDeviceId?: string) {
	const [sessions, service] = await Promise.all([
		prisma.session.findMany({
			where: { userId: user.id, status: { in: ["PENDING", "ACTIVE"] }, device: { status: "ACTIVE" } },
			include: { device: true, node: true }, orderBy: { connectedAt: "desc" },
		}), serviceStatus(),
	])
	const unique = [...new Map(sessions.slice().reverse().map((s) => [s.deviceId, s])).values()].sort((a, b) => b.connectedAt.getTime() - a.connectedAt.getTime())
	const selected = unique.slice(0, 5)
	const nodes = await loadPublicNodes(selected.map((s) => s.node))
	const now = new Date()
	const devices = await Promise.all(selected.map(async (s, i) => ({
		id: s.deviceId, deviceName: s.device.deviceName, platform: s.device.platform,
		lastSeen: s.device.lastSeen?.toISOString() ?? null, isCurrent: currentDeviceId === s.deviceId,
		connected: true, sessionId: s.id, status: s.status, connectedAt: s.connectedAt.toISOString(),
		durationSec: Math.max(0, Math.floor((now.getTime() - s.connectedAt.getTime()) / 1000)),
		origin: await sessionOrigin(s.id, s.clientIp), node: nodes[i],
	})))
	return { serverTime: now.toISOString(), pollAfterMs: 5000, activeTunnels: sessions.length, maxDevices: effectiveDeviceLimit(user), truncated: unique.length > selected.length, service, devices }
}

type Counters = { downloadBytes: number; uploadBytes: number }
const emptyCounters = (): Counters => ({ downloadBytes: 0, uploadBytes: 0 })
const totalBytes = (v: Counters) => v.downloadBytes + v.uploadBytes
export async function accountAnalytics(userId: string, period: UsagePeriod, now = new Date()) {
	const window = usageWindow(period, now)
	const domainCutoff = new Date(now.getTime() - config.DOMAIN_STATS_RETENTION_DAYS * 86400000)
	const [rows, domains, budget, settings] = await Promise.all([
		prisma.trafficUsageBucket.findMany({ where: { userId, bucketStart: { gte: window.start, lte: now } }, orderBy: { bucketStart: "asc" } }),
		config.DOMAIN_STATS_ENABLED ? prisma.trafficDomainStat.groupBy({
			by: ["domain", "category"], where: { userId, lastSeenAt: { gte: domainCutoff } },
			_sum: { bytesRx: true, bytesTx: true, connections: true }, _max: { lastSeenAt: true },
		}) : [],
		egressBudgetView(now), serviceSettings(),
	])
	const totals = emptyCounters()
	const series = new Map<string, { start: string } & Counters>()
	// Zero is only used inside the known observation coverage, never for a day
	// before installation. A partial first hour/day is explicitly marked below.
	const since = settings.analyticsSince ? new Date(settings.analyticsSince) : now
	const first = new Date(Math.max(window.start.getTime(), since.getTime()))
	const step = window.bucketSize === "hour" ? 3600000 : 86400000
	for (let t = new Date(usageBucket(first, window.bucketSize)).getTime(); t <= now.getTime(); t += step) {
		const start = new Date(t).toISOString()
		series.set(start, { start, ...emptyCounters() })
	}
	const devices = new Map<string, { deviceId: string; deviceName: string; platform: string | null } & Counters>()
	for (const row of rows) {
		const downloadBytes = bytesToNumber(row.downloadBytes)
		const uploadBytes = bytesToNumber(row.uploadBytes)
		totals.downloadBytes += downloadBytes; totals.uploadBytes += uploadBytes
		const key = usageBucket(row.bucketStart, window.bucketSize)
		const bucket = series.get(key) ?? { start: key, ...emptyCounters() }
		bucket.downloadBytes += downloadBytes; bucket.uploadBytes += uploadBytes
		series.set(key, bucket)
		const device = devices.get(row.deviceId) ?? { deviceId: row.deviceId, deviceName: row.deviceName, platform: row.platform, ...emptyCounters() }
		device.downloadBytes += downloadBytes; device.uploadBytes += uploadBytes
		device.deviceName = row.deviceName; device.platform = row.platform
		devices.set(row.deviceId, device)
	}
	const categories = new Map<string, { category: string } & Counters>()
	const domainItems = domains.map((row) => {
		const value = { domain: row.domain, category: row.category ?? "other", downloadBytes: bytesToNumber(row._sum.bytesTx), uploadBytes: bytesToNumber(row._sum.bytesRx), connections: row._sum.connections ?? 0, lastSeenAt: row._max.lastSeenAt?.toISOString() ?? null, faviconUrl: ["https:", "", "icons.duckduckgo.com", "ip3", encodeURIComponent(row.domain) + ".ico"].join("/") }
		const category = categories.get(value.category) ?? { category: value.category, ...emptyCounters() }
		category.downloadBytes += value.downloadBytes; category.uploadBytes += value.uploadBytes
		categories.set(value.category, category)
		return value
	}).sort((a, b) => totalBytes(b) - totalBytes(a)).slice(0, 20)
	return {
		period, start: window.start.toISOString(), end: now.toISOString(), bucketSize: window.bucketSize,
		coverage: { since: settings.analyticsSince, partial: !settings.analyticsSince || since > window.start, source: "session-counter-deltas", timezone: "UTC" },
		totals, series: [...series.values()].sort((a, b) => a.start.localeCompare(b.start)),
		devices: [...devices.values()].sort((a, b) => totalBytes(b) - totalBytes(a)),
		domains: { enabled: config.DOMAIN_STATS_ENABLED, windowDays: config.DOMAIN_STATS_RETENTION_DAYS, scope: "retained-session-totals", items: domainItems },
		categories: [...categories.values()].sort((a, b) => totalBytes(b) - totalBytes(a)),
		// The OCI allowance belongs to the SERVICE, not every subscription. Cost,
		// error strings, OCI resource identifiers and other users are never exposed.
		budget: { scope: "service", source: "oci", available: budget.configured && Boolean(budget.lastPolledAt) && !budget.lastError,
			usedBytes: budget.usedBytes, budgetBytes: budget.budgetBytes, usedPercent: budget.usedPercent,
			cycleStart: budget.cycleStart, cycleEnd: budget.cycleEnd, lastPolledAt: budget.lastPolledAt },
	}
}
