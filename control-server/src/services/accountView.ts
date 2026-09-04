import type { Subscription, User } from "@prisma/client"
import { prisma } from "../prisma"

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
		isAdmin: user.isAdmin,
		isTester: user.isTester,
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

const PLAN_NAMES: Record<string, string> = {
	free: "Free",
	basic: "Basic",
	pro: "Pro",
	test: "Test",
}

export function planDisplayName(code: string): string {
	return PLAN_NAMES[code.toLowerCase()] ?? code
}

export function subscriptionPayload(
	subscription: Subscription | null,
): Record<string, unknown> | null {
	if (!subscription) return null
	const msLeft = subscription.expiresAt.getTime() - Date.now()
	return {
		status: subscription.status,
		plan: subscription.plan,
		planName: planDisplayName(subscription.plan),
		tier: subscription.tier,
		source: subscription.source,
		expiresAt: subscription.expiresAt.toISOString(),
		daysLeft: Math.max(0, Math.ceil(msLeft / (24 * 60 * 60 * 1000))),
	}
}

/** The subscription clients should display: the latest-expiring one. */
export async function latestSubscription(userId: string): Promise<Subscription | null> {
	return prisma.subscription.findFirst({
		where: { userId },
		orderBy: [{ expiresAt: "desc" }, { tier: "desc" }],
	})
}
