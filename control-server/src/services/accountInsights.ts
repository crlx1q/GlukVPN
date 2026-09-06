import type { User } from "@prisma/client"
import { config } from "../config"
import { effectiveDeviceLimit } from "../lib/deviceLimit"
import { bytesToNumber, prisma } from "../prisma"
import { egressBudgetView } from "./egressBudget"
import { lookupOrigin } from "./geo"
import { countryPoint, usageBucket, usageWindow, type UsagePeriod } from "./insightMath"
import { loadPublicNodes } from "./nodes"
import { serviceSettings, serviceStatus } from "./serviceControl"

type Origin = { lat: number; lon: number; countryCode: string | null; country: string | null; source: "ip-country" | "device-estimate"; approximate: true }
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
export function deviceEstimate(code: string | null | undefined): Origin | null {
	const point = countryPoint(code)
	return point ? { lat: point[0], lon: point[1], countryCode: String(code).toUpperCase(), country: null, source: "device-estimate", approximate: true } : null
}

// Иконка сайта — только для настоящих доменов.
//
// Раньше адрес иконки склеивался безусловно, поэтому для сеансов без SNI,
// где «домен» — это IP, получалось
// https://icons.duckduckgo.com/ip3/77.111.249.147.ico. Такого файла не
// существует и не может существовать — сервис отвечает 404, а клиенты
// честно сообщали об этом в телеметрию (`NetworkImageLoadException:
// HTTP 404`). У IP иконки нет — отдаём null, и интерфейс ставит свою
// заглушку вместо заведомо битой картинки.
const IPV4_LITERAL = /^\d{1,3}(?:\.\d{1,3}){3}$/
export function domainFaviconUrl(domain: string): string | null {
	const host = String(domain ?? "").trim().toLowerCase().replace(/\.$/, "")
	if (!host || host.length > 253) return null
	// IPv6 и порты — тоже не домены.
	if (host.includes(":") || IPV4_LITERAL.test(host)) return null
	// Должна быть хотя бы одна точка и буквенный TLD.
	if (!/^[a-z0-9.-]+$/.test(host) || !/\.[a-z]{2,}$/.test(host)) return null
	return ["https:", "", "icons.duckduckgo.com", "ip3", encodeURIComponent(host) + ".ico"].join("/")
}

export async function recordMapCountry(userId: string, deviceId: string, countryCode: string) {
	return prisma.device.updateMany({
		where: { userId, id: deviceId, status: "ACTIVE", OR: [{ mapCountryCode: null }, { mapCountryCode: { not: countryCode } }] },
		data: { mapCountryCode: countryCode },
	})
}

export async function accountActiveMap(user: User, currentDeviceId?: string) {
	const [sessions, service] = await Promise.all([
		prisma.session.findMany({
			where: { userId: user.id, status: { in: ["PENDING", "ACTIVE"] }, device: { status: "ACTIVE" } },
			include: { device: true, node: true }, orderBy: { connectedAt: "desc" },
		}), serviceStatus(),
	])
	const unique = [...new Map(sessions.slice().reverse().map((s) => [s.deviceId, s])).values()].sort((a, b) => b.connectedAt.getTime() - a.connectedAt.getTime())
	const selected = unique
	const nodes = await loadPublicNodes(selected.map((s) => s.node))
	const now = new Date()
	const devices = await Promise.all(selected.map(async (s, i) => ({
		id: s.deviceId, deviceName: s.device.deviceName, platform: s.device.platform,
		lastSeen: s.device.lastSeen?.toISOString() ?? null, isCurrent: currentDeviceId === s.deviceId,
		connected: s.status === 'ACTIVE', sessionId: s.id, status: s.status, connectedAt: s.connectedAt.toISOString(),
		durationSec: Math.max(0, Math.floor((now.getTime() - s.connectedAt.getTime()) / 1000)),
		origin: (await sessionOrigin(s.id, s.clientIp)) ?? deviceEstimate(s.device.mapCountryCode), node: nodes[i],
	})))
	return { serverTime: now.toISOString(), pollAfterMs: 5000, activeTunnels: selected.filter(s => s.status === 'ACTIVE').length, pendingTunnels: selected.filter(s => s.status === 'PENDING').length, maxDevices: effectiveDeviceLimit(user), truncated: unique.length > selected.length, service, devices }
}

type Counters = { downloadBytes: number; uploadBytes: number }
const emptyCounters = (): Counters => ({ downloadBytes: 0, uploadBytes: 0 })
const totalBytes = (v: Counters) => v.downloadBytes + v.uploadBytes
export async function accountAnalytics(userId: string, period: UsagePeriod, now = new Date(), includeBudget = false) {
	const window = usageWindow(period, now)
	const domainCutoff = new Date(now.getTime() - config.DOMAIN_STATS_RETENTION_DAYS * 86400000)
	const [rows, domains, budget, settings] = await Promise.all([
		prisma.trafficUsageBucket.findMany({ where: { userId, bucketStart: { gte: window.start, lte: now } }, orderBy: { bucketStart: "asc" } }),
		config.DOMAIN_STATS_ENABLED ? prisma.trafficDomainStat.groupBy({
			by: ["domain", "category"], where: { userId, lastSeenAt: { gte: domainCutoff } },
			_sum: { bytesRx: true, bytesTx: true, connections: true }, _max: { lastSeenAt: true },
		}) : [],
		includeBudget ? egressBudgetView(now) : null, serviceSettings(),
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
		const value = { domain: row.domain, category: row.category ?? "other", downloadBytes: bytesToNumber(row._sum.bytesTx), uploadBytes: bytesToNumber(row._sum.bytesRx), connections: row._sum.connections ?? 0, lastSeenAt: row._max.lastSeenAt?.toISOString() ?? null, faviconUrl: domainFaviconUrl(row.domain) }
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
		budget: budget ? { adminOnly: true, scope: "service", source: "oci", available: budget.configured && Boolean(budget.lastPolledAt) && !budget.lastError,
			usedBytes: budget.usedBytes, budgetBytes: budget.budgetBytes, usedPercent: budget.usedPercent,
			cycleStart: budget.cycleStart, cycleEnd: budget.cycleEnd, lastPolledAt: budget.lastPolledAt } : null,
	}
}
