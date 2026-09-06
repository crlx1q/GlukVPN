/**
 * Monthly traffic quota: how much of the plan's allowance is left.
 *
 * Two properties matter and both come from where the traffic actually is:
 *
 * 1. **The node counts, the server decides, the client only renders.** Usage is
 *    read from `traffic_usage_buckets`, which the nodes fill through the
 *    reporting endpoint - the same counters the analytics page is built from.
 *    Nothing here trusts a number sent by a phone, a desktop app or the
 *    extension, so a patched client cannot award itself more gigabytes.
 * 2. **The window is anchored to the subscription, not to the calendar.** A
 *    plan started on the 17th resets on a multiple of 30 days from the 17th, so
 *    a three-month term resets three times and a year resets twelve. That
 *    arithmetic lives in `entitlements.quotaPeriod`; this module only asks it
 *    which window contains "now" and adds up the bytes inside it.
 *
 * A Free account has no subscription, so its window is anchored to the day the
 * account was created - Free is the absence of a plan, not a plan with a start
 * date.
 */
import { prisma } from "../prisma"
import { type Entitlement, type QuotaPeriod, resolveEntitlement } from "./entitlements"

export type QuotaStatus = {
	entitlement: Entitlement
	period: QuotaPeriod
	/** Bytes the nodes have attributed to this account inside the window. */
	usedBytes: number
	/** `null` when the plan is uncapped. */
	limitBytes: number | null
	/** `null` when uncapped; never negative. */
	remainingBytes: number | null
	/** 0..1, clamped. `0` when uncapped so a bar can render without branching. */
	usedFraction: number
	/** True when the account has spent its allowance and must wait for the reset. */
	exceeded: boolean
}

/**
 * Bytes the nodes recorded for this account inside one window.
 *
 * Buckets are hourly and keyed by `(user, device, bucketStart)`, so summing
 * them covers every device on the account, including ones that have since been
 * removed - the allowance belongs to the account, not to a device.
 */
export async function usedBytesInPeriod(userId: string, period: QuotaPeriod): Promise<number> {
	const sum = await prisma.trafficUsageBucket.aggregate({
		where: { userId, bucketStart: { gte: period.start, lt: period.end } },
		_sum: { uploadBytes: true, downloadBytes: true },
	})
	// BigInt in, number out: at these magnitudes a double is exact well past any
	// plan we sell (2^53 bytes is ~9 PB), and every consumer is JSON anyway.
	const up = sum._sum.uploadBytes ?? BigInt(0)
	const down = sum._sum.downloadBytes ?? BigInt(0)
	return Number(up) + Number(down)
}

/** Plan, window and usage in one answer. Never throws for a Free account. */
export async function quotaStatus(userId: string, at: Date = new Date()): Promise<QuotaStatus> {
	const entitlement = await resolveEntitlement(userId, at)
	return quotaStatusFor(userId, entitlement)
}

/** Same, when the caller already resolved the entitlement. */
export async function quotaStatusFor(
	userId: string,
	entitlement: Entitlement,
): Promise<QuotaStatus> {
	const period = entitlement.period
	const usedBytes = await usedBytesInPeriod(userId, period)
	const limitBytes = entitlement.trafficLimitBytes
	const remainingBytes = limitBytes === null ? null : Math.max(0, limitBytes - usedBytes)
	return {
		entitlement,
		period,
		usedBytes,
		limitBytes,
		remainingBytes,
		usedFraction:
			limitBytes === null || limitBytes <= 0 ? 0 : Math.min(1, usedBytes / limitBytes),
		exceeded: limitBytes !== null && usedBytes >= limitBytes,
	}
}

/**
 * What every client renders as "234 MB of 5 GB".
 *
 * Bytes rather than a formatted string: the phone, the desktop app, the
 * extension and the site each format in their own language, and a server-side
 * "234 МБ" would be wrong on half of them. `resetAt` is the end of the window,
 * so a blocked client can say when it will work again instead of guessing.
 */
export function quotaPayload(status: QuotaStatus): Record<string, unknown> {
	return {
		usedBytes: status.usedBytes,
		limitBytes: status.limitBytes,
		remainingBytes: status.remainingBytes,
		// Percent is derived here too, so four clients cannot round it four ways.
		usedPercent: Math.round(status.usedFraction * 1000) / 10,
		unlimited: status.limitBytes === null,
		exceeded: status.exceeded,
		periodStart: status.period.start.toISOString(),
		periodEnd: status.period.end.toISOString(),
		resetAt: status.period.end.toISOString(),
		periodIndex: status.period.index,
		periodDays: Math.round(
			(status.period.end.getTime() - status.period.start.getTime()) / (24 * 60 * 60 * 1000),
		),
	}
}

/** Close reason used everywhere a tunnel is cut for spending the allowance. */
export const TRAFFIC_LIMIT_REASON = "traffic_limit"

/**
 * Accounts that have spent their allowance and still hold an open session.
 *
 * Used by the monitor to cut tunnels between connects: enforcing only at
 * connect time would let one long session run past the limit forever, which is
 * exactly the hole that made the client the source of truth in the first place.
 * One query per account with a live session, and only accounts that actually
 * have a cap are considered.
 */
export async function usersOverQuota(at: Date = new Date()): Promise<
	Array<{ userId: string; usedBytes: number; limitBytes: number; resetAt: Date }>
> {
	const live = await prisma.session.findMany({
		where: { status: { in: ["PENDING", "ACTIVE"] } },
		distinct: ["userId"],
		select: { userId: true },
	})
	const over: Array<{ userId: string; usedBytes: number; limitBytes: number; resetAt: Date }> = []
	for (const row of live) {
		const status = await quotaStatus(row.userId, at)
		if (status.exceeded && status.limitBytes !== null) {
			over.push({
				userId: row.userId,
				usedBytes: status.usedBytes,
				limitBytes: status.limitBytes,
				resetAt: status.period.end,
			})
		}
	}
	return over
}
