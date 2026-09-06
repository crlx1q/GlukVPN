import { prisma } from "../prisma"

/**
 * Crash reporting for the clients.
 *
 * Everything a client sends is hostile input: a stack trace is a string the
 * client assembled from its own memory, so it can easily contain an access
 * token, a password the user typed into the wrong field or a WireGuard key.
 * `scrubText` runs over every free-form field before it is stored, and the
 * columns are length-capped, so one runaway client cannot fill the disk.
 *
 * The endpoint that feeds this is unauthenticated (the failures worth seeing
 * are the ones that happen instead of a successful sign-in), which is why the
 * spam defences live here rather than only in the rate limiter.
 */

export const CLIENT_PLATFORMS = ["windows", "android", "extension", "web"] as const

export type ClientPlatform = (typeof CLIENT_PLATFORMS)[number]

/** Hard caps. Anything longer is truncated, never rejected: a report that
 *  arrives trimmed is worth more than no report at all. */
export const LIMITS = {
	name: 120,
	message: 500,
	context: 500,
	stack: 6000,
	version: 40,
	deviceId: 120,
} as const

/** Identical reports from the same address inside this window are dropped. */
const DEDUPE_WINDOW_MS = 60_000

/** Ceiling per address per hour, on top of the route's rate limit. */
const MAX_PER_IP_PER_HOUR = 60

type Redaction = [RegExp, string]

// Order matters: the specific shapes go first so the generic key=value rule
// cannot eat half of a JWT and leave the rest readable.
const REDACTIONS: Redaction[] = [
	// JSON Web Tokens - three base64url segments. Access and refresh tokens,
	// Google ID tokens and anything else signed all match this.
	[/\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/g, "[jwt]"],
	// "Authorization: Bearer <token>", however it was capitalised.
	[/\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [redacted]"],
	// key=value / "key": "value" for anything that smells like a credential.
	[
		/\b(password|passwd|pwd|token|secret|api[_-]?key|apikey|authorization|pepper|private[_-]?key|privatekey|refresh[_-]?token|access[_-]?token|session[_-]?id|otp|code)("?\s*[:=]\s*)("?)([^\s",;&}]{3,})\3/gi,
		'$1$2$3[redacted]$3',
	],
	// WireGuard / X25519 keys: 43 base64 characters and a padding '='.
	[/\b[A-Za-z0-9+/]{43}=/g, "[key]"],
	// Long opaque blobs (hex or base64) that survived the rules above.
	[/\b[A-Fa-f0-9]{40,}\b/g, "[hex]"],
]

/**
 * Removes credentials from a free-form client string.
 *
 * Deliberately blunt: it is better to redact a harmless string than to store a
 * live token in a table support staff read all day.
 */
export function scrubText(value: string): string {
	let result = value
	for (const [pattern, replacement] of REDACTIONS) {
		result = result.replace(pattern, replacement)
	}
	return result
}

function clean(value: string | null | undefined, max: number): string | null {
	if (typeof value !== "string") return null
	// Control characters would break the panel's table layout.
	const flattened = value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, " ").trim()
	if (flattened.length === 0) return null
	const scrubbed = scrubText(flattened)
	return scrubbed.length > max ? `${scrubbed.slice(0, max)}…` : scrubbed
}

export type ClientErrorInput = {
	platform: ClientPlatform
	appVersion: string
	errorName: string
	errorMessage: string
	stackTrace?: string | null
	context?: string | null
	deviceId?: string | null
	userId?: string | null
	ip?: string | null
}

export type ClientErrorOutcome = {
	stored: boolean
	/** True when an identical report arrived moments ago, or the address is
	 *  over its hourly ceiling. Reported back so the client can back off. */
	throttled: boolean
}

/**
 * Stores one report. Never throws: telemetry must not be able to fail a
 * request, let alone crash the client that is already having a bad day.
 */
export async function recordClientError(
	input: ClientErrorInput,
): Promise<ClientErrorOutcome> {
	const errorName = clean(input.errorName, LIMITS.name) ?? "Error"
	const errorMessage = clean(input.errorMessage, LIMITS.message) ?? "(no message)"
	const appVersion = clean(input.appVersion, LIMITS.version) ?? "unknown"
	const ip = input.ip ?? null

	try {
		const since = new Date(Date.now() - DEDUPE_WINDOW_MS)
		const duplicate = await prisma.clientErrorLog.findFirst({
			where: {
				platform: input.platform,
				errorName,
				errorMessage,
				ip,
				createdAt: { gte: since },
			},
			select: { id: true },
		})
		// A crash loop reports the same line dozens of times a second. One row
		// per minute says exactly as much and keeps the table readable.
		if (duplicate) return { stored: false, throttled: true }

		if (ip) {
			const hourAgo = new Date(Date.now() - 3_600_000)
			const recent = await prisma.clientErrorLog.count({
				where: { ip, createdAt: { gte: hourAgo } },
			})
			if (recent >= MAX_PER_IP_PER_HOUR) return { stored: false, throttled: true }
		}

		await prisma.clientErrorLog.create({
			data: {
				platform: input.platform,
				appVersion,
				errorName,
				errorMessage,
				stackTrace: clean(input.stackTrace, LIMITS.stack),
				context: clean(input.context, LIMITS.context),
				deviceId: clean(input.deviceId, LIMITS.deviceId),
				userId: input.userId ?? null,
				ip,
			},
		})
		return { stored: true, throttled: false }
	} catch (error) {
		// eslint-disable-next-line no-console
		console.error(
			`client_error_store_failed platform=${input.platform} error=${
				error instanceof Error ? error.message : "unknown"
			}`,
		)
		return { stored: false, throttled: false }
	}
}

/** Drops reports older than the retention window. Called by the monitor. */
export async function purgeOldClientErrors(retentionDays: number): Promise<number> {
	const cutoff = new Date(Date.now() - retentionDays * 86_400_000)
	try {
		const { count } = await prisma.clientErrorLog.deleteMany({
			where: { createdAt: { lt: cutoff } },
		})
		return count
	} catch {
		return 0
	}
}

/**
 * Очистка журнала из админки.
 *
 * Сбор при этом НЕ выключается: удаляются только записи, которые
 * уже существовали на момент запроса (`before`), поэтому отчёт,
 * пришедший в тот же момент или позже, гарантированно остаётся в списке.
 * Так можно обнулить старые ошибки перед выпуском и сразу видеть,
 * что присылает новая сборка.
 */
export async function clearClientErrors(
	query: { platform?: ClientPlatform; before?: Date } = {},
): Promise<number> {
	const before = query.before ?? new Date()
	try {
		const { count } = await prisma.clientErrorLog.deleteMany({
			where: {
				createdAt: { lte: before },
				...(query.platform ? { platform: query.platform } : {}),
			},
		})
		return count
	} catch (error) {
		// eslint-disable-next-line no-console
		console.error(
			`client_errors_clear_failed error=${error instanceof Error ? error.message : "unknown"}`,
		)
		return 0
	}
}

export type ClientErrorView = {
	id: string
	platform: string
	appVersion: string
	errorName: string
	errorMessage: string
	stackTrace: string | null
	context: string | null
	deviceId: string | null
	userId: string | null
	user: { id: string; publicId: string; username: string } | null
	ip: string | null
	createdAt: string
}

export type ClientErrorListQuery = {
	platform?: ClientPlatform
	limit?: number
}

/**
 * The admin list. Accounts are resolved in one extra query rather than a join
 * because `user_id` is not a foreign key - the account may well be gone.
 */
export async function listClientErrors(
	query: ClientErrorListQuery = {},
): Promise<{ errors: ClientErrorView[]; counts: Record<string, number>; total: number }> {
	const limit = Math.min(Math.max(query.limit ?? 100, 1), 500)
	const where = query.platform ? { platform: query.platform } : {}

	const [rows, total, grouped] = await Promise.all([
		prisma.clientErrorLog.findMany({
			where,
			orderBy: { createdAt: "desc" },
			take: limit,
		}),
		prisma.clientErrorLog.count({ where }),
		prisma.clientErrorLog.groupBy({
			by: ["platform"],
			_count: { _all: true },
		}),
	])

	const userIds = Array.from(
		new Set(rows.map((row) => row.userId).filter((id): id is string => Boolean(id))),
	)
	const users = userIds.length
		? await prisma.user.findMany({
				where: { id: { in: userIds } },
				select: { id: true, publicId: true, username: true },
			})
		: []
	const byId = new Map(users.map((user) => [user.id, user]))

	const counts: Record<string, number> = {}
	for (const row of grouped) counts[row.platform] = row._count._all

	return {
		total,
		counts,
		errors: rows.map((row) => ({
			id: row.id,
			platform: row.platform,
			appVersion: row.appVersion,
			errorName: row.errorName,
			errorMessage: row.errorMessage,
			stackTrace: row.stackTrace,
			context: row.context,
			deviceId: row.deviceId,
			userId: row.userId,
			user: row.userId ? (byId.get(row.userId) ?? null) : null,
			ip: row.ip,
			createdAt: row.createdAt.toISOString(),
		})),
	}
}
