/**
 * Outbound-traffic budget against Oracle's always-free allowance.
 *
 * The allowance resets on the anniversary of the PAYG subscription, not on the
 * first of the month, so every window here is anchored to
 * OCI_BILLING_CYCLE_START. Getting that wrong is not a rounding error: an
 * account that started on the 20th would appear to reset twenty days early and
 * the alerts would fire long after the traffic was already paid for.
 *
 * Thresholds are announced once per cycle. The record of what has already been
 * announced lives in the database rather than in memory, because the poll
 * interval is minutes and a deploy restart would otherwise re-send every alert
 * the cycle had already passed.
 */
import type { FastifyInstance } from "fastify"

import { config } from "../config"
import { prisma } from "../prisma"
import {
	BYTES_PER_TB,
	cycleEnd,
	cycleStart,
	formatBytes,
	parseThresholds,
} from "./egressBudgetMath"
import {
	ociConfigured,
	summarizeCharges,
	summarizeEgressBytes,
	type TimeWindow,
} from "./ociClient"

import { sendTelegramMessage } from "./telegramBot"

// The cycle arithmetic and the byte formatting are pure, and are unit-tested on
// their own; re-exported here so callers have one place to import from.
export { cycleEnd, cycleStart, formatBytes, parseThresholds }

function anchorDate(): Date | null {
	const raw = config.OCI_BILLING_CYCLE_START.trim()
	if (!raw) return null
	const parsed = new Date(raw)
	return Number.isNaN(parsed.getTime()) ? null : parsed
}

function budgetBytes(): number {
	return config.OCI_EGRESS_BUDGET_TB * BYTES_PER_TB
}

/** True when the module has everything it needs to actually poll. */
export function egressBudgetConfigured(): boolean {
	return ociConfigured() && anchorDate() !== null
}

/** The current cycle, or null when no anchor date is configured. */
export function currentWindow(now: Date = new Date()): TimeWindow | null {
	const anchor = anchorDate()
	if (!anchor) return null
	const start = cycleStart(anchor, now)
	return { start, end: cycleEnd(start, anchor) }
}

async function rowForCycle(window: TimeWindow) {
	return prisma.egressBudgetCycle.upsert({
		where: { cycleStart: window.start },
		update: {},
		create: {
			cycleStart: window.start,
			cycleEnd: window.end,
			bytesOut: BigInt(0),
			alertedTb: [],
		},
	})
}

function alreadyAlerted(raw: unknown): number[] {
	if (!Array.isArray(raw)) return []
	return raw.filter((value): value is number => typeof value === "number")
}

export type EgressBudgetView = {
	/** False when credentials or the cycle anchor are missing. */
	configured: boolean
	cycleStart: string | null
	cycleEnd: string | null
	usedBytes: number
	remainingBytes: number
	budgetBytes: number
	usedPercent: number
	usedLabel: string
	remainingLabel: string
	budgetLabel: string
	thresholdsTb: number[]
	alertedTb: number[]
	charges: { amount: number; currency: string } | null
	lastPolledAt: string | null
	lastError: string | null
}

/** Read model for the admin dashboard. Never throws, never calls Oracle. */
export async function egressBudgetView(
	now: Date = new Date(),
): Promise<EgressBudgetView> {
	const thresholds = parseThresholds(config.OCI_EGRESS_ALERT_TB)
	const budget = budgetBytes()
	const window = currentWindow(now)

	const empty: EgressBudgetView = {
		configured: egressBudgetConfigured(),
		cycleStart: window ? window.start.toISOString() : null,
		cycleEnd: window ? window.end.toISOString() : null,
		usedBytes: 0,
		remainingBytes: budget,
		budgetBytes: budget,
		usedPercent: 0,
		usedLabel: formatBytes(0),
		remainingLabel: formatBytes(budget),
		budgetLabel: formatBytes(budget),
		thresholdsTb: thresholds,
		alertedTb: [],
		charges: null,
		lastPolledAt: null,
		lastError: null,
	}
	if (!window) return empty

	const row = await prisma.egressBudgetCycle.findUnique({
		where: { cycleStart: window.start },
	})
	if (!row) return empty

	const used = Number(row.bytesOut)
	const remaining = Math.max(0, budget - used)
	return {
		...empty,
		usedBytes: used,
		remainingBytes: remaining,
		usedPercent: budget > 0 ? Math.round((used / budget) * 1000) / 10 : 0,
		usedLabel: formatBytes(used),
		remainingLabel: formatBytes(remaining),
		alertedTb: alreadyAlerted(row.alertedTb),
		charges:
			row.chargedAmount === null
				? null
				: {
						amount: Number(row.chargedAmount),
						currency: row.chargedCurrency ?? "USD",
					},
		lastPolledAt: row.lastPolledAt ? row.lastPolledAt.toISOString() : null,
		lastError: row.lastError,
	}
}

async function alert(text: string, logger: FastifyInstance["log"]): Promise<void> {
	const chatId = config.TELEGRAM_ALERT_CHAT_ID.trim()
	if (!chatId) {
		// Worth a warning rather than silence: the operator asked for alerts and
		// the threshold was genuinely crossed, so a missing chat id is a
		// misconfiguration and not a preference.
		logger.warn({}, "egress_alert_no_chat_id")
		return
	}
	try {
		await sendTelegramMessage(chatId, text)
	} catch (error) {
		logger.error({ err: error }, "egress_alert_send_failed")
	}
}

export type EgressTickResult = {
	polled: boolean
	usedBytes: number
	alertsSent: number
	chargesFlagged: boolean
}

/**
 * One poll: read the meter, store it, announce any threshold newly crossed.
 *
 * Failures are recorded on the cycle row instead of being thrown away, so the
 * admin dashboard can say "last poll failed, and why" rather than quietly
 * showing a stale number that looks current.
 */
export async function runEgressBudgetTick(
	logger: FastifyInstance["log"],
	now: Date = new Date(),
): Promise<EgressTickResult> {
	const idle: EgressTickResult = {
		polled: false,
		usedBytes: 0,
		alertsSent: 0,
		chargesFlagged: false,
	}
	const window = currentWindow(now)
	if (!window || !ociConfigured()) return idle

	const row = await rowForCycle(window)

	let used: number
	try {
		// The meter is read up to "now", not to the end of the cycle: asking for
		// datapoints in the future returns nothing useful and wastes the window.
		used = await summarizeEgressBytes({ start: window.start, end: now })
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error)
		logger.error({ err: error }, "egress_budget_poll_failed")
		await prisma.egressBudgetCycle.update({
			where: { id: row.id },
			data: { lastPolledAt: now, lastError: message.slice(0, 500) },
		})
		return idle
	}

	// A cycle total can only grow. If OCI answers with less than we already
	// recorded - a partial response, or a metric gap - keep the larger figure so
	// an alert is never un-sent and the dashboard never walks backwards.
	const stored = Math.max(used, Number(row.bytesOut))
	const budget = budgetBytes()
	const usedTb = stored / BYTES_PER_TB

	const announced = alreadyAlerted(row.alertedTb)
	const thresholds = parseThresholds(config.OCI_EGRESS_ALERT_TB)
	const crossed = thresholds.filter(
		(threshold) => usedTb >= threshold && !announced.includes(threshold),
	)

	let charges: { amount: number; currency: string } | null = null
	if (config.OCI_USAGE_CHECK_ENABLED) {
		try {
			charges = await summarizeCharges({ start: window.start, end: now })
		} catch (error) {
			// A missing Usage API permission must not stop traffic accounting.
			logger.warn({ err: error }, "egress_budget_usage_check_failed")
		}
	}

	const chargesFlagged =
		charges !== null && charges.amount > 0 && row.chargesAlertedAt === null

	await prisma.egressBudgetCycle.update({
		where: { id: row.id },
		data: {
			cycleEnd: window.end,
			bytesOut: BigInt(Math.round(stored)),
			lastPolledAt: now,
			lastError: null,
			alertedTb: [...announced, ...crossed].sort((a, b) => a - b),
			...(charges
				? { chargedAmount: charges.amount, chargedCurrency: charges.currency }
				: {}),
			...(chargesFlagged ? { chargesAlertedAt: now } : {}),
		},
	})

	for (const threshold of crossed) {
		const remaining = Math.max(0, budget - stored)
		await alert(
			"\u26a0\ufe0f <b>GlukVPN</b>: \u0438\u0441\u0445\u043e\u0434\u044f\u0449\u0438\u0439 \u0442\u0440\u0430\u0444\u0438\u043a " +
				threshold +
				" \u0422\u0411.\n\n" +
				"\u0418\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u043d\u043e: <b>" +
				formatBytes(stored) +
				"</b> \u0438\u0437 " +
				formatBytes(budget) +
				"\n\u041e\u0441\u0442\u0430\u043b\u043e\u0441\u044c: <b>" +
				formatBytes(remaining) +
				"</b>\n\u0426\u0438\u043a\u043b \u0434\u043e: " +
				window.end.toISOString().slice(0, 10),
			logger,
		)
	}

	if (chargesFlagged && charges) {
		await alert(
			"\ud83d\udcb0 <b>GlukVPN</b>: Oracle \u043d\u0430\u0447\u0438\u0441\u043b\u0438\u043b " +
				charges.amount +
				" " +
				charges.currency +
				" \u0432 \u044d\u0442\u043e\u043c \u0446\u0438\u043a\u043b\u0435.\n\n" +
				"\u041e\u0436\u0438\u0434\u0430\u043b\u043e\u0441\u044c 0.00 \u2014 \u0447\u0442\u043e-\u0442\u043e \u0432\u044b\u0448\u043b\u043e \u0437\u0430 \u0440\u0430\u043c\u043a\u0438 Always Free.",
			logger,
		)
	}

	if (crossed.length > 0) {
		logger.warn({ usedTb, crossed }, "egress_budget_threshold_crossed")
	}

	return {
		polled: true,
		usedBytes: stored,
		alertsSent: crossed.length + (chargesFlagged ? 1 : 0),
		chargesFlagged,
	}
}

export type EgressBudgetHandle = { stop: () => void }

/**
 * Start the background poll. Safe to call unconfigured: it says so once in the
 * log and returns a handle that does nothing, so prod, beta and a dev checkout
 * all share one code path and one env template.
 */
export function startEgressBudget(app: FastifyInstance): EgressBudgetHandle {
	if (!egressBudgetConfigured()) {
		app.log.info(
			{ credentials: ociConfigured(), anchor: anchorDate() !== null },
			"egress_budget_disabled",
		)
		return { stop: () => {} }
	}

	let running = false
	const tick = async (): Promise<void> => {
		if (running) return
		running = true
		try {
			const result = await runEgressBudgetTick(app.log)
			if (result.polled) {
				app.log.debug({ egress: result }, "egress_budget_tick")
			}
		} catch (error) {
			app.log.error({ err: error }, "egress_budget_tick_failed")
		} finally {
			running = false
		}
	}

	void tick()
	const timer = setInterval(
		() => {
			void tick()
		},
		config.OCI_POLL_INTERVAL_MIN * 60 * 1000,
	)
	// Never keep the process alive just for the meter.
	timer.unref()

	return { stop: () => clearInterval(timer) }
}
