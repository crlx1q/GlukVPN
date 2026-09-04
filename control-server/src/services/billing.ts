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
import { requestPolicySync } from "./policy"
import { type PlanWithPrices, resolvePlanPrice } from "./pricing"

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
}): Promise<{ expiresAt: Date }> {
	const days = params.days ?? params.plan.days
	const now = new Date()
	const current = await prisma.subscription.findFirst({
		where: {
			userId: params.userId,
			status: "ACTIVE",
			expiresAt: { gt: now },
			tier: { lte: params.plan.tier },
		},
		orderBy: { expiresAt: "desc" },
	})
	const start = current && current.expiresAt > now ? current.expiresAt : now
	const expiresAt = new Date(start.getTime() + days * 24 * 60 * 60 * 1000)

	await prisma.$transaction(async (tx) => {
		// The old row of the same tier would otherwise stay ACTIVE beside the
		// new one and confuse "which plan am I on"; it is superseded, not lost.
		if (current) {
			await tx.subscription.update({
				where: { id: current.id },
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

/** The free plan for a brand-new account, when one exists. */
export async function grantDefaultSubscription(userId: string): Promise<void> {
	const free = await prisma.plan.findFirst({ where: { code: "free", active: true } })
	if (!free) return
	// "Free" is not a 30-day trial: ten years, renewed silently if it ever runs out.
	await grantPlan({ userId, plan: free, days: 3650, source: "signup" })
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
	return config.BILLING_PROVIDER === "stripe" ? stripeProvider : manualProvider
}

// --------------------------------------------------------------- orders ----

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
	paidAt: string | null
	createdAt: string
}

export function orderView(order: Order & { plan: Plan }): OrderView {
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
}): Promise<{ order: Order & { plan: Plan }; checkout: CheckoutResult }> {
	const gateway = provider()
	const plan = await prisma.plan.findFirst({
		where: { code: params.planCode.toLowerCase(), active: true, isPublic: true },
		include: { prices: true },
	})
	if (!plan) throw notFound("Plan not found")
	if (plan.priceMinor <= 0) throw badRequest("This plan is free and needs no order")

	// The order carries the amount actually charged, and both gateway adapters
	// read the amount from the order rather than from the plan - so quoting a
	// visitor in roubles and then billing them in tenge cannot happen.
	const price = resolvePlanPrice(plan, params.currency)

	// One open order per plan per user: a double click should not make two.
	const open = await prisma.order.findFirst({
		where: {
			userId: params.user.id,
			planId: plan.id,
			status: "PENDING",
			createdAt: { gt: new Date(Date.now() - 6 * 60 * 60 * 1000) },
		},
		include: { plan: true },
	})
	if (open && open.provider === gateway.name) {
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
			amountMinor: price.priceMinor,
			currency: price.currency,
			provider: gateway.name,
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
}): Promise<Order & { plan: Plan }> {
	const order = await prisma.order.findUnique({
		where: { id: params.orderId },
		include: { plan: true },
	})
	if (!order) throw notFound("Order not found")
	if (order.status === "PAID") return order
	if (order.status !== "PENDING") throw conflict(`Order is ${order.status.toLowerCase()}`)

	// PENDING -> PAID is the gate; the loser of a race sees the winner's row.
	const claimed = await prisma.order.updateMany({
		where: { id: order.id, status: "PENDING" },
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

	const granted = await grantPlan({ userId: order.userId, plan: order.plan, source: "order" })
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
