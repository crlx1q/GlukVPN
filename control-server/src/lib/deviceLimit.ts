import { config } from "../config"
import { HttpError } from "./errors"

/**
 * Hard ceiling on how many devices one account can hold.
 *
 * Matches the admin panel's own validation (`maxDevices` is capped at 20 in
 * routes/admin.ts), so an administrator cannot set a number the rest of the
 * server would then quietly refuse to honour.
 */
export const DEVICE_LIMIT_CEILING = 20

/**
 * How many ACTIVE devices this account is allowed.
 *
 * ROUND 28. This used to be `Math.min(user.maxDevices, MAX_DEVICES_PER_USER)`,
 * which made the Pro tier impossible to actually use.
 *
 * The two numbers mean different things:
 *
 *   * `MAX_DEVICES_PER_USER` (env, default 3) is the allowance handed to a
 *     NEW account - registration.ts, cli.ts, seed.ts and admin.ts all use it
 *     that way, as a default.
 *   * `user.maxDevices` is the account's real allowance. billing.ts raises it
 *     to the plan's value on activation:
 *     `maxDevices: Math.max(user.maxDevices, plan.maxDevices)`.
 *
 * Taking the minimum of the two threw the second one away. A paying Pro user
 * (plan max_devices = 5, per price.md) was still cut off after 3 devices, and
 * the only cure was an environment variable nobody would think to change. The
 * per-account allowance is now the authority, bounded by a hard ceiling so a
 * mistyped admin edit cannot mint unlimited slots.
 */
export function effectiveDeviceLimit(user: { maxDevices: number }): number {
	const allowance = Number.isFinite(user.maxDevices)
		? Math.trunc(user.maxDevices)
		: config.MAX_DEVICES_PER_USER
	return Math.max(1, Math.min(allowance, DEVICE_LIMIT_CEILING))
}

/** One row in the "pick a device to sign out" dialog. */
export type DeviceLimitSlot = {
	id: string
	deviceName: string
	platform: string | null
	lastSeen: string | null
	/** True while a tunnel is currently up for this device. */
	connected: boolean
}

export type DeviceLimitDetails = {
	maxDevices: number
	activeDevices: number
	devices: DeviceLimitSlot[]
}

/**
 * A 409 the client can ACT on rather than merely report.
 *
 * The old error was a bare conflict string, so every client could only turn a
 * full account into a dead end: "Device limit reached (3)" and no way forward
 * except finding the account page on another device. The dedicated `code` lets
 * the three clients recognise this case, and `details.devices` is exactly the
 * list the picker renders - so the dialog needs no second round trip, and it
 * works during sign-in, before a device-scoped token exists at all.
 *
 * `maxDevices` is reported so the title can read the account's real allowance
 * (1 on Free, 3 on Basic, 5 on Pro) instead of a hard-coded 5.
 */
export const deviceLimitReached = (details: DeviceLimitDetails): HttpError =>
	new HttpError(
		409,
		"device_limit_reached",
		"Device limit reached (" +
			details.activeDevices +
			"/" +
			details.maxDevices +
			"). Sign out of one of your devices to continue.",
		details,
	)
