/**
 * Pure arithmetic for the egress budget: cycle boundaries, alert thresholds and
 * byte formatting.
 *
 * Split out from egressBudget.ts so it can be unit-tested without pulling in
 * Prisma or the Telegram client. The date handling is the part most likely to
 * be wrong and the part least likely to be noticed when it is: a cycle that
 * rolls over on the wrong day still produces plausible-looking numbers.
 */

// Oracle quotes the allowance in decimal terabytes, and so does the invoice.
// Using 2^40 here would silently give us a 10% larger budget than we have.
export const BYTES_PER_TB = 1_000_000_000_000

/**
 * Day-of-month clamped to a month that may be shorter.
 *
 * A subscription that began on the 31st has no anniversary in February; the
 * cycle has to land on the 28th (or 29th) instead, and Date.UTC would otherwise
 * roll the day forward into March.
 */
function clampDay(year: number, month: number, day: number): number {
	const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
	return Math.min(day, lastDay)
}

/**
 * First instant of the billing cycle containing `now`.
 *
 * `anchor` is the date the PAYG subscription began. The allowance resets on its
 * anniversary, so the cycle boundary is the anchor's day-of-month - not the 1st.
 */
export function cycleStart(anchor: Date, now: Date): Date {
	const day = anchor.getUTCDate()
	let year = now.getUTCFullYear()
	let month = now.getUTCMonth()

	let candidate = Date.UTC(year, month, clampDay(year, month, day))
	if (candidate > now.getTime()) {
		// The anniversary this month has not happened yet, so we are still inside
		// the cycle that began last month.
		month -= 1
		if (month < 0) {
			month = 11
			year -= 1
		}
		candidate = Date.UTC(year, month, clampDay(year, month, day))
	}

	// The first cycle is short: it cannot begin before the subscription did.
	const subscriptionStart = Date.UTC(
		anchor.getUTCFullYear(),
		anchor.getUTCMonth(),
		anchor.getUTCDate(),
	)
	return new Date(Math.max(candidate, subscriptionStart))
}

/** First instant of the cycle after the one beginning at `start`. */
export function cycleEnd(start: Date, anchor: Date): Date {
	const day = anchor.getUTCDate()
	let year = start.getUTCFullYear()
	let month = start.getUTCMonth() + 1
	if (month > 11) {
		month = 0
		year += 1
	}
	return new Date(Date.UTC(year, month, clampDay(year, month, day)))
}

/** Alert thresholds in TB, de-duplicated and sorted. "7,8,9,9.5" -> [7,8,9,9.5] */
export function parseThresholds(raw: string): number[] {
	const seen = new Set<number>()
	for (const part of raw.split(",")) {
		const value = Number.parseFloat(part.trim())
		if (Number.isFinite(value) && value > 0) seen.add(value)
	}
	return Array.from(seen).sort((a, b) => a - b)
}

const UNITS = ["B", "KB", "MB", "GB", "TB", "PB"]

/** Human-readable size. Decimal units, to match how Oracle bills. */
export function formatBytes(bytes: number): string {
	if (!Number.isFinite(bytes) || bytes <= 0) return "0 B"
	let value = bytes
	let unit = 0
	while (value >= 1000 && unit < UNITS.length - 1) {
		value /= 1000
		unit += 1
	}
	const rounded = unit === 0 ? Math.round(value) : Number(value.toFixed(2))
	return rounded + " " + (UNITS[unit] ?? "B")
}
