import { prisma } from "../prisma"

/**
 * One answer to "what is this account entitled to right now".
 *
 * Two rules drive everything here:
 *
 * 1. **Free is not a subscription.** It is the absence of one. There is no such
 *    thing as "Free, active, 790 days left" - a Free account simply has no row,
 *    and legacy `plan = "free"` rows are ignored on purpose so old data reads
 *    the same way. Deactivating a subscription therefore does not need to grant
 *    anything: the account falls back to Free by itself.
 * 2. **The server decides.** Limits (devices, sessions, monthly traffic) come
 *    from the plans table, never from the client. Clients only render what this
 *    module reports.
 *
 * The monthly traffic window is anchored to the day the subscription started -
 * not to the first of the calendar month - and repeats every 30 days for as
 * long as the plan runs: three months paid = three windows.
 */

const DAY_MS = 24 * 60 * 60 * 1000

/** Length of one traffic window. Fixed 30 days, deliberately not a month. */
export const QUOTA_PERIOD_DAYS = 30
export const QUOTA_PERIOD_MS = QUOTA_PERIOD_DAYS * DAY_MS

export const FREE_PLAN_CODE = "free"

export type PlanShape = {
	code: string
	name: string
	tier: number
	maxDevices: number
	maxSessions: number
	/** Monthly cap in GB. `null` means uncapped. */
	trafficGb: number | null
}

/**
 * price.md, mirrored in code as the fallback when the `plans` table has no row
 * for a code (fresh database, legacy "test" grants, a beta tier that was never
 * seeded). The table wins whenever it has the plan.
 */
export const PLAN_MATRIX: Record<string, PlanShape> = {
	free: { code: "free", name: "Free", tier: 0, maxDevices: 1, maxSessions: 1, trafficGb: 5 },
	basic: { code: "basic", name: "Basic", tier: 1, maxDevices: 3, maxSessions: 3, trafficGb: 50 },
	pro: { code: "pro", name: "Pro", tier: 2, maxDevices: 5, maxSessions: 5, trafficGb: 150 },
	pro_3m: { code: "pro_3m", name: "Pro", tier: 2, maxDevices: 5, maxSessions: 5, trafficGb: 150 },
	// Internal test tier: never sold, never listed, but grantable by an admin.
	beta_pro: { code: "beta_pro", name: "\u03b2 Pro", tier: 2, maxDevices: 5, maxSessions: 5, trafficGb: 150 },
	// Legacy: accounts created by the old admin form got plan "test".
	test: { code: "test", name: "\u03b2 Pro", tier: 2, maxDevices: 5, maxSessions: 5, trafficGb: 150 },
}

export function planShape(code: string | null | undefined): PlanShape {
	const key = (code ?? "").trim().toLowerCase()
	return PLAN_MATRIX[key] ?? { ...PLAN_MATRIX.free, code: key || FREE_PLAN_CODE }
}

/** Display name shown next to a nickname on every platform. */
export function planDisplayName(code: string | null | undefined): string {
	const key = (code ?? "").trim().toLowerCase()
	return PLAN_MATRIX[key]?.name ?? (key ? key : "Free")
}

/**
 * Which badge a client should draw. Kept as a stable token so the site, the
 * desktop app, Android and the extension can all key their own artwork off it.
 */
export function planBadge(code: string | null | undefined): "free" | "basic" | "pro" | "beta" {
	const key = (code ?? "").trim().toLowerCase()
	if (key === "beta_pro" || key === "test") return "beta"
	if (key === "pro" || key === "pro_3m") return "pro"
	if (key === "basic") return "basic"
	return "free"
}

/** Free is not grantable: granting it is what produced "Free - active - 790 days". */
export function isGrantablePlanCode(code: string | null | undefined): boolean {
	const key = (code ?? "").trim().toLowerCase()
	return key.length > 0 && key !== FREE_PLAN_CODE
}

export type QuotaPeriod = {
	/** How many full windows have passed since the anchor. */
	index: number
	start: Date
	end: Date
	anchor: Date
}

/**
 * The window that contains `at`, counted in 30-day steps from `anchor`.
 *
 * Anchor = the day the plan started, so a plan bought on the 17th always resets
 * on a multiple of 30 days from the 17th, whatever the calendar does.
 */
export function quotaPeriod(anchor: Date, at: Date = new Date()): QuotaPeriod {
	const elapsed = at.getTime() - anchor.getTime()
	const index = elapsed <= 0 ? 0 : Math.floor(elapsed / QUOTA_PERIOD_MS)
	const start = new Date(anchor.getTime() + index * QUOTA_PERIOD_MS)
	return { index, start, end: new Date(start.getTime() + QUOTA_PERIOD_MS), anchor }
}

export type Entitlement = {
	planCode: string
	planName: string
	badge: "free" | "basic" | "pro" | "beta"
	tier: number
	/** True only when a real (non-Free) subscription is active. */
	subscribed: boolean
	subscriptionId: string | null
	source: string | null
	expiresAt: Date | null
	daysLeft: number | null
	maxDevices: number
	maxSessions: number
	/** `null` = uncapped. */
	trafficLimitBytes: number | null
	period: QuotaPeriod
}

/**
 * Where the traffic window starts counting.
 *
 * `grantPlan` supersedes the old row and writes a new one when a plan is
 * extended, so the newest row's `createdAt` alone would hand out a free quota
 * reset on every renewal. Walk back through same-plan rows that were still
 * valid when the next one was created and use the start of that chain instead:
 * "everything counts from the first day", exactly as asked.
 */
async function chainStart(userId: string, plan: string, createdAt: Date): Promise<Date> {
	const previous = await prisma.subscription.findMany({
		where: { userId, plan, createdAt: { lt: createdAt } },
		orderBy: { createdAt: "desc" },
		take: 36,
		select: { createdAt: true, expiresAt: true },
	})
	let anchor = createdAt
	for (const row of previous) {
		// Contiguous when the older row had not run out yet (one day of slack for
		// a renewal that landed just after the expiry).
		if (row.expiresAt.getTime() + DAY_MS < anchor.getTime()) break
		anchor = row.createdAt
	}
	return anchor
}

/**
 * The single source of truth for plan, limits and traffic window.
 *
 * Never throws for a Free account: it returns the Free entitlement, which is
 * what "no subscription" means.
 */
export async function resolveEntitlement(
	userId: string,
	at: Date = new Date(),
): Promise<Entitlement> {
	const [user, active] = await Promise.all([
		prisma.user.findUnique({
			where: { id: userId },
			select: { createdAt: true },
		}),
		prisma.subscription.findFirst({
			// Free rows are deliberately excluded: they are not subscriptions.
			where: {
				userId,
				status: "ACTIVE",
				expiresAt: { gt: at },
				plan: { not: FREE_PLAN_CODE },
			},
			orderBy: [{ tier: "desc" }, { expiresAt: "desc" }],
		}),
	])

	const code = active?.plan ?? FREE_PLAN_CODE
	const shape = planShape(code)
	const row = await prisma.plan.findFirst({ where: { code: shape.code } })
	const trafficGb = row ? row.trafficGb : shape.trafficGb
	const anchor = active
		? await chainStart(userId, active.plan, active.createdAt)
		: (user?.createdAt ?? at)

	return {
		planCode: shape.code,
		planName: row?.name && row.name.trim() ? row.name : shape.name,
		badge: planBadge(shape.code),
		tier: active?.tier ?? row?.tier ?? shape.tier,
		subscribed: active !== null,
		subscriptionId: active?.id ?? null,
		source: active?.source ?? null,
		expiresAt: active?.expiresAt ?? null,
		daysLeft: active
			? Math.max(0, Math.ceil((active.expiresAt.getTime() - at.getTime()) / DAY_MS))
			: null,
		maxDevices: row?.maxDevices ?? shape.maxDevices,
		maxSessions: row?.maxSessions ?? shape.maxSessions,
		trafficLimitBytes:
			trafficGb === null || trafficGb === undefined ? null : trafficGb * 1024 * 1024 * 1024,
		period: quotaPeriod(anchor, at),
	}
}

/** The plan half of what clients render. Traffic numbers live in `quota.ts`. */
export function entitlementPayload(ent: Entitlement): Record<string, unknown> {
	return {
		plan: ent.planCode,
		planName: ent.planName,
		badge: ent.badge,
		tier: ent.tier,
		// "Free" is reported as an absent subscription, never as an active one.
		subscribed: ent.subscribed,
		status: ent.subscribed ? "ACTIVE" : "NONE",
		expiresAt: ent.expiresAt ? ent.expiresAt.toISOString() : null,
		daysLeft: ent.daysLeft,
		maxDevices: ent.maxDevices,
		maxSessions: ent.maxSessions,
		trafficLimitBytes: ent.trafficLimitBytes,
		periodStart: ent.period.start.toISOString(),
		periodEnd: ent.period.end.toISOString(),
	}
}
