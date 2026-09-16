/**
 * TabPay — hosted checkout for roubles (SBP + bank cards, 3-D Secure).
 *
 * The whole integration is three moves, and none of them touch card data:
 *
 *   1. POST /api/v1/payments with our own order id -> the gateway answers with
 *      a payment object and a `payUrl`;
 *   2. the browser is sent to `payUrl`, which is TabPay's own page (this is why
 *      GlukVPN has no card form of its own and never will);
 *   3. every final status arrives as a signed webhook, and that webhook - not
 *      the redirect back to the site - is what turns an order into a plan.
 *
 * Money is always an integer number of kopecks and the gateway settles in
 * roubles only, which is what `currency` below tells the billing layer.
 *
 * A test shop behaves exactly like a live one: same API, same signatures, same
 * webhooks, only `isTest: true` and buttons instead of a real bank on the
 * payment page. Going live is therefore an .env change (TABPAY_API_KEY,
 * TABPAY_SHOP_ID, TABPAY_WEBHOOK_SECRET) and nothing else.
 */
import { serviceUnavailable } from "../../lib/errors"
import type {
	PaymentCheckout,
	PaymentEvent,
	PaymentEventKind,
	PaymentModule,
	PaymentOrderInput,
	PaymentSnapshot,
	WebhookRequest,
} from "../types"
import {
	type TabpayWebhookEvent,
	createTabpayPayment,
	findTabpayPaymentByOrderId,
	getTabpayPayment,
	verifyTabpaySignature,
} from "./client"
import {
	TABPAY_CURRENCY,
	TABPAY_ID,
	TABPAY_LABEL,
	TABPAY_MIN_KOPECKS,
	isConfigured,
	method,
} from "./config"

/** TabPay's status vocabulary in ours. Anything new is "unknown", not "paid". */
function statusKind(status: string): PaymentEventKind {
	switch (status.trim().toUpperCase()) {
		case "SUCCESS":
			return "paid"
		case "FAILED":
			return "failed"
		case "EXPIRED":
			return "expired"
		case "CANCELED":
		case "CANCELLED":
			return "canceled"
		case "REFUNDED":
			return "refunded"
		case "":
		case "CREATED":
		case "PENDING":
			return "pending"
		default:
			return "unknown"
	}
}

function parseBody(rawBody: string): TabpayWebhookEvent {
	try {
		const parsed = JSON.parse(rawBody) as unknown
		return typeof parsed === "object" && parsed !== null ? (parsed as TabpayWebhookEvent) : {}
	} catch {
		return {}
	}
}

function text(value: unknown): string {
	return typeof value === "string" ? value.trim() : ""
}

export const paymentModule: PaymentModule = {
	id: TABPAY_ID,
	label: TABPAY_LABEL,
	currency: TABPAY_CURRENCY,
	minimumMinor: TABPAY_MIN_KOPECKS,
	configured: isConfigured,

	async createCheckout(input: PaymentOrderInput): Promise<PaymentCheckout> {
		if (input.currency.toUpperCase() !== TABPAY_CURRENCY) {
			// Reaching this means the catalogue has no rouble price for the plan;
			// charging the tenge number as roubles would be a silent 6x discount.
			throw serviceUnavailable("This plan has no price in roubles")
		}
		const payment = await createTabpayPayment({
			orderId: input.orderId,
			amountKopecks: input.amountMinor,
			description: input.description,
			...(input.customer.email ? { email: input.customer.email } : {}),
			...(input.customer.telegramId ? { telegramId: input.customer.telegramId } : {}),
			// Echoed back in the webhook, so the handler never has to guess.
			metadata: input.metadata,
			successUrl: input.successUrl,
			failUrl: input.failUrl,
			...(method() ? { method: method() } : {}),
		})
		return { paymentUrl: payment.payUrl, providerRef: payment.id, manual: false, instructions: null }
	},

	async fetchStatus(ref): Promise<PaymentSnapshot | null> {
		// The gateway knows our order id, so a lost providerRef is recoverable.
		const payment = ref.providerRef
			? await getTabpayPayment(ref.providerRef)
			: await findTabpayPaymentByOrderId(ref.orderId)
		if (!payment) return null
		const status = text(payment.status)
		return {
			providerRef: payment.id ?? null,
			status,
			kind: statusKind(status),
			amountMinor: typeof payment.amountKopecks === "number" ? payment.amountKopecks : null,
		}
	},

	verifyWebhook(request: WebhookRequest): boolean {
		return verifyTabpaySignature(request.rawBody, request.headers)
	},

	parseWebhook(request: WebhookRequest): PaymentEvent {
		const event = parseBody(request.rawBody)
		const paymentId = text(event.id)
		const orderId = text(event.orderId)
		const status = text(event.status).toUpperCase()
		// The dashboard's "send test webhook" button signs a synthetic event
		// whose id is not a payment. It proves the URL and the secret, and must
		// hand out nothing. `test: true` is a different thing entirely: a sandbox
		// payment is exactly what the bank's reviewer will make, and it has to
		// work.
		if (paymentId.startsWith("test-")) {
			return { kind: "probe", orderId: null, providerRef: paymentId, status }
		}
		return {
			kind: statusKind(status),
			orderId: orderId || null,
			providerRef: paymentId || null,
			status,
			amountMinor: typeof event.amountKopecks === "number" ? event.amountKopecks : null,
		}
	},
}
