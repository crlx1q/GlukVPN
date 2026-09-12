import type { User } from "@prisma/client"
import type { FastifyInstance, FastifyRequest } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { badRequest, unauthorized } from "../lib/errors"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import {
	createOrder,
	handleStripeEvent,
	handleTabpayEvent,
	listPlans,
	minimumChargeMinor,
	orderView,
	planView,
	priceLabel,
	reconcilePendingOrders,
	settlementCurrency,
	verifyStripeSignature,
} from "../services/billing"
import { normalizeCurrency, resolveMarketByIp, resolvePlanPrice } from "../services/pricing"
import { applyPromo, promoPlanCodes } from "../services/promo"
import { verifyTabpaySignature } from "../services/tabpay"
import { claimTrial, trialOffer } from "../services/trial"

const CreateOrderBody = z.object({
	planCode: z.string().trim().min(2).max(32),
	// Optional: the client echoes back the currency it was quoted in, so a
	// visitor who saw roubles is charged in roubles even if the edge changes
	// its mind about their country between the two requests.
	currency: z.string().trim().min(3).max(3).optional(),
	// A code typed by the visitor. It is validated again on the server, and the
	// reply carries the amount that was actually charged.
	promoCode: z.string().trim().max(32).optional(),
})

const PromoCheckBody = z.object({
	code: z.string().trim().min(2).max(32),
	planCode: z.string().trim().min(2).max(32),
	currency: z.string().trim().min(3).max(3).optional(),
})

/**
 * The signed-in user, or null for a visitor.
 *
 * The trial offer is shown to people who have not signed up yet - that is the
 * whole point of the banner - so the endpoint cannot demand a token, but it
 * still has to give a straight answer to somebody who has one.
 */
async function optionalUser(request: FastifyRequest): Promise<User | null> {
	if (typeof request.headers.authorization !== "string") return null
	try {
		await requireUser(request)
	} catch {
		// An expired token is a visitor, not an error: the page still renders.
		return null
	}
	return request.authUser?.user ?? null
}

/**
 * Public plan catalogue, the user's own orders, and the gateway webhook.
 * Administrative actions (mark paid, cancel, grant) live in routes/admin.ts.
 */
export async function billingRoutes(app: FastifyInstance): Promise<void> {
	app.get(
		"/api/billing/plans",
		{ config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (request, reply) => {
			// Price follows the visitor, not the server: the edge header when the
			// request came through Cloudflare, otherwise GeoIP on the connecting
			// address, and only then the self-reported zone. ?currency= lets a
			// client override it. `market` is in the reply so the site and the
			// apps can pick their language from the same answer instead of
			// guessing it a second time and disagreeing with the price.
			const market = await resolveMarketByIp(request)
			const asked = (request.query as { currency?: string } | undefined)?.currency
			const currency = normalizeCurrency(asked) ?? market.currency
			const plans = await listPlans()
			// TabPay settles in roubles only, so a visitor quoted in tenge or
			// dollars still sees a rouble amount on their statement. The exact
			// figure travels with every plan, so the page can name it up front
			// instead of leaving it as a surprise on the gateway's own screen.
			const settle = settlementCurrency()
			return reply.send({
				billingEnabled: config.billingEnabled,
				provider: config.billingEnabled ? config.BILLING_PROVIDER : null,
				currency,
				market,
				settlement: settle ? { currency: settle } : null,
				plans: plans.map((plan) => {
					const view = planView(plan, currency)
					const settled = settle && settle !== view.currency.toUpperCase()
					if (!settled || view.priceMinor === 0) return view
					const charged = resolvePlanPrice(plan, settle)
					return {
						...view,
						settlementCurrency: charged.currency,
						settlementMinor: charged.priceMinor,
						settlementLabel: priceLabel(charged.priceMinor, charged.currency),
					}
				}),
			})
		},
	)

	app.post(
		"/api/billing/orders",
		{ preHandler: requireUser, config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = CreateOrderBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("planCode is required")
			const { user } = getAuthUser(request)
			const { order, checkout } = await createOrder({
				user,
				planCode: parsed.data.planCode,
				ip: clientIp(request),
				// Charge in the currency the visitor was actually quoted.
				currency:
					normalizeCurrency(parsed.data.currency) ??
					(await resolveMarketByIp(request)).currency,
				promoCode: parsed.data.promoCode ?? null,
			})
			return reply.code(201).send({
				order: orderView(order),
				paymentUrl: checkout.paymentUrl,
				manual: checkout.manual,
				instructions: checkout.instructions,
			})
		},
	)

	app.get("/api/billing/orders", { preHandler: requireUser }, async (request, reply) => {
		const { user } = getAuthUser(request)
		const orders = await prisma.order.findMany({
			where: { userId: user.id },
			include: { plan: true },
			orderBy: { createdAt: "desc" },
			take: 50,
		})
		return reply.send({ orders: orders.map(orderView) })
	})

	// Called when the browser comes back from the hosted payment page. The
	// webhook is still what grants a plan; this asks the gateway directly, so a
	// delivery that is late or lost cannot leave somebody who has paid looking
	// at "no subscription", and a refused attempt cannot stand in the way of the
	// next one.
	app.post(
		"/api/billing/orders/sync",
		{ preHandler: requireUser, config: { rateLimit: { max: 20, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const { user } = getAuthUser(request)
			const synced = await reconcilePendingOrders(user)
			const orders = await prisma.order.findMany({
				where: { userId: user.id },
				include: { plan: true },
				orderBy: { createdAt: "desc" },
				take: 10,
			})
			return reply.send({ synced, orders: orders.map(orderView) })
		},
	)

	// -------------------------------------------------------------- trial ----

	// Open to visitors on purpose: the home page banner and /trial are rendered
	// from this, and somebody who has not signed up yet still needs the price,
	// the dates and the rules. `eligibility.reason` names what is missing
	// ("sign_in_required", "telegram_required", ...) so the page can ask for
	// exactly that instead of guessing.
	app.get(
		"/api/billing/trial",
		{ config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const user = await optionalUser(request)
			const asked = (request.query as { currency?: string } | undefined)?.currency
			const currency =
				normalizeCurrency(asked) ?? (await resolveMarketByIp(request)).currency
			const trial = await trialOffer({ user, currency })
			return reply.send({
				billingEnabled: config.billingEnabled,
				provider: config.billingEnabled ? config.BILLING_PROVIDER : null,
				trial,
			})
		},
	)

	// Claiming is an ordinary order for a hidden plan: same gateway, same
	// webhook, same grant. Eligibility is decided in the service, never here.
	app.post(
		"/api/billing/trial/claim",
		{ preHandler: requireUser, config: { rateLimit: { max: 5, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const { user } = getAuthUser(request)
			const { order, checkout, days } = await claimTrial({ user, ip: clientIp(request) })
			return reply.code(201).send({
				order: orderView(order),
				paymentUrl: checkout.paymentUrl,
				manual: checkout.manual,
				instructions: checkout.instructions,
				days,
			})
		},
	)

	// -------------------------------------------------------------- promo ----

	// Quotes a code before checkout so the pricing page can show the new
	// figure. It runs the same validation the order will run, so the preview
	// and the charge cannot disagree; the refusal `code` ("promo_expired",
	// "promo_already_used", ...) is what the site turns into a sentence.
	app.post(
		"/api/billing/promo/check",
		{ config: { rateLimit: { max: 20, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = PromoCheckBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("code and planCode are required")
			// Open to visitors on purpose: somebody comparing tariffs should see
			// what a code is worth before registering. The per-account limit is
			// checked for the account that actually pays - here when there is one,
			// and again in `createOrder`, which is the moment that counts.
			const user = await optionalUser(request)

			const plan = await prisma.plan.findFirst({
				where: { code: parsed.data.planCode.toLowerCase(), active: true },
				include: { prices: true },
			})
			if (!plan) throw badRequest("Unknown plan")

			// Two amounts are in play and they are not always in the same
			// currency: the one on the visitor's screen and the one the gateway
			// settles. Quoting the discount in the settlement currency is what
			// put "-25%, к оплате 284 ₽" under a card priced at 790 ₸, so the
			// code is validated against the amount that is really charged and
			// the answer is returned in the currency that was asked for.
			const askedCurrency = normalizeCurrency(parsed.data.currency)
			const wanted = askedCurrency ?? (await resolveMarketByIp(request)).currency
			const shown = resolvePlanPrice(plan, wanted)
			const settle = settlementCurrency()
			const charged = settle ? resolvePlanPrice(plan, settle) : shown
			const applied = await applyPromo({
				code: parsed.data.code,
				userId: user?.id ?? null,
				planCode: plan.code,
				amountMinor: charged.priceMinor,
				currency: charged.currency,
				// The gateway's floor is a rouble figure, so it only means anything
				// against the amount that is actually settled.
				minimumMinor: minimumChargeMinor(),
			})

			// One currency on both sides: the validated figures are the ones to
			// show. Otherwise the percentage is applied to the displayed price,
			// leaving at least one minor unit so the card never reads "0 ₸".
			const same = shown.currency.toUpperCase() === charged.currency.toUpperCase()
			const discountMinor = same
				? applied.discountMinor
				: Math.min(
						Math.max(0, shown.priceMinor - 1),
						Math.round((shown.priceMinor * applied.percentOff) / 100),
					)
			return reply.send({
				ok: true,
				code: applied.promo.code,
				percentOff: applied.percentOff,
				discountMinor,
				amountMinor: shown.priceMinor - discountMinor,
				currency: shown.currency,
				// What the bank will really debit, when that is another currency.
				// The pricing page prints it next to the discounted price so the
				// two figures cannot look like a mistake.
				settlement: same
					? null
					: {
							currency: charged.currency,
							amountMinor: applied.amountMinor,
							label: priceLabel(applied.amountMinor, charged.currency),
						},
				// Which plans the code covers, so the pricing page can mark the cards
				// it applies to instead of quietly discounting everything.
				planCode: plan.code,
				planCodes: promoPlanCodes(applied.promo),
			})
		},
	)

	// Stripe posts JSON and signs the *raw* bytes, so this scope keeps the body
	// as a string and parses it only after the signature checks out. The parser
	// is registered inside the scope, so every other route keeps Fastify's own.
	await app.register(async (scope) => {
		scope.addContentTypeParser(
			"application/json",
			{ parseAs: "string" },
			(_request, body, done) => done(null, body),
		)
		scope.post(
			"/api/billing/webhook/stripe",
			{ config: { rateLimit: { max: 120, timeWindow: "1 minute" } } },
			async (request, reply) => {
				if (config.BILLING_PROVIDER !== "stripe") throw unauthorized("Webhook not enabled")
				const raw = typeof request.body === "string" ? request.body : ""
				const signature = request.headers["stripe-signature"]
				if (!verifyStripeSignature(raw, typeof signature === "string" ? signature : undefined)) {
					throw unauthorized("Invalid webhook signature")
				}
				let event: Record<string, unknown>
				try {
					event = JSON.parse(raw) as Record<string, unknown>
				} catch {
					throw badRequest("Malformed webhook body")
				}
				const outcome = await handleStripeEvent(event as Parameters<typeof handleStripeEvent>[0])
				return reply.send({ received: true, ...outcome })
			},
		)

		// TabPay signs `${timestamp}.${rawBody}`, so it belongs in the same raw
		// body scope. Anything that is not a signature failure answers 200: the
		// gateway retries a non-2xx for a day, and an event we cannot act on -
		// the other environment's shop, the dashboard's own probe - will not
		// become actionable on the fifth attempt. What happened is reported in
		// `handled` and `ignored`, which is what the delivery log then shows.
		scope.post(
			"/api/billing/webhook/tabpay",
			{ config: { rateLimit: { max: 300, timeWindow: "1 minute" } } },
			async (request, reply) => {
				if (config.BILLING_PROVIDER !== "tabpay") throw unauthorized("Webhook not enabled")
				const raw = typeof request.body === "string" ? request.body : ""
				if (!verifyTabpaySignature(raw, request.headers as Record<string, unknown>)) {
					throw unauthorized("Invalid webhook signature")
				}
				let event: Record<string, unknown>
				try {
					event = JSON.parse(raw) as Record<string, unknown>
				} catch {
					throw badRequest("Malformed webhook body")
				}
				const outcome = await handleTabpayEvent(event as Parameters<typeof handleTabpayEvent>[0])
				return reply.send({ received: true, ...outcome })
			},
		)
	})
}
