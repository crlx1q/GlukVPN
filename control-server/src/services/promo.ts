/**
 * Promo codes: a percentage off one order, checked on the server.
 *
 * Two rules keep this honest:
 *
 * 1. **The discount is applied to the amount the gateway is asked to charge**,
 *    never to a number the browser sent. A client can type a code; it cannot
 *    decide what it is worth.
 * 2. **A code is only consumed when the money arrives.** Validation happens at
 *    checkout, redemption is written by `markOrderPaid`, so an abandoned
 *    checkout does not burn a single-use code and a retried webhook does not
 *    burn it twice (the redemption row is unique per order).
 *
 * Only orders that we charge ourselves can carry a code: a "manual" order is
 * settled outside the system, so its final amount is not ours to promise.
 */
import type { PromoCode } from "@prisma/client"
import { HttpError } from "../lib/errors"
import { prisma } from "../prisma"

export type PromoView = {
	id: string
	code: string
	description: string | null
	percentOff: number
	active: boolean
	startsAt: string | null
	endsAt: string | null
	maxRedemptions: number | null
	perUserLimit: number
	/** Empty = every paid plan. */
	planCodes: string[]
	redeemedCount: number
	createdAt: string
}

/** Codes are stored and compared upper-case: "tiktok" is TIKTOK. */
export function normalizePromoCode(raw: string): string {
	return raw.trim().toUpperCase().slice(0, 32)
}

export function promoPlanCodes(promo: PromoCode): string[] {
	if (!Array.isArray(promo.planCodes)) return []
	return (promo.planCodes as unknown[])
		.map((item) => String(item).trim().toLowerCase())
		.filter((item) => item.length > 0)
}

export function promoView(promo: PromoCode): PromoView {
	return {
		id: promo.id,
		code: promo.code,
		description: promo.description,
		percentOff: promo.percentOff,
		active: promo.active,
		startsAt: promo.startsAt?.toISOString() ?? null,
		endsAt: promo.endsAt?.toISOString() ?? null,
		maxRedemptions: promo.maxRedemptions,
		perUserLimit: promo.perUserLimit,
		planCodes: promoPlanCodes(promo),
		redeemedCount: promo.redeemedCount,
		createdAt: promo.createdAt.toISOString(),
	}
}

export async function findPromo(code: string): Promise<PromoCode | null> {
	const normalized = normalizePromoCode(code)
	if (!normalized) return null
	return prisma.promoCode.findUnique({ where: { code: normalized } })
}

/**
 * Machine-readable refusals: the site turns each code into its own sentence,
 * in the visitor's language, instead of showing a translated server string.
 */
function refuse(code: string, message: string): HttpError {
	return new HttpError(400, code, message)
}

export type PromoApplication = {
	promo: PromoCode
	percentOff: number
	/** How much comes off, in minor units. */
	discountMinor: number
	/** What is left to charge, in minor units. */
	amountMinor: number
}

/**
 * Validates a code for one user and one plan and returns the discounted
 * amount. Throws an `HttpError` whose `code` says exactly why, so nothing has
 * to be inferred from the text.
 */
export async function applyPromo(params: {
	code: string
	userId: string
	planCode: string
	amountMinor: number
	currency: string
	/** The gateway's floor; a discount may not push the charge below it. */
	minimumMinor?: number
	at?: Date
}): Promise<PromoApplication> {
	const at = params.at ?? new Date()
	const promo = await findPromo(params.code)
	if (!promo) throw refuse("promo_not_found", "Promo code not found")
	if (!promo.active) throw refuse("promo_inactive", "Promo code is not active")
	if (promo.startsAt && promo.startsAt.getTime() > at.getTime()) {
		throw refuse("promo_not_started", "Promo code is not active yet")
	}
	if (promo.endsAt && promo.endsAt.getTime() <= at.getTime()) {
		throw refuse("promo_expired", "Promo code has expired")
	}

	const plans = promoPlanCodes(promo)
	if (plans.length > 0 && !plans.includes(params.planCode.trim().toLowerCase())) {
		throw refuse("promo_plan_not_eligible", "Promo code does not apply to this plan")
	}

	if (promo.maxRedemptions !== null && promo.redeemedCount >= promo.maxRedemptions) {
		throw refuse("promo_limit_reached", "Promo code has been used up")
	}

	if (promo.perUserLimit > 0) {
		const mine = await prisma.promoRedemption.count({
			where: { promoCodeId: promo.id, userId: params.userId },
		})
		if (mine >= promo.perUserLimit) {
			throw refuse("promo_already_used", "Promo code has already been used on this account")
		}
	}

	const floor = Math.max(1, params.minimumMinor ?? 1)
	const raw = Math.round((params.amountMinor * promo.percentOff) / 100)
	// Never below the gateway's minimum: a 25% cut on a one-rouble trial would
	// otherwise produce an amount the gateway rejects outright.
	const discountMinor = Math.max(0, Math.min(raw, params.amountMinor - floor))
	if (discountMinor <= 0) {
		throw refuse("promo_amount_too_small", "This amount is too small for a discount")
	}

	return {
		promo,
		percentOff: promo.percentOff,
		discountMinor,
		amountMinor: params.amountMinor - discountMinor,
	}
}

/**
 * Records that a paid order used a code. Idempotent: the redemption row is
 * unique per order, so a webhook delivered twice counts once.
 */
export async function redeemPromo(params: {
	code: string
	userId: string
	orderId: string
	discountMinor: number
	currency: string
}): Promise<boolean> {
	const promo = await findPromo(params.code)
	if (!promo) return false
	const existing = await prisma.promoRedemption.findUnique({ where: { orderId: params.orderId } })
	if (existing) return false

	try {
		await prisma.$transaction([
			prisma.promoRedemption.create({
				data: {
					promoCodeId: promo.id,
					userId: params.userId,
					orderId: params.orderId,
					discountMinor: Math.max(0, Math.round(params.discountMinor)),
					currency: params.currency.toUpperCase(),
				},
			}),
			prisma.promoCode.update({
				where: { id: promo.id },
				data: { redeemedCount: { increment: 1 } },
			}),
		])
		return true
	} catch {
		// A concurrent webhook won the unique index. That is the desired outcome.
		return false
	}
}

export async function listPromos(): Promise<PromoCode[]> {
	return prisma.promoCode.findMany({ orderBy: { createdAt: "desc" }, take: 200 })
}
