import { config } from "../config"

/**
 * Hard ceiling on how many concurrent VPN sessions one account can hold.
 *
 * Matches the admin panel's validation so an administrator cannot set a number
 * the rest of the server would then quietly refuse to honour.
 */
export const SESSION_LIMIT_CEILING = 20

/**
 * How many concurrent ACTIVE sessions this account is allowed.
 *
 * Parallel to `effectiveDeviceLimit` in `deviceLimit.ts`:
 * `config.MAX_CONCURRENT_SESSIONS` (env, default 1) is the default allowance handed
 * to a brand-new Free account upon registration.
 *
 * `user.maxSessions` is the account's real allowance, raised by billing/plan activation:
 * e.g., 3 for Basic, 5 for Pro.
 *
 * The previous logic took `Math.min(user.maxSessions, config.MAX_CONCURRENT_SESSIONS)`.
 * Because MAX_CONCURRENT_SESSIONS defaults to 1 in .env, every paying Pro user
 * was restricted to exactly 1 concurrent connection regardless of their subscription.
 *
 * The per-account allowance (`user.maxSessions`) is now the authority, bounded
 * by SESSION_LIMIT_CEILING.
 */
export function effectiveSessionLimit(user: { maxSessions: number }): number {
	const allowance = Number.isFinite(user.maxSessions)
		? Math.trunc(user.maxSessions)
		: config.MAX_CONCURRENT_SESSIONS
	return Math.max(1, Math.min(allowance, SESSION_LIMIT_CEILING))
}
