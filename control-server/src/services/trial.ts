/**
 * The trial offer: a paid plan for a token rouble, once per account.
 *
 * Why it is a real order and not a free grant:
 *
 *   - a charge of 1 ₽ proves a real card or SBP account, which is the cheapest
 *     filter against somebody minting accounts for free traffic;
 *   - the payment goes through the same gateway, the same webhook and the same
 *     `markOrderPaid` as every other purchase, so there is no second code path
 *     that can hand out a plan;
 *   - and it is exactly the flow a payment provider's reviewer walks through
 *     when they check that the shop works.
 *
 * There is no auto-renewal. The trial subscription simply expires - nothing is
 * stored to charge later and nothing is charged later.
 *
 * Everything the offer does is a row in `trial_offers`, so an administrator can
 * switch it off, move it to Pro, change the length or the sign-up window
 * without a deploy. The .env values only seed that row the first time.
 */
import type { Order, Plan, Prisma, User } from "@prisma/client"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { HttpError } from "../lib/errors"
import { prisma } from "../prisma"
import { type CheckoutResult, createOrder, priceLabel } from "./billing"
import { planShape } from "./entitlements"
import { TABPAY_CURRENCY } from "./tabpay"

/** There is only ever one offer running, so the row has a fixed id. */
export const TRIAL_SETTINGS_ID = "global"
/** `Subscription.source` for a trial: this is how "once per account" is asked. */
export const TRIAL_SOURCE = "trial"
export const TRIAL_PLAN_SUFFIX = "_trial"
/** How many days before the end the account is reminded. */
export const TRIAL_REMINDER_DAYS = 2

const DAY_MS = 24 * 60 * 60 * 1000

/**
 * Display equivalents of the rouble price.
 *
 * The charge is always in roubles - that is the only currency the gateway
 * settles in - but a visitor in Almaty should read the offer in tenge. These
 * are the round marketing figures for "one rouble" (100 ₸, $0.1), not an FX
 * rate, and they scale with the price so changing it in the panel keeps the
 * three numbers consistent.
 */
const EQUIVALENT_RATIO: Record<string, number> = { RUB: 1, KZT: 100, USD: 0.1 }

export type TrialSettings = {
	enabled: boolean
	/** Base plan the trial previews: "basic" or "pro". */
	planCode: string
	days: number
	eligibilityDays: number
	requireTelegram: boolean
	priceKopecks: number
	updatedAt: Date
}

function settingsFrom(row: {
	enabled: boolean
	planCode: string
	days: number
	eligibilityDays: number
	requireTelegram: boolean
	priceKopecks: number
	updatedAt: Date
}): TrialSettings {
	return {
		enabled: row.enabled,
		planCode: row.planCode.trim().toLowerCase(),
		days: row.days,
		eligibilityDays: row.eligibilityDays,
		requireTelegram: row.requireTelegram,
		priceKopecks: row.priceKopecks,
		updatedAt: row.updatedAt,
	}
}

/** The live offer, seeded from .env the first time it is asked for. */
export async function trialSettings(): Promise<TrialSettings> {
	const existing = await prisma.trialOffer.findUnique({ where: { id: TRIAL_SETTINGS_ID } })
	if (existing) return settingsFrom(existing)
	try {
		const created = await prisma.trialOffer.create({
			data: {
				id: TRIAL_SETTINGS_ID,
				enabled: config.TRIAL_OFFER_ENABLED,
				planCode: config.TRIAL_OFFER_PLAN,
				days: config.TRIAL_OFFER_DAYS,
				eligibilityDays: config.TRIAL_OFFER_WINDOW_DAYS,
				requireTelegram: config.TRIAL_OFFER_REQUIRE_TELEGRAM,
				priceKopecks: config.TRIAL_OFFER_PRICE_KOPECKS,
			},
		})
		return settingsFrom(created)
	} catch {
		// Two requests raced to seed it; the other one won.
		const row = await prisma.trialOffer.findUniqueOrThrow({ where: { id: TRIAL_SETTINGS_ID } })
		return settingsFrom(row)
	}
}

export type TrialSettingsPatch = {
	enabled?: boolean
	planCode?: string
	days?: number
	eligibilityDays?: number
	requireTelegram?: boolean
	priceKopecks?: number
}

/** Applies an admin edit and keeps the hidden trial plan in step with it. */
export async function updateTrialSettings(
	patch: TrialSettingsPatch,
	adminId: string,
): Promise<TrialSettings> {
	const current = await trialSettings()
	const planCode = (patch.planCode ?? current.planCode).trim().toLowerCase()
	if (planCode !== "basic" && planCode !== "pro") {
		throw new HttpError(400, "bad_request", "Trial plan must be basic or pro")
	}
	const next = {
		enabled: patch.enabled ?? current.enabled,
		planCode,
		days: patch.days ?? current.days,
		eligibilityDays: patch.eligibilityDays ?? current.eligibilityDays,
		requireTelegram: patch.requireTelegram ?? current.requireTelegram,
		priceKopecks: patch.priceKopecks ?? current.priceKopecks,
	}
	const row = await prisma.trialOffer.update({ where: { id: TRIAL_SETTINGS_ID }, data: next })
	const settings = settingsFrom(row)
	// The plan row carries the length and the price, so it has to follow the
	// settings immediately - otherwise the panel would say 14 days and the
	// checkout would still sell 7.
	await ensureTrialPlan(settings)
	await writeAudit({
		action: "billing.trial.update",
		userId: adminId,
		metadata: { ...next },
	})
	return settings
}

/** The hidden plan the trial sells, e.g. "basic_trial". */
export function trialPlanCode(baseCode: string): string {
	return `${baseCode.trim().toLowerCase()}${TRIAL_PLAN_SUFFIX}`
}

/**
 * Creates or refreshes the hidden plan behind the offer.
 *
 * It mirrors the limits of the plan it previews (a Basic trial *is* Basic for
 * seven days) and stays `isPublic: false` so it can never be bought straight
 * off the pricing page - only through `claimTrial`, which checks eligibility
 * first.
 */
export async function ensureTrialPlan(settings: TrialSettings): Promise<Plan> {
	const base = await prisma.plan.findUnique({ where: { code: settings.planCode } })
	const shape = planShape(settings.planCode)
	const code = trialPlanCode(settings.planCode)
	const data = {
		name: base?.name ?? shape.name,
		tier: base?.tier ?? shape.tier,
		days: settings.days,
		priceMinor: settings.priceKopecks,
		currency: TABPAY_CURRENCY,
		maxDevices: base?.maxDevices ?? shape.maxDevices,
		maxSessions: base?.maxSessions ?? shape.maxSessions,
		trafficGb: base?.trafficGb ?? shape.trafficGb,
		features: (base?.features ?? []) as Prisma.InputJsonValue,
		featured: false,
		active: true,
		isPublic: false,
		sortOrder: 90,
	}
	const plan = await prisma.plan.upsert({
		where: { code },
		update: data,
		create: { code, ...data },
	})

	// Display prices for the other markets. The charge is still in roubles.
	for (const [currency, ratio] of Object.entries(EQUIVALENT_RATIO)) {
		const priceMinor = Math.max(1, Math.round(settings.priceKopecks * ratio))
		await prisma.planPrice.upsert({
			where: { planId_currency: { planId: plan.id, currency } },
			update: { priceMinor },
			create: { planId: plan.id, currency, priceMinor },
		})
	}
	return plan
}

export type TrialReason =
	| "ok"
	| "offer_disabled"
	| "sign_in_required"
	| "telegram_required"
	| "window_passed"
	| "already_used"
	| "already_subscribed"

export type TrialEligibility = {
	eligible: boolean
	reason: TrialReason
	/** When the account was created, for "you have N days left to claim". */
	registeredAt: string | null
	eligibleUntil: string | null
	daysLeft: number | null
}

/**
 * Whether this account may claim the offer.
 *
 * "New" is deliberately three separate conditions: created within the window,
 * verified on Telegram (one phone, one human), and never having had a trial or
 * a running paid plan. A signed-out visitor is not refused - the site still
 * shows the offer and asks them to sign up, which is the point of the banner.
 */
export async function trialEligibility(
	user: User | null,
	settings: TrialSettings,
	at: Date = new Date(),
): Promise<TrialEligibility> {
	const registeredAt = user?.createdAt ?? null
	const deadline = registeredAt
		? new Date(registeredAt.getTime() + settings.eligibilityDays * DAY_MS)
		: null
	const daysLeft = deadline
		? Math.max(0, Math.ceil((deadline.getTime() - at.getTime()) / DAY_MS))
		: null
	const base = {
		registeredAt: registeredAt?.toISOString() ?? null,
		eligibleUntil: deadline?.toISOString() ?? null,
		daysLeft,
	}

	if (!settings.enabled) return { eligible: false, reason: "offer_disabled", ...base }
	if (!user) return { eligible: false, reason: "sign_in_required", ...base }
	if (settings.requireTelegram && !user.telegramVerifiedAt) {
		return { eligible: false, reason: "telegram_required", ...base }
	}
	if (deadline && deadline.getTime() <= at.getTime()) {
		return { eligible: false, reason: "window_passed", ...base }
	}

	// Ever had one? Both halves matter: the subscription answers "was a trial
	// granted", the order answers "was one paid for" even if it was later
	// superseded by a bigger plan.
	const usedGrant = await prisma.subscription.count({
		where: { userId: user.id, source: TRIAL_SOURCE },
	})
	const usedOrder = await prisma.order.count({
		where: { userId: user.id, status: "PAID", plan: { code: { endsWith: TRIAL_PLAN_SUFFIX } } },
	})
	if (usedGrant > 0 || usedOrder > 0) return { eligible: false, reason: "already_used", ...base }

	// Somebody already paying does not need a preview of what they have.
	const active = await prisma.subscription.count({
		where: { userId: user.id, status: "ACTIVE", expiresAt: { gt: at } },
	})
	if (active > 0) return { eligible: false, reason: "already_subscribed", ...base }

	return { eligible: true, reason: "ok", ...base }
}

export type TrialMoney = { currency: string; minor: number; label: string }

function money(currency: string, minor: number): TrialMoney {
	return { currency, minor, label: priceLabel(minor, currency) }
}

export type TrialOfferView = {
	enabled: boolean
	/** The plan being previewed, and the hidden plan that is actually sold. */
	planCode: string
	planName: string
	trialPlanCode: string
	days: number
	eligibilityDays: number
	requireTelegram: boolean
	/** What the visitor sees, in their own currency. */
	price: TrialMoney
	/** What is actually charged. Always roubles while TabPay is the gateway. */
	charge: TrialMoney
	equivalents: TrialMoney[]
	/**
	 * The dates the /trial page draws, computed here so every client agrees on
	 * them and nothing depends on a correct clock in the browser.
	 */
	timeline: {
		startsAt: string
		reminderAt: string
		endsAt: string
		reminderDays: number
	}
	/** No recurring charge exists: the trial ends, it does not renew. */
	autoRenew: false
	eligibility: TrialEligibility
}

/** Everything the site needs to render the offer for one visitor. */
export async function trialOffer(params: {
	user: User | null
	currency?: string | null
	at?: Date
}): Promise<TrialOfferView> {
	const at = params.at ?? new Date()
	const settings = await trialSettings()
	const eligibility = await trialEligibility(params.user, settings, at)
	const base = await prisma.plan.findUnique({ where: { code: settings.planCode } })
	const shape = planShape(settings.planCode)

	const wanted = (params.currency ?? "").trim().toUpperCase()
	const display = EQUIVALENT_RATIO[wanted] === undefined ? TABPAY_CURRENCY : wanted
	const displayMinor = Math.max(1, Math.round(settings.priceKopecks * (EQUIVALENT_RATIO[display] ?? 1)))

	const endsAt = new Date(at.getTime() + settings.days * DAY_MS)
	// The reminder lands two days before the end - unless the trial is shorter
	// than that, in which case it lands the moment it starts.
	const reminderAt = new Date(
		Math.max(at.getTime(), endsAt.getTime() - TRIAL_REMINDER_DAYS * DAY_MS),
	)

	return {
		enabled: settings.enabled,
		planCode: settings.planCode,
		planName: base?.name ?? shape.name,
		trialPlanCode: trialPlanCode(settings.planCode),
		days: settings.days,
		eligibilityDays: settings.eligibilityDays,
		requireTelegram: settings.requireTelegram,
		price: money(display, displayMinor),
		charge: money(TABPAY_CURRENCY, settings.priceKopecks),
		equivalents: Object.keys(EQUIVALENT_RATIO).map((currency) =>
			money(currency, Math.max(1, Math.round(settings.priceKopecks * (EQUIVALENT_RATIO[currency] ?? 1)))),
		),
		timeline: {
			startsAt: at.toISOString(),
			reminderAt: reminderAt.toISOString(),
			endsAt: endsAt.toISOString(),
			reminderDays: TRIAL_REMINDER_DAYS,
		},
		autoRenew: false,
		eligibility,
	}
}

const REFUSAL_TEXT: Record<TrialReason, string> = {
	ok: "",
	offer_disabled: "The trial offer is not running right now",
	sign_in_required: "Sign in to claim the trial",
	telegram_required: "Confirm your Telegram account to claim the trial",
	window_passed: "The trial is only available to new accounts",
	already_used: "This account has already used the trial",
	already_subscribed: "This account already has an active subscription",
}

/**
 * Turns an eligible account into a real order for the hidden trial plan.
 *
 * Eligibility is checked here and nowhere else that matters: the site's copy
 * is a courtesy, this is the gate.
 */
export async function claimTrial(params: {
	user: User
	ip?: string | null
}): Promise<{ order: Order & { plan: Plan }; checkout: CheckoutResult; days: number }> {
	const settings = await trialSettings()
	const eligibility = await trialEligibility(params.user, settings)
	if (!eligibility.eligible) {
		throw new HttpError(409, `trial_${eligibility.reason}`, REFUSAL_TEXT[eligibility.reason])
	}

	const plan = await ensureTrialPlan(settings)
	const result = await createOrder({
		user: params.user,
		planCode: plan.code,
		ip: params.ip ?? null,
		// The offer is priced in roubles; the equivalents are display only.
		currency: TABPAY_CURRENCY,
		allowHidden: true,
		source: TRIAL_SOURCE,
	})
	await writeAudit({
		action: "billing.trial.claim",
		userId: params.user.id,
		ip: params.ip ?? null,
		metadata: {
			orderId: result.order.id,
			plan: plan.code,
			days: settings.days,
			amountMinor: result.order.amountMinor,
		},
	})
	return { ...result, days: settings.days }
}
