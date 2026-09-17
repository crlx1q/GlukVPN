/**
 * Billing: plans, orders and the payment-gateway adapters.
 *
 * The shape is provider-agnostic on purpose. A client asks for a plan, we
 * create a PENDING order and hand it to the adapter named by
 * BILLING_PROVIDER, which returns either a URL to send the browser to or
 * instructions to show. Whatever the gateway, the only thing that turns an
 * order into a subscription is `markOrderPaid`, and it does so exactly once.
 *
 * Adapters:
 *   - "manual": no gateway. The order sits PENDING until an administrator
 *     presses "Mark paid" in the panel (bank transfer, Kaspi, cash, promo).
 *   - "stripe": Stripe Checkout (hosted page) + the `checkout.session.completed`
 *     webhook, verified with the endpoint secret. Written against Stripe's
 *     plain REST API with fetch, so there is no SDK to keep up to date.
 *   - one folder per acquirer under `payments/` (TabPay, MulenPay, Cashera),
 *     each implementing `PaymentModule` and loaded by `payments/registry`.
 *     Which one is live is a row in the database, flipped in the admin panel -
 *     not a redeploy.
 *
 * Nothing in this file names an acquirer any more, and that is the point:
 * deleting `payments/mulenpay/` removes the gateway from the switch and from
 * the build, and the shop keeps selling through the other two.
 *
 * A gateway that settles in one currency (all three Russian ones do) is why
 * `settlementCurrency()` and `minimumChargeMinor()` exist - and why they, like
 * `provider()` itself, are async now: the answer depends on a row.
 */
import { createHmac, timingSafeEqual } from "node:crypto"
import type { Order, Plan, Prisma, User } from "@prisma/client"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { badRequest, conflict, notFound, serviceUnavailable } from "../lib/errors"
import { paymentModule } from "../payments/registry"
import { activeProviderId } from "../payments/settings"
import type { PaymentEvent, PaymentModule, PaymentSnapshot } from "../payments/types"
import { returnUrls, webhookUrl } from "../payments/urls"
import { prisma } from "../prisma"
import { FREE_PLAN_CODE } from "./entitlements"
import { requestPolicySync } from "./policy"
import { type PlanWithPrices, resolvePlanPrice } from "./pricing"
import { type PromoApplication, applyPromo, redeemPromo } from "./promo"

// --------------------------------------------------------------- plans -----

export type PlanView = {
	code: string
	name: string
	tier: number
	days: number
	priceMinor: number
	currency: string
	priceLabel: string
	maxDevices: number
	maxSessions: number
	/** Monthly traffic cap in GB, or null when uncapped. */
	trafficGb: number | null
	/** Per-device link speed in Mbit/s, or null when unshaped. */
	speedMbps: number | null
	features: string[]
	featured: boolean
}

const CURRENCY_SYMBOL: Record<string, string> = {
	KZT: "₸",
	RUB: "₽",
	USD: "$",
	EUR: "€",
}

/** "1 490 ₸" / "$9.99" — minor units in, human string out. */
export function priceLabel(minor: number, currency: string): string {
	const symbol = CURRENCY_SYMBOL[currency.toUpperCase()] ?? currency.toUpperCase()
	const major = minor / 100
	const zeroDecimals = currency.toUpperCase() === "KZT" || currency.toUpperCase() === "RUB"
	const text = zeroDecimals
		? Math.round(major).toLocaleString("ru-RU")
		: major.toFixed(2)
	return symbol === "$" || symbol === "€" ? `${symbol}${text}` : `${text} ${symbol}`
}

/**
 * One plan as the clients render it.
 *
 * `currency` chooses which of the plan's prices to quote. Without it the plan's
 * own base price is used, which leaves every existing caller (the admin panel)
 * behaving exactly as before.
 */
export function planView(plan: PlanWithPrices, currency?: string | null): PlanView {
	const features = Array.isArray(plan.features)
		? (plan.features as unknown[]).map((item) => String(item))
		: []
	const price = resolvePlanPrice(plan, currency)
	return {
		code: plan.code,
		name: plan.name,
		tier: plan.tier,
		days: plan.days,
		priceMinor: price.priceMinor,
		currency: price.currency,
		priceLabel: price.priceMinor === 0 ? "0" : priceLabel(price.priceMinor, price.currency),
		maxDevices: plan.maxDevices,
		maxSessions: plan.maxSessions,
		trafficGb: plan.trafficGb,
		speedMbps: plan.speedMbps,
		features,
		featured: plan.featured,
	}
}

/**
 * The public catalogue: active, publicly listed, with every currency attached.
 *
 * `isPublic` is what keeps the internal beta tier out of the shop while leaving
 * it grantable from the admin panel. `active` cannot do that job, because an
 * inactive plan cannot be granted at all.
 */
export async function listPlans(): Promise<PlanWithPrices[]> {
	return prisma.plan.findMany({
		where: { active: true, isPublic: true },
		include: { prices: true },
		orderBy: { sortOrder: "asc" },
	})
}

// -------------------------------------------------------- subscriptions ----

/**
 * Applies a plan to a user: a new subscription row starting where the days
 * already paid for run out (so buying early never loses any), and the plan's
 * device / session limits when they are more generous than what the account
 * already has. Never lowers a limit.
 */
export async function grantPlan(params: {
	userId: string
	plan: Plan
	days?: number
	source: string
	/**
	 * "extend" (default) keeps the days already paid for and stacks the new term
	 * on top of them. "replace" drops whatever is active and starts a fresh term
	 * now - what an admin means by "put this account on Basic for one month".
	 */
	mode?: "extend" | "replace"
}): Promise<{ expiresAt: Date }> {
	// Free is the absence of a subscription, never a row. Granting it is exactly
	// how an account ended up displaying "Free - active - 790 days left".
	if (params.plan.code.trim().toLowerCase() === FREE_PLAN_CODE) {
		throw badRequest("Free is not a subscription")
	}
	const mode = params.mode ?? "extend"
	const days = params.days ?? params.plan.days
	const now = new Date()
	// Every row still valid at this moment, latest expiry first.
	const live = await prisma.subscription.findMany({
		where: { userId: params.userId, status: "ACTIVE", expiresAt: { gt: now } },
		orderBy: { expiresAt: "desc" },
	})
	// Rows this grant takes over. Extending supersedes only the same-or-lower
	// tier (a Pro month bought on top of Basic keeps Pro); replacing clears the
	// lot, so an account can never sit on two plans at once.
	const superseded = mode === "extend" ? live.filter((row) => row.tier <= params.plan.tier) : live
	// Where the new term begins: after the last day already paid for, whatever
	// tier holds it. Reading this off `superseded` instead is what broke a
	// downgrade - a Basic month bought while a Pro year was running started
	// *now* and burned in parallel with the Pro it cannot out-rank, so the
	// account lost the month it had just paid for. Queued behind Pro instead,
	// Basic simply takes over on the day Pro ends.
	//
	// Legacy `free` rows are excluded on purpose: they are not paid days, and
	// one of those ten-year rows would push every new term out to 2035.
	const paidUntil =
		live.find((row) => row.plan.trim().toLowerCase() !== FREE_PLAN_CODE)?.expiresAt ?? null
	const start = mode === "extend" && paidUntil && paidUntil > now ? paidUntil : now
	const expiresAt = new Date(start.getTime() + days * 24 * 60 * 60 * 1000)

	await prisma.$transaction(async (tx) => {
		// The old row of the same tier would otherwise stay ACTIVE beside the
		// new one and confuse "which plan am I on"; it is superseded, not lost.
		if (superseded.length > 0) {
			await tx.subscription.updateMany({
				where: { id: { in: superseded.map((row) => row.id) } },
				data: { status: "EXPIRED" },
			})
		}
		await tx.subscription.create({
			data: {
				userId: params.userId,
				plan: params.plan.code,
				tier: params.plan.tier,
				source: params.source,
				status: "ACTIVE",
				expiresAt,
			},
		})
		const user = await tx.user.findUnique({ where: { id: params.userId } })
		if (user) {
			await tx.user.update({
				where: { id: user.id },
				data: {
					maxDevices: Math.max(user.maxDevices, params.plan.maxDevices),
					maxSessions: Math.max(user.maxSessions, params.plan.maxSessions),
				},
			})
		}
	})
	// A higher tier may unlock nodes the device was not provisioned on yet.
	await requestPolicySync().catch(() => 0)
	return { expiresAt }
}

/**
 * What a brand-new account gets: nothing.
 *
 * This used to write a ten-year "free" subscription, which is why accounts
 * reported "Free - active - 790 days left". Free is the absence of a
 * subscription, and `entitlements.ts` reads a missing row (or a legacy free
 * row) as Free, so sign-up has nothing to do here.
 *
 * Kept as a no-op because every registration path calls it - and because a
 * welcome trial, if there ever is one, belongs exactly here.
 */
export async function grantDefaultSubscription(_userId: string): Promise<void> {
	return
}

// ------------------------------------------------------------- providers ---

export type CheckoutResult = {
	paymentUrl: string | null
	providerRef: string | null
	manual: boolean
	instructions: string | null
}

export interface PaymentProvider {
	readonly name: string
	createCheckout(order: Order, plan: Plan, user: User): Promise<CheckoutResult>
}

function siteUrl(path: string): string {
	return `${config.SITE_BASE_URL.replace(/\/+$/, "")}${path}`
}

const manualProvider: PaymentProvider = {
	name: "manual",
	async createCheckout(order, plan) {
		const instructions = config.BILLING_MANUAL_INSTRUCTIONS.replace(
			"{orderId}",
			order.id.slice(0, 8).toUpperCase(),
		).replace("{amount}", `${priceLabel(order.amountMinor, order.currency)} (${plan.name})`)
		return { paymentUrl: null, providerRef: null, manual: true, instructions }
	},
}

const stripeProvider: PaymentProvider = {
	name: "stripe",
	async createCheckout(order, plan, user) {
		const key = config.STRIPE_SECRET_KEY.trim()
		if (!key) throw serviceUnavailable("Stripe is not configured")
		const params = new URLSearchParams()
		params.set("mode", "payment")
		params.set("client_reference_id", order.id)
		params.set("metadata[orderId]", order.id)
		params.set("metadata[userId]", user.id)
		params.set("metadata[planCode]", plan.code)
		params.set("line_items[0][quantity]", "1")
		params.set("line_items[0][price_data][currency]", order.currency.toLowerCase())
		params.set("line_items[0][price_data][unit_amount]", String(order.amountMinor))
		params.set("line_items[0][price_data][product_data][name]", `GlukVPN ${plan.name} — ${plan.days} days`)
		params.set(
			"success_url",
			config.BILLING_SUCCESS_URL.trim() || siteUrl("/app/?paid=1&order=" + order.id),
		)
		params.set("cancel_url", config.BILLING_CANCEL_URL.trim() || siteUrl("/app/?failed=1&order=" + order.id))
		if (user.email) params.set("customer_email", user.email)

		let response: Response
		try {
			response = await fetch("https://api.stripe.com/v1/checkout/sessions", {
				method: "POST",
				headers: {
					authorization: `Bearer ${key}`,
					"content-type": "application/x-www-form-urlencoded",
					"idempotency-key": `order-${order.id}`,
				},
				body: params.toString(),
				signal: AbortSignal.timeout(15000),
			})
		} catch {
			throw serviceUnavailable("Payment gateway did not respond")
		}
		const body = (await response.json().catch(() => ({}))) as {
			id?: string
			url?: string
			error?: { message?: string }
		}
		if (!response.ok || !body.url || !body.id) {
			throw serviceUnavailable(body.error?.message ?? "Payment gateway refused the order")
		}
		return { paymentUrl: body.url, providerRef: body.id, manual: false, instructions: null }
	},
}

/**
 * Wraps a payment folder as a provider.
 *
 * The only place where our order model meets a gateway's, and deliberately
 * thin: it fills in `PaymentOrderInput` and hands over. Everything specific to
 * an acquirer - signatures, receipts, status words - stays in its folder.
 */
function moduleProvider(mod: PaymentModule): PaymentProvider {
	return {
		name: mod.id,
		async createCheckout(order, plan, user) {
			const meta = orderMetadata(order)
			const isTrial = meta.source === "trial"
			// The rail the payer picked, remembered on the order: a checkout that
			// is handed back later opens on the one it was created for.
			const method = typeof meta.method === "string" ? meta.method : null
			const urls = returnUrls({ orderId: order.id, isTrial })
			// The short order id is what a payer sees on a bank statement and
			// quotes to support, so it belongs in the description.
			const reference = order.id.slice(0, 8).toUpperCase()
			return mod.createCheckout({
				orderId: order.id,
				amountMinor: order.amountMinor,
				currency: order.currency,
				description: `GlukVPN ${plan.name}, ${plan.days} дн. (заказ ${reference})`,
				isTrial,
				...(method ? { method } : {}),
				successUrl: urls.successUrl,
				failUrl: urls.failUrl,
				webhookUrl: webhookUrl(mod.id),
				customer: {
					userId: user.id,
					email: user.email,
					// Digits only. A @username is not an id, and a gateway asked to
					// treat one as a number answers with a validation error.
					telegramId: /^\d+$/.test(String(user.telegramId ?? "")) ? String(user.telegramId) : null,
				},
				metadata: {
					orderId: order.id,
					userId: user.id,
					planCode: plan.code,
					channel: "glukvpn",
					...(typeof meta.source === "string" ? { source: meta.source } : {}),
				},
			})
		},
	}
}

/**
 * The gateway the next payment goes through.
 *
 * A provider that is selected but not installed, or installed without keys, is
 * refused here rather than papered over: the alternative is an order nobody
 * can pay and a customer staring at a broken link.
 */
async function provider(): Promise<PaymentProvider> {
	const id = await activeProviderId()
	if (!id) throw serviceUnavailable("Billing is not enabled on this server")
	if (id === "manual") return manualProvider
	if (id === "stripe") {
		if (!config.STRIPE_SECRET_KEY.trim()) throw serviceUnavailable("Stripe is not configured")
		return stripeProvider
	}
	const mod = paymentModule(id)
	if (!mod) throw serviceUnavailable("The selected payment provider is not installed")
	if (!mod.configured()) throw serviceUnavailable(`${mod.label} is not configured`)
	return moduleProvider(mod)
}

export type BillingStatus = {
	/** Can this server take money right now. */
	enabled: boolean
	/** The selected provider id, even when it cannot take money. */
	provider: string
}

/**
 * Whether the shop can sell, and through what.
 *
 * This replaces `config.billingEnabled`, which could only ever read .env. The
 * answer now depends on the row an administrator flipped and on whether that
 * folder is still installed and holding keys.
 */
export async function billingStatus(): Promise<BillingStatus> {
	const id = await activeProviderId()
	if (!id) return { enabled: false, provider: "" }
	if (id === "manual") return { enabled: true, provider: id }
	if (id === "stripe") return { enabled: config.STRIPE_SECRET_KEY.trim().length > 0, provider: id }
	const mod = paymentModule(id)
	return { enabled: mod ? mod.configured() : false, provider: id }
}

/** Which adapter is live, or "" when billing is switched off. */
export async function activeProviderName(): Promise<string> {
	const status = await billingStatus()
	return status.enabled ? status.provider : ""
}

/**
 * The currency the active gateway can actually settle in, or null when it
 * takes whatever the visitor was quoted.
 *
 * All three Russian acquirers settle in roubles and nothing else. Without
 * this, a visitor quoted "790 ₸" would be handed a checkout for 790 roubles,
 * and the one-rouble trial would be a one-tenge trial.
 */
export async function settlementCurrency(): Promise<string | null> {
	const mod = paymentModule(await activeProviderId())
	return mod ? mod.currency : null
}

/** Smallest amount the active gateway accepts, in minor units. */
export async function minimumChargeMinor(): Promise<number> {
	const mod = paymentModule(await activeProviderId())
	return mod ? mod.minimumMinor : 1
}

// --------------------------------------------------------------- orders ----

/** Order metadata as an object, whatever the JSON column happens to hold. */
function orderMetadata(order: Order): Record<string, unknown> {
	return typeof order.metadata === "object" && order.metadata !== null && !Array.isArray(order.metadata)
		? (order.metadata as Record<string, unknown>)
		: {}
}

/**
 * The payer's chosen rail as it will be stored, or null when nothing was
 * picked. Nothing is validated against a list here: which ids exist is the
 * gateway folder's business, and it ignores what it does not know.
 */
function normalizeMethod(value?: string | null): string | null {
	const text = (value ?? "").trim()
	return text ? text.slice(0, 32) : null
}

/** Two rails, compared the way a gateway would: case does not matter. */
function sameMethod(stored: unknown, wanted: string | null): boolean {
	const left = typeof stored === "string" ? stored.trim().toLowerCase() : ""
	return left === (wanted ?? "").toLowerCase()
}

export type OrderView = {
	id: string
	status: Order["status"]
	planCode: string
	planName: string
	amountMinor: number
	currency: string
	priceLabel: string
	provider: string
	paymentUrl: string | null
	/** The code that was applied, and what it took off the charge. */
	promoCode: string | null
	discountMinor: number
	/** What the visitor was quoted, when the gateway forced another currency. */
	quotedCurrency: string | null
	quotedMinor: number | null
	paidAt: string | null
	createdAt: string
}

export function orderView(order: Order & { plan: Plan }): OrderView {
	const meta = orderMetadata(order)
	const quotedCurrency = typeof meta.quotedCurrency === "string" ? meta.quotedCurrency : null
	const quotedMinor = typeof meta.quotedMinor === "number" ? meta.quotedMinor : null
	return {
		id: order.id,
		status: order.status,
		planCode: order.plan.code,
		planName: order.plan.name,
		amountMinor: order.amountMinor,
		currency: order.currency,
		priceLabel: priceLabel(order.amountMinor, order.currency),
		provider: order.provider,
		paymentUrl: order.status === "PENDING" ? order.paymentUrl : null,
		promoCode: typeof meta.promoCode === "string" ? meta.promoCode : null,
		discountMinor: typeof meta.discountMinor === "number" ? meta.discountMinor : 0,
		// Only interesting when it differs: same currency means nothing was
		// converted and the quote is the charge.
		quotedCurrency: quotedCurrency && quotedCurrency !== order.currency ? quotedCurrency : null,
		quotedMinor: quotedCurrency && quotedCurrency !== order.currency ? quotedMinor : null,
		paidAt: order.paidAt?.toISOString() ?? null,
		createdAt: order.createdAt.toISOString(),
	}
}

export async function createOrder(params: {
	user: User
	planCode: string
	ip?: string | null
	/** Which currency to charge in. Defaults to the plan's own. */
	currency?: string | null
	/** A promo code typed by the visitor. Validated here, never trusted. */
	promoCode?: string | null
	/**
	 * The rail the payer picked, as an id from the active gateway's own
	 * `availableMethods` ("sbp", "CARD", "all", ...). Kept on the order and
	 * handed to the adapter, which is the only thing that knows what its
	 * acquirer calls a rail.
	 */
	method?: string | null
	/**
	 * Allow ordering a plan that is not in the public catalogue. Only the trial
	 * uses this: its plan is hidden so it cannot be bought straight off the
	 * pricing page, and `trial.ts` opens it once eligibility is proven.
	 */
	allowHidden?: boolean
	/** Recorded on the order; "trial" makes the grant a trial subscription. */
	source?: string | null
}): Promise<{ order: Order & { plan: Plan }; checkout: CheckoutResult }> {
	const gateway = await provider()
	const plan = await prisma.plan.findFirst({
		where: {
			code: params.planCode.toLowerCase(),
			active: true,
			...(params.allowHidden ? {} : { isPublic: true }),
		},
		include: { prices: true },
	})
	if (!plan) throw notFound("Plan not found")
	if (plan.priceMinor <= 0) throw badRequest("This plan is free and needs no order")

	// The order carries the amount actually charged, and both gateway adapters
	// read the amount from the order rather than from the plan - so quoting a
	// visitor in roubles and then billing them in tenge cannot happen.
	const quoted = resolvePlanPrice(plan, params.currency)
	// When the gateway settles in a single currency, that currency wins and the
	// quote is kept on the order so the site can explain the conversion.
	const settle = await settlementCurrency()
	const price = settle ? resolvePlanPrice(plan, settle) : quoted
	if (settle && price.currency.toUpperCase() !== settle) {
		throw serviceUnavailable("This plan is not priced in the gateway's currency")
	}

	// A code changes the amount, so it is resolved before any order exists.
	let promo: PromoApplication | null = null
	if (params.promoCode?.trim()) {
		promo = await applyPromo({
			code: params.promoCode,
			userId: params.user.id,
			planCode: plan.code,
			amountMinor: price.priceMinor,
			currency: price.currency,
			minimumMinor: await minimumChargeMinor(),
		})
	}
	const amountMinor = promo ? promo.amountMinor : price.priceMinor
	// Which rail to open the payment on. It lives on the order rather than in
	// an extra argument, so every adapter reads it the same way - and so a
	// reused checkout cannot quietly move a payer from SBP to a card.
	const method = normalizeMethod(params.method)
	const metadata: Prisma.InputJsonValue = {
		quotedCurrency: quoted.currency,
		quotedMinor: quoted.priceMinor,
		...(method ? { method } : {}),
		...(promo
			? {
					promoCode: promo.promo.code,
					promoPercent: promo.percentOff,
					discountMinor: promo.discountMinor,
				}
			: {}),
		...(params.source ? { source: params.source } : {}),
	}

	// One open order per plan per user: a double click should not make two.
	// The amount is part of the match, or a second attempt carrying a promo
	// code would silently reuse the full-price checkout.
	const open = await prisma.order.findFirst({
		where: {
			userId: params.user.id,
			planId: plan.id,
			status: "PENDING",
			amountMinor,
			currency: price.currency,
			createdAt: { gt: new Date(Date.now() - 6 * 60 * 60 * 1000) },
		},
		include: { plan: true },
	})
	// A payer who came back and picked another rail needs a new payment: the
	// stored link opens on the rail it was created for.
	const sameRail = open ? sameMethod(orderMetadata(open).method, method) : false
	if (open && sameRail && open.provider === gateway.name && (gateway.name === "manual" || open.paymentUrl)) {
		// ...but only while the gateway still considers that attempt payable. A
		// declined payment stays PENDING here until its webhook lands, and
		// handing back the same `paymentUrl` would drop the customer onto the
		// page that already refused them instead of starting a new attempt.
		const verdict = await openOrderVerdict(open, gateway.name)
		if (verdict === "paid") {
			// The money arrived while nobody was looking; `openOrderVerdict` has
			// just granted the plan. Hand back the settled order without a link:
			// there is nothing left to pay.
			const settled = await prisma.order.findUnique({
				where: { id: open.id },
				include: { plan: true },
			})
			return {
				order: settled ?? open,
				checkout: { paymentUrl: null, providerRef: open.providerRef, manual: false, instructions: null },
			}
		}
		if (verdict === "reuse") {
			return {
				order: open,
				checkout: {
					paymentUrl: open.paymentUrl,
					providerRef: open.providerRef,
					manual: gateway.name === "manual",
					instructions:
						gateway.name === "manual"
							? (await manualProvider.createCheckout(open, plan, params.user)).instructions
							: null,
				},
			}
		}
		// "dead": that attempt is over. Fall through and open a fresh payment
		// under a fresh order id - a gateway answers a repeated one with a
		// refusal, never with a second attempt.
	}

	const created = await prisma.order.create({
		data: {
			userId: params.user.id,
			planId: plan.id,
			amountMinor,
			currency: price.currency,
			provider: gateway.name,
			metadata,
		},
		include: { plan: true },
	})

	let checkout: CheckoutResult
	try {
		checkout = await gateway.createCheckout(created, plan, params.user)
	} catch (error) {
		await prisma.order.update({
			where: { id: created.id },
			data: { status: "FAILED", metadata: { error: error instanceof Error ? error.message : "unknown" } },
		})
		throw error
	}

	const order = await prisma.order.update({
		where: { id: created.id },
		data: { paymentUrl: checkout.paymentUrl, providerRef: checkout.providerRef },
		include: { plan: true },
	})
	await writeAudit({
		action: "billing.order.create",
		userId: params.user.id,
		ip: params.ip ?? null,
		metadata: { orderId: order.id, plan: plan.code, amountMinor: order.amountMinor, provider: gateway.name },
	})
	return { order, checkout }
}

/**
 * The single place an order becomes a subscription. Idempotent: a webhook
 * retried five times still extends the account once.
 */
export async function markOrderPaid(params: {
	orderId: string
	providerRef?: string | null
	by: "webhook" | "admin"
	adminId?: string | null
	/**
	 * Accept money for an order we had already given up on. Late settlement is
	 * documented behaviour - an expired or failed attempt can still turn into a
	 * payment - and the money is real, so the plan has to follow it.
	 */
	revive?: boolean
}): Promise<Order & { plan: Plan }> {
	const order = await prisma.order.findUnique({
		where: { id: params.orderId },
		include: { plan: true },
	})
	if (!order) throw notFound("Order not found")
	if (order.status === "PAID") return order
	const revivable = params.revive === true && (order.status === "FAILED" || order.status === "CANCELLED")
	if (order.status !== "PENDING" && !revivable) throw conflict(`Order is ${order.status.toLowerCase()}`)

	// PENDING -> PAID is the gate; the loser of a race sees the winner's row.
	const claimed = await prisma.order.updateMany({
		where: {
			id: order.id,
			status: revivable ? { in: ["PENDING", "FAILED", "CANCELLED"] } : "PENDING",
		},
		data: {
			status: "PAID",
			paidAt: new Date(),
			...(params.providerRef ? { providerRef: params.providerRef } : {}),
			metadata: { ...(typeof order.metadata === "object" && order.metadata ? (order.metadata as object) : {}), paidBy: params.by } as Prisma.InputJsonValue,
		},
	})
	if (claimed.count !== 1) {
		return prisma.order.findUniqueOrThrow({ where: { id: order.id }, include: { plan: true } })
	}

	const meta = orderMetadata(order)
	// A trial is still an order; the subscription just remembers where it came
	// from, which is what makes "one trial per account" answerable later.
	const source = meta.source === "trial" ? "trial" : "order"
	const granted = await grantPlan({ userId: order.userId, plan: order.plan, source })
	// A code is consumed by the payment, not by the checkout, so an abandoned
	// order never burns it. Best effort: bookkeeping must not undo a grant.
	if (typeof meta.promoCode === "string" && meta.promoCode) {
		await redeemPromo({
			code: meta.promoCode,
			userId: order.userId,
			orderId: order.id,
			discountMinor: Number(meta.discountMinor) || 0,
			currency: order.currency,
		}).catch(() => false)
	}
	await writeAudit({
		action: "billing.order.paid",
		userId: params.adminId ?? order.userId,
		metadata: {
			orderId: order.id,
			targetUserId: order.userId,
			plan: order.plan.code,
			by: params.by,
			expiresAt: granted.expiresAt.toISOString(),
		},
	})
	// #092 for the administration channel, #097 for the buyer. Fire-and-forget
	// on purpose: the plan is already granted above, so a Telegram outage may
	// cost a message but can never cost a subscription.
	void notifyPaidOrder({ order, granted, by: params.by, meta }).catch(() => undefined)
	return prisma.order.findUniqueOrThrow({ where: { id: order.id }, include: { plan: true } })
}

/**
 * Tell the admins a purchase happened (#092) and the buyer that the plan is
 * already on (#097).
 *
 * The Telegram modules are required lazily because both of them import this
 * one for price formatting - a static import here would be a cycle.
 */
async function notifyPaidOrder(params: {
	order: Order & { plan: Plan }
	granted: { expiresAt: Date }
	by: string
	meta: ReturnType<typeof orderMetadata>
}): Promise<void> {
	const user = await prisma.user
		.findUnique({
			where: { id: params.order.userId },
			select: { username: true, publicId: true, telegramId: true },
		})
		.catch(() => null)
	if (!user) return
	const admin = require("./telegramAdmin") as typeof import("./telegramAdmin")
	const account = require("./telegramAccount") as typeof import("./telegramAccount")
	await admin
		.notifyPurchase({
			username: user.username,
			publicId: user.publicId,
			planName: params.order.plan.name,
			planCode: params.order.plan.code,
			days: params.order.plan.days,
			amountMinor: params.order.amountMinor,
			currency: params.order.currency,
			provider: params.order.provider,
			source: typeof params.meta.source === "string" ? params.meta.source : null,
			promoCode: typeof params.meta.promoCode === "string" ? params.meta.promoCode : null,
			discountMinor: Number(params.meta.discountMinor) || 0,
			expiresAt: params.granted.expiresAt,
			confirmedBy: params.by,
		})
		.catch(() => undefined)
	if (!user.telegramId) return
	await account
		.notifySubscriptionActivated({
			telegramId: user.telegramId,
			planName: params.order.plan.name,
			days: params.order.plan.days,
			amountMinor: params.order.amountMinor,
			currency: params.order.currency,
			expiresAt: params.granted.expiresAt,
		})
		.catch(() => undefined)
}

export async function cancelOrder(orderId: string, adminId: string): Promise<void> {
	const result = await prisma.order.updateMany({
		where: { id: orderId, status: "PENDING" },
		data: { status: "CANCELLED" },
	})
	if (result.count !== 1) throw conflict("Only pending orders can be cancelled")
	await writeAudit({ action: "billing.order.cancel", userId: adminId, metadata: { orderId } })
}

/** Housekeeping: a checkout nobody finished within a day is dead. */
export async function expireStaleOrders(): Promise<number> {
	const result = await prisma.order.updateMany({
		where: { status: "PENDING", createdAt: { lt: new Date(Date.now() - 24 * 60 * 60 * 1000) } },
		data: { status: "CANCELLED" },
	})
	return result.count
}

// ---------------------------------------------------------- stripe hook ----

/**
 * Verifies `Stripe-Signature` (t=...,v1=...) over `${t}.${rawBody}` with the
 * endpoint secret and rejects events older than five minutes.
 */
export function verifyStripeSignature(rawBody: string, header: string | undefined): boolean {
	const secret = config.STRIPE_WEBHOOK_SECRET.trim()
	if (!secret || !header) return false
	const parts = Object.fromEntries(
		header.split(",").map((part) => {
			const [k, ...rest] = part.trim().split("=")
			return [k, rest.join("=")]
		}),
	) as Record<string, string>
	const timestamp = Number(parts.t)
	const signatures = header
		.split(",")
		.map((part) => part.trim())
		.filter((part) => part.startsWith("v1="))
		.map((part) => part.slice(3))
	if (!Number.isFinite(timestamp) || signatures.length === 0) return false
	if (Math.abs(Date.now() / 1000 - timestamp) > 300) return false
	const expected = createHmac("sha256", secret).update(`${timestamp}.${rawBody}`, "utf8").digest("hex")
	const expectedBuffer = Buffer.from(expected, "hex")
	return signatures.some((candidate) => {
		const buffer = Buffer.from(candidate, "hex")
		return buffer.length === expectedBuffer.length && timingSafeEqual(buffer, expectedBuffer)
	})
}

export async function handleStripeEvent(event: {
	type?: string
	data?: { object?: { id?: string; client_reference_id?: string; metadata?: Record<string, string>; payment_status?: string } }
}): Promise<{ handled: boolean; orderId?: string }> {
	if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") {
		return { handled: false }
	}
	const session = event.data?.object
	const orderId = session?.client_reference_id ?? session?.metadata?.orderId
	if (!orderId) return { handled: false }
	if (session?.payment_status && session.payment_status !== "paid") return { handled: false, orderId }
	await markOrderPaid({ orderId, providerRef: session?.id ?? null, by: "webhook" })
	return { handled: true, orderId }
}

// ----------------------------------------------------------- order state ----

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Marks an order dead. False when it was not PENDING any more. */
export async function markOrderFailed(params: {
	orderId: string
	status: "FAILED" | "CANCELLED"
	reason?: string | null
}): Promise<boolean> {
	const result = await prisma.order.updateMany({
		where: { id: params.orderId, status: "PENDING" },
		data: { status: params.status },
	})
	if (result.count !== 1) return false
	await writeAudit({
		action: "billing.order.failed",
		metadata: { orderId: params.orderId, status: params.status, reason: params.reason ?? null },
	})
	return true
}

/**
 * Records a refund. The subscription is deliberately left alone: giving money
 * back is a support decision, and taking access away is an explicit act in the
 * admin panel - not something a webhook does behind an operator's back.
 */
export async function markOrderRefunded(params: {
	orderId: string
	reason?: string | null
}): Promise<boolean> {
	const result = await prisma.order.updateMany({
		where: { id: params.orderId, status: "PAID" },
		data: { status: "REFUNDED" },
	})
	if (result.count !== 1) return false
	await writeAudit({
		action: "billing.order.refunded",
		metadata: { orderId: params.orderId, reason: params.reason ?? null },
	})
	return true
}

// ----------------------------------------------------- reconciliation ----

/**
 * What to do with an open order somebody has come back to.
 *
 * Our own row is not the authority here - the gateway is. A declined payment
 * leaves the order PENDING until its webhook lands, so a delivery that is
 * late, lost, or aimed at a URL nobody has filled in yet would otherwise have
 * us send the customer straight back to the page that refused them.
 *
 *   - "reuse": CREATED or PENDING. Nobody finished paying; the link still works.
 *   - "paid": SUCCESS. The money did arrive - grant the plan now rather than
 *     wait for a webhook that may never come, and never ask for it twice.
 *   - "dead": failed, expired, canceled, refunded. Close this attempt so the
 *     caller opens a new payment under a new order id: a gateway answers a
 *     repeated order id with a refusal, not with a second attempt.
 *
 * A gateway we cannot reach counts as "reuse": the payment may well be alive,
 * and inventing a second one for somebody who is mid-3DS is the worse of the
 * two mistakes.
 */
type OpenOrderVerdict = "reuse" | "paid" | "dead"

async function openOrderVerdict(order: Order, gatewayName: string): Promise<OpenOrderVerdict> {
	const mod = paymentModule(gatewayName)
	// "manual" has nothing to ask, and Stripe expires its own sessions: the
	// stored link stays usable until its webhook says otherwise.
	if (!mod) return "reuse"
	let snapshot: PaymentSnapshot | null = null
	try {
		snapshot = await mod.fetchStatus({ orderId: order.id, providerRef: order.providerRef })
	} catch {
		return "reuse"
	}
	if (!snapshot) return "reuse"
	// Still payable, or a status this adapter does not recognise: leave the
	// customer's link alone rather than act on a guess.
	if (snapshot.kind === "pending" || snapshot.kind === "unknown" || snapshot.kind === "probe") return "reuse"
	// Replaying the status through the event handler keeps a single code path for
	// what a status means: the grant, the audit entry and the promo redemption
	// are written identically whether the news arrived by webhook or by this
	// lookup. `confirmed` records that the gateway's own API is the source.
	await handlePaymentEvent(
		mod.id,
		{
			kind: snapshot.kind,
			orderId: order.id,
			providerRef: snapshot.providerRef,
			status: snapshot.status,
			amountMinor: snapshot.amountMinor ?? null,
		},
		{ confirmed: true },
	)
	return snapshot.kind === "paid" ? "paid" : "dead"
}

export type OrderSyncResult = {
	orderId: string
	status: string
	/** True when the gateway's answer moved the order. */
	changed: boolean
}

/**
 * Brings one account's open payments up to date with the gateway.
 *
 * The webhook remains the primary path; this is the belt. It runs when the
 * browser comes back from the hosted page, so a delivery that never arrives
 * cannot leave somebody who has paid looking at "no subscription", and a
 * refused attempt cannot stand in the way of the next one.
 */
export async function reconcilePendingOrders(user: User, limit = 5): Promise<OrderSyncResult[]> {
	const gateway = await provider()
	// Only a gateway folder can be asked about a payment: "manual" has no API
	// and Stripe reports through its own webhook.
	if (!paymentModule(gateway.name)) return []
	const now = Date.now()
	const open = await prisma.order.findMany({
		where: {
			userId: user.id,
			provider: gateway.name,
			OR: [
				{ status: "PENDING", createdAt: { gt: new Date(now - 7 * 24 * 60 * 60 * 1000) } },
				// Gateways settle late: an attempt we already wrote off can still turn
				// into SUCCESS. Re-asking about yesterday's refusals costs one call
				// and is the difference between "declined" and the plan somebody paid
				// for; markOrderPaid revives FAILED and CANCELLED for exactly this.
				{
					status: { in: ["FAILED", "CANCELLED"] },
					createdAt: { gt: new Date(now - 24 * 60 * 60 * 1000) },
				},
			],
		},
		orderBy: { createdAt: "desc" },
		take: Math.max(1, Math.min(limit, 10)),
	})
	const results: OrderSyncResult[] = []
	for (const order of open) {
		const verdict = await openOrderVerdict(order, gateway.name)
		const fresh = await prisma.order.findUnique({
			where: { id: order.id },
			select: { status: true },
		})
		results.push({ orderId: order.id, status: fresh?.status ?? order.status, changed: verdict !== "reuse" })
	}
	return results
}

export type PaymentEventOutcome = {
	handled: boolean
	orderId?: string
	status?: string
	/** Why nothing was done, when nothing was done. */
	ignored?: string
}

/**
 * Applies one webhook, whichever wallet sent it.
 *
 * The delivery is authenticated by the route (`verifyWebhook`) and translated
 * into our vocabulary by the provider folder (`parseWebhook`). Everything here
 * is about the order, so it is identical for all three gateways.
 *
 * Two rails stop a webhook from being a way to get a free subscription:
 *
 *   - a gateway whose callback carries no signature at all (MulenPay) sets
 *     `confirmWebhookByStatus`, and a "paid" claim is then re-read from the
 *     gateway's own API before anything is handed out. `options.confirmed` is
 *     how reconciliation says "this came from the API, don't ask twice";
 *   - the amount is compared with the order. A callback that pays 1 rouble for
 *     a 990-rouble plan is a mismatch, not a sale.
 *
 * Anything unrecognised is acknowledged rather than refused: a gateway retries
 * every non-2xx for hours, and an event about an order this database does not
 * have (the other environment's shop, a purged order) will never start
 * succeeding.
 */
export async function handlePaymentEvent(
	providerId: string,
	event: PaymentEvent,
	options: { confirmed?: boolean } = {},
): Promise<PaymentEventOutcome> {
	const status = event.status.trim()
	const orderId = (event.orderId ?? "").trim()
	const providerRef = (event.providerRef ?? "").trim()

	// A dashboard "send test webhook" button proves the URL and the secret and
	// must hand out nothing. A sandbox *payment* is a different thing entirely:
	// that is exactly what a bank's reviewer makes, and it has to work.
	if (event.kind === "probe") return { handled: false, ignored: "probe", status }
	if (event.kind === "unknown") return { handled: false, ignored: "no_action", status }
	if (!orderId) return { handled: false, ignored: "malformed", status }
	if (!UUID_RE.test(orderId)) return { handled: false, ignored: "unknown_order", orderId, status }

	const known = await prisma.order.findUnique({
		where: { id: orderId },
		select: { id: true, provider: true, amountMinor: true },
	})
	if (!known) return { handled: false, ignored: "unknown_order", orderId, status }

	// The order remembers which wallet opened it. After a switch in the panel
	// the previous gateway's late deliveries keep arriving, and they must not be
	// applied as if the new one had taken the money.
	if (known.provider && known.provider !== providerId) {
		return { handled: false, ignored: "provider_mismatch", orderId, status }
	}

	switch (event.kind) {
		case "paid": {
			const mod = paymentModule(providerId)
			if (mod?.confirmWebhookByStatus && !options.confirmed) {
				const snapshot = await mod
					.fetchStatus({ orderId, providerRef: providerRef || null })
					.catch(() => null)
				if (snapshot?.kind !== "paid") {
					return { handled: false, ignored: "status_unconfirmed", orderId, status }
				}
			}
			if (typeof event.amountMinor === "number" && event.amountMinor !== known.amountMinor) {
				return { handled: false, ignored: "amount_mismatch", orderId, status }
			}
			await markOrderPaid({ orderId, providerRef: providerRef || null, by: "webhook", revive: true })
			return { handled: true, orderId, status }
		}
		case "failed":
		case "expired":
			await markOrderFailed({ orderId, status: "FAILED", reason: event.kind })
			return { handled: true, orderId, status }
		case "canceled":
			await markOrderFailed({ orderId, status: "CANCELLED", reason: "canceled" })
			return { handled: true, orderId, status }
		case "refunded":
			await markOrderRefunded({ orderId, reason: "refunded" })
			return { handled: true, orderId, status }
		default:
			// "pending", and whatever the vocabulary grows into later.
			return { handled: false, ignored: "no_action", orderId, status }
	}
}
