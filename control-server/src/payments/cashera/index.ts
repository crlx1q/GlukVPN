/**
 * Cashera - hosted checkout for roubles (SBP, cards, crypto).
 *
 * The flow:
 *
 *   1. POST /integration/transactions with the amount in kopecks and our order
 *      id as `external_id` -> the transaction comes back with a `payment_url`;
 *   2. the browser goes to that page, or straight to one rail when
 *      CASHERA_PAYMENT_METHOD pins it;
 *   3. `transaction.status_updated` arrives on the callback, carrying
 *      `X-Api-Key` and `X-Secret` - the merchant's own credentials, compared in
 *      constant time before anything is read.
 *
 * Three habits this adapter keeps, all of them from Cashera's own guidance:
 *
 *   - only `status: "paid"` hands anything out. `pending` waits, `chargeback`
 *     is money leaving again.
 *   - unknown event types are acknowledged and ignored, never rejected: the
 *     list grows, and a 4xx only makes Cashera retry something we do not want.
 *     `webhook.test` is exactly that case, and is reported as a probe.
 *   - payouts and subscription lifecycle events are not ours to act on. We
 *     sell one-off orders; a recurring charge still arrives as an ordinary
 *     `transaction.status_updated`, which is the one that grants a plan.
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
import { createCasheraTransaction, getCasheraTransaction, verifyCasheraCredentials } from "./client"
import {
	CASHERA_CURRENCY,
	CASHERA_ID,
	CASHERA_LABEL,
	isConfigured,
	minimumMinor,
	paymentMethod,
} from "./config"

/** Cashera's status words in ours. Anything new is "unknown", not "paid". */
function statusKind(status: string): PaymentEventKind {
	switch (status.trim().toLowerCase()) {
		case "paid":
			return "paid"
		case "failed":
			return "failed"
		case "expired":
			return "expired"
		case "canceled":
		case "cancelled":
			return "canceled"
		// A chargeback is a refund with worse paperwork: the money is gone.
		case "refunded":
		case "chargeback":
			return "refunded"
		case "":
		case "created":
		case "pending":
		case "processing":
			return "pending"
		default:
			return "unknown"
	}
}

function text(value: unknown): string {
	if (typeof value === "string") return value.trim()
	if (typeof value === "number" && Number.isFinite(value)) return String(value)
	return ""
}

type WebhookBody = {
	event?: unknown
	transaction?: unknown
}

function parseBody(rawBody: string): WebhookBody {
	try {
		const parsed = JSON.parse(rawBody) as unknown
		return typeof parsed === "object" && parsed !== null ? (parsed as WebhookBody) : {}
	} catch {
		return {}
	}
}

export const paymentModule: PaymentModule = {
	id: CASHERA_ID,
	label: CASHERA_LABEL,
	currency: CASHERA_CURRENCY,
	// A getter: the floor depends on which rail is pinned in .env.
	get minimumMinor(): number {
		return minimumMinor()
	},
	configured: isConfigured,

	async createCheckout(input: PaymentOrderInput): Promise<PaymentCheckout> {
		if (input.currency.toUpperCase() !== CASHERA_CURRENCY) {
			throw serviceUnavailable("This plan has no price in roubles")
		}
		const transaction = await createCasheraTransaction({
			orderId: input.orderId,
			amountMinor: input.amountMinor,
			description: input.description,
			...(paymentMethod() ? { paymentMethod: paymentMethod() } : {}),
			// Per-payment callback: the merchant-wide address stays as a backup.
			callbackUrl: input.webhookUrl,
			successUrl: input.successUrl,
			failUrl: input.failUrl,
			metadata: input.metadata,
		})
		return {
			paymentUrl: transaction.paymentUrl,
			providerRef: transaction.uuid,
			manual: false,
			instructions: null,
		}
	},

	async fetchStatus(ref): Promise<PaymentSnapshot | null> {
		// Transactions are addressed by Cashera's uuid; there is no documented
		// lookup by `external_id`, so an order without a reference is left alone.
		if (!ref.providerRef) return null
		const transaction = await getCasheraTransaction(ref.providerRef)
		if (!transaction) return null
		return {
			providerRef: transaction.uuid,
			status: transaction.status,
			kind: statusKind(transaction.status),
			amountMinor: transaction.amount,
		}
	},

	verifyWebhook(request: WebhookRequest): boolean {
		return verifyCasheraCredentials(request.headers)
	},

	parseWebhook(request: WebhookRequest): PaymentEvent {
		const body = parseBody(request.rawBody)
		const event = text(body.event).toLowerCase()

		// The dashboard's "test webhook" button. Proves the URL and both
		// credentials, belongs to no order, grants nothing.
		if (event === "webhook.test") {
			return { kind: "probe", orderId: null, providerRef: null, status: event }
		}

		const row =
			typeof body.transaction === "object" && body.transaction !== null
				? (body.transaction as { uuid?: unknown; external_id?: unknown; status?: unknown; amount?: unknown })
				: null

		// A payout or a subscription lifecycle event: real, signed, and none of
		// our business. Acknowledged without touching an order.
		if (!row) {
			return { kind: "unknown", orderId: null, providerRef: null, status: event || "no_transaction" }
		}

		const status = text(row.status).toLowerCase()
		return {
			kind: statusKind(status),
			orderId: text(row.external_id) || null,
			providerRef: text(row.uuid) || null,
			status,
			amountMinor: typeof row.amount === "number" && Number.isFinite(row.amount) ? row.amount : null,
		}
	},
}
