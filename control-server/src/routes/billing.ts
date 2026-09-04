import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { badRequest, unauthorized } from "../lib/errors"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import {
	createOrder,
	handleStripeEvent,
	listPlans,
	orderView,
	planView,
	verifyStripeSignature,
} from "../services/billing"

const CreateOrderBody = z.object({
	planCode: z.string().trim().min(2).max(32),
})

/**
 * Public plan catalogue, the user's own orders, and the gateway webhook.
 * Administrative actions (mark paid, cancel, grant) live in routes/admin.ts.
 */
export async function billingRoutes(app: FastifyInstance): Promise<void> {
	app.get(
		"/api/billing/plans",
		{ config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (_request, reply) => {
			const plans = await listPlans()
			return reply.send({
				billingEnabled: config.billingEnabled,
				provider: config.billingEnabled ? config.BILLING_PROVIDER : null,
				currency: config.BILLING_CURRENCY,
				plans: plans.map(planView),
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
	})
}
