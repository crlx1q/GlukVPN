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
 *   - "tabpay": TabPay's hosted page (SBP + cards, roubles only) + a webhook
 *     signed with the shop's secret. See `tabpay.ts`; the gateway settles in
 *     one currency, which is why `settlementCurrency()` exists.
 *
 * Adding Kaspi / Freedom Pay / CloudPayments / crypto means one more adapter
 * implementing `PaymentProvider`; nothing else changes.
 */
import { createHmac, timingSafeEqual } from "node:crypto"
import type { Order, Plan, Prisma, User } from "@prisma/client"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { badRequest, conflict, notFound, serviceUnavailable } from "../lib/errors"
import { prisma } from "../prisma"
import { FREE_PLAN_CODE } from "./entitlements"
import { requestPolicySync } from "./policy"
import { type PlanWithPrices, resolvePlanPrice } from "./pricing"
import { type PromoApplication, applyPromo, redeemPromo } from "./promo"
import {
	TABPAY_CURRENCY,
	TABPAY_MIN_KOPECKS,
	type TabpayWebhookEvent,
	tabpayProvider,
} from "./tabpay"

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
 * Applies a plan to a user: a new subscription row starting where the current
 * one of the same-or-lower tier ends (so paying early never loses days), and
 * the plan's device / session limits when they are more generous than what the
 * account already has. Never lowers a limit.
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
	// Rows this grant takes over. Extending supersedes only the same-or-lower
	// tier (a Pro month bought on top of Basic keeps Pro); replacing clears the
	// lot, so an account can never sit on two plans at once.
	const superseded = await prisma.subscription.findMany({
		where: {
			userId: params.userId,
			status: "ACTIVE",
			expiresAt: { gt: now },
			...(mode === "extend" ? { tier: { lte: params.plan.tier } } : {}),
		},
		orderBy: { expiresAt: "desc" },
	})
	const current = superseded[0] ?? null
	const start = mode === "extend" && current && current.expiresAt > now ? current.expiresAt : now
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
		params.set("cancel_url", config.BILLING_CANCEL_URL.trim() || siteUrl("/pricing/?cancelled=1"))
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

function provider(): PaymentProvider {
	if (!config.billingEnabled) throw serviceUnavailable("Billing is not enabled on this server")
	if (config.BILLING_PROVIDER === "stripe") return stripeProvider
	if (config.BILLING_PROVIDER === "tabpay") return tabpayProvider
	return manualProvider
}

/** Which adapter is live, or "" when billing is switched off. */
export function activeProviderName(): string {
	return config.billingEnabled ? config.BILLING_PROVIDER : ""
}

/**
 * The currency the active gateway can actually settle in, or null when it
 * takes whatever the visitor was quoted.
 *
 * TabPay is a Russian acquirer: roubles and nothing else. Without this, a
 * visitor quoted "790 ₸" would be handed a checkout for 790 roubles, and the
 * one-rouble trial would be a one-tenge trial.
 */
export function settlementCurrency(): string | null {
	return config.BILLING_PROVIDER === "tabpay" ? TABPAY_CURRENCY : null
}

/** Smallest amount the active gateway accepts, in minor units. */
export function minimumChargeMinor(): number {
	return config.BILLING_PROVIDER === "tabpay" ? TABPAY_MIN_KOPECKS : 1
}

// --------------------------------------------------------------- orders ----

/** Order metadata as an object, whatever the JSON column happens to hold. */
function orderMetadata(order: Order): Record<string, unknown> {
	return typeof order.metadata === "object" && order.metadata !== null && !Array.isArray(order.metadata)
		? (order.metadata as Record<string, unknown>)
		: {}
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
	 * Allow ordering a plan that is not in the public catalogue. Only the trial
	 * uses this: its plan is hidden so it cannot be bought straight off the
	 * pricing page, and `trial.ts` opens it once eligibility is proven.
	 */
	allowHidden?: boolean
	/** Recorded on the order; "trial" makes the grant a trial subscription. */
	source?: string | null
}): Promise<{ order: Order & { plan: Plan }; checkout: CheckoutResult }> {
	const gateway = provider()
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
	const settle = settlementCurrency()
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
			minimumMinor: minimumChargeMinor(),
		})
	}
	const amountMinor = promo ? promo.amountMinor : price.priceMinor
	const metadata: Prisma.InputJsonValue = {
		quotedCurrency: quoted.currency,
		quotedMinor: quoted.priceMinor,
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
	if (open && open.provider === gateway.name && (gateway.name === "manual" || open.paymentUrl)) {
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
	 * Accept money for an order we had already given up on. TabPay documents
	 * late settlement - EXPIRED or FAILED can still become SUCCESS - and the
	 * payment is real, so the plan has to follow it.
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
	return prisma.order.findUniqueOrThrow({ where: { id: order.id }, include: { plan: true } })
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

// ---------------------------------------------------------- tabpay hook ----

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

export type TabpayEventOutcome = {
	handled: boolean
	orderId?: string
	status?: string
	/** Why nothing was done, when nothing was done. */
	ignored?: string
}

/**
 * Applies one TabPay webhook. The signature is verified by the route before
 * this runs; the only job here is to move the order.
 *
 * Anything unrecognised is acknowledged rather than refused: the gateway
 * retries every non-2xx for a day, and an event about an order this database
 * does not have (the other environment's shop, a purged order) will never
 * start succeeding.
 */
export async function handleTabpayEvent(event: TabpayWebhookEvent): Promise<TabpayEventOutcome> {
	const paymentId = typeof event.id === "string" ? event.id.trim() : ""
	const orderId = typeof event.orderId === "string" ? event.orderId.trim() : ""
	const status = typeof event.status === "string" ? event.status.trim().toUpperCase() : ""

	// The dashboard's "send test webhook" button signs a synthetic event whose
	// id is not a payment. It proves the URL and the secret, and must hand out
	// nothing. `test: true` is a different thing entirely: a sandbox payment is
	// exactly what the bank's reviewer will make, and it has to work.
	if (paymentId.startsWith("test-")) return { handled: false, ignored: "probe", status }
	if (!orderId || !status) return { handled: false, ignored: "malformed" }
	if (!UUID_RE.test(orderId)) return { handled: false, ignored: "unknown_order", orderId, status }

	const known = await prisma.order.findUnique({ where: { id: orderId }, select: { id: true } })
	if (!known) return { handled: false, ignored: "unknown_order", orderId, status }

	switch (status) {
		case "SUCCESS":
			await markOrderPaid({ orderId, providerRef: paymentId || null, by: "webhook", revive: true })
			return { handled: true, orderId, status }
		case "FAILED":
		case "EXPIRED":
			await markOrderFailed({ orderId, status: "FAILED", reason: status.toLowerCase() })
			return { handled: true, orderId, status }
		case "CANCELED":
		case "CANCELLED":
			await markOrderFailed({ orderId, status: "CANCELLED", reason: "canceled" })
			return { handled: true, orderId, status }
		case "REFUNDED":
			await markOrderRefunded({ orderId, reason: "refunded" })
			return { handled: true, orderId, status }
		default:
			// CREATED / PENDING, and whatever the status set grows into later.
			return { handled: false, ignored: "no_action", orderId, status }
	}
}
