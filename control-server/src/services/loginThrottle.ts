import { config } from "../config"
import { prisma } from "../prisma"

export type ThrottleState = {
	locked: boolean
	retryAfterSec: number
	failedByUsername: number
	failedByIp: number
}

// A single IP may legitimately host several devices, so the IP threshold is
// deliberately looser than the per-username one.
const IP_THRESHOLD_MULTIPLIER = 4

export async function checkLoginThrottle(
	username: string,
	ip: string,
): Promise<ThrottleState> {
	const windowStart = new Date(Date.now() - config.LOGIN_LOCKOUT_MINUTES * 60 * 1000)
	const [failedByUsername, failedByIp] = await Promise.all([
		prisma.loginAttempt.count({
			where: { username, success: false, createdAt: { gte: windowStart } },
		}),
		prisma.loginAttempt.count({
			where: { ip, success: false, createdAt: { gte: windowStart } },
		}),
	])

	const locked =
		failedByUsername >= config.LOGIN_MAX_ATTEMPTS ||
		failedByIp >= config.LOGIN_MAX_ATTEMPTS * IP_THRESHOLD_MULTIPLIER

	return {
		locked,
		retryAfterSec: locked ? config.LOGIN_LOCKOUT_MINUTES * 60 : 0,
		failedByUsername,
		failedByIp,
	}
}

export async function recordLoginAttempt(
	username: string,
	ip: string,
	success: boolean,
): Promise<void> {
	await prisma.loginAttempt.create({ data: { username, ip, success } })
	if (success) {
		// A successful login clears the failure counters for that identity.
		await prisma.loginAttempt.deleteMany({
			where: { success: false, OR: [{ username }, { ip }] },
		})
	}
}

/** Housekeeping: keeps the throttling table small. */
export async function purgeOldLoginAttempts(olderThanHours = 24): Promise<number> {
	const cutoff = new Date(Date.now() - olderThanHours * 60 * 60 * 1000)
	const result = await prisma.loginAttempt.deleteMany({
		where: { createdAt: { lt: cutoff } },
	})
	return result.count
}
