import type { Subscription, User } from "@prisma/client"
import { prisma } from "../prisma"
import {
	FREE_PLAN_CODE,
	entitlementPayload,
	entitlementRevision,
	planBadge,
	planDisplayName,
	resolveEntitlement,
} from "./entitlements"

/**
 * The one shape every sign-in surface returns for a user and a subscription.
 *
 * `/api/auth/login`, `/api/auth/me`, the link flow and Google sign-in used to
 * each spell this out by hand, which is how a field added in one place went
 * missing in another. One function per object, used everywhere.
 */

export function userPayload(user: User): Record<string, unknown> {
	return {
		id: user.id,
		publicId: user.publicId,
		username: user.username,
		email: user.email,
		emailVerified: user.emailVerifiedAt !== null,
		// With the Telegram step optional, "verified account" stopped meaning the
		// email code: an address is free and infinite, a phone shared through
		// Telegram is not. So the badge every client draws - and the trial - hang
		// on the phone step, while an email-only account stays real and usable,
		// just unverified until the link is made from Settings.
		telegramLinked: user.telegramId !== null,
		telegramVerified: user.telegramVerifiedAt !== null,
		verified: user.telegramVerifiedAt !== null,
		isAdmin: user.isAdmin,
		isTester: user.isTester,
		isSupport: user.isSupport,
		status: user.status,
		maxDevices: user.maxDevices,
		maxConcurrentSessions: user.maxSessions,
		createdAt: user.createdAt.toISOString(),
		// Country/region only — the app draws the marker at a country centre.
		origin: {
			country: user.lastCountry,
			countryCode: user.lastCountryCode,
			region: user.lastRegion,
		},
	}
}

// Plan names, tiers, badges and limits all live in one matrix now.
export { planBadge, planDisplayName }

const DAY_MS = 24 * 60 * 60 * 1000

/**
 * One subscription row as clients see it.
 *
 * `at` is a parameter instead of `Date.now()` so a payload can never disagree
 * with the entitlement sent beside it.
 */
export function subscriptionPayload(
	subscription: Subscription | null,
	at: Date = new Date(),
): Record<string, unknown> | null {
	if (!subscription) return null
	// Free is not a subscription. A legacy "free" row must read as "no plan",
	// otherwise clients print nonsense like "Free, active, 790 days left".
	if (subscription.plan.trim().toLowerCase() === FREE_PLAN_CODE) return null
	const msLeft = subscription.expiresAt.getTime() - at.getTime()
	// The clock decides, not the column. `monitor` sweeps run-out rows every few
	// minutes, so until one runs a row can sit at ACTIVE with a date already in
	// the past - and a client that trusted the column drew a live plan from it.
	const status =
		subscription.status === "ACTIVE" && msLeft <= 0 ? "EXPIRED" : subscription.status
	const active = status === "ACTIVE"
	return {
		id: subscription.id,
		status,
		// Existence and validity are two different questions. A row exists from
		// the first purchase onwards and that is not what "subscribed" means, so
		// every client reads this flag rather than re-deriving it from a status
		// string and a date in its own timezone - four clients, four answers.
		active,
		plan: subscription.plan,
		planName: planDisplayName(subscription.plan),
		// Which badge every client draws next to the nickname.
		badge: planBadge(subscription.plan),
		tier: subscription.tier,
		source: subscription.source,
		expiresAt: subscription.expiresAt.toISOString(),
		// Zero once it is over: "0 days left" beside a date in 2029 is what made
		// the account page unreadable.
		daysLeft: active ? Math.max(0, Math.ceil(msLeft / DAY_MS)) : 0,
	}
}

/**
 * The row that is valid *right now*, or null.
 *
 * Same filter and same ordering as `resolveEntitlement`, deliberately: these
 * two answers are rendered side by side, and while they disagreed the account
 * page could show "Free" next to a Pro badge.
 */
export async function activeSubscription(
	userId: string,
	at: Date = new Date(),
): Promise<Subscription | null> {
	return prisma.subscription.findFirst({
		where: { userId, status: "ACTIVE", expiresAt: { gt: at }, plan: { not: FREE_PLAN_CODE } },
		orderBy: [{ tier: "desc" }, { expiresAt: "desc" }],
	})
}

/**
 * The newest row in the account's history, whatever state it is in.
 *
 * History, never the current plan. Handing this out as "the subscription" is
 * the whole bug: a revoked beta row running to 2029 outranked the Pro month
 * that was actually paid for, so the website printed "Free - DISABLED - 0 days
 * - 6 February 2029" while the admin panel had it right all along.
 */
export async function latestSubscription(userId: string): Promise<Subscription | null> {
	return prisma.subscription.findFirst({
		// Free rows are skipped on purpose: they are not subscriptions.
		where: { userId, plan: { not: FREE_PLAN_CODE } },
		orderBy: [{ createdAt: "desc" }, { expiresAt: "desc" }],
	})
}

/**
 * Everything a sign-in surface says about a plan, in one object.
 *
 * Spread into the reply, so `/api/auth/login`, `/api/auth/me`, Google sign-in
 * and the link flow cannot drift apart again:
 *
 * - `subscription` - the plan in force, or `null` for Free. This is what
 *   clients render, and nothing else.
 * - `lastSubscription` - what came before, so an expired plan can be named
 *   ("Pro ended on 14 October") instead of leaving a Free page unexplained.
 *   Absent while it is the active row.
 * - `entitlement` - the limits the server will actually enforce.
 * - `subscriptionRevision` - changes whenever any of the above does.
 */
export async function accountSubscriptionPayload(
	userId: string,
	at: Date = new Date(),
): Promise<{
	subscription: Record<string, unknown> | null
	lastSubscription: Record<string, unknown> | null
	entitlement: Record<string, unknown>
	subscriptionRevision: string
}> {
	const [active, last, entitlement] = await Promise.all([
		activeSubscription(userId, at),
		latestSubscription(userId),
		resolveEntitlement(userId, at),
	])
	return {
		subscription: subscriptionPayload(active, at),
		lastSubscription: last && last.id !== active?.id ? subscriptionPayload(last, at) : null,
		entitlement: entitlementPayload(entitlement),
		subscriptionRevision: entitlementRevision(entitlement),
	}
}
