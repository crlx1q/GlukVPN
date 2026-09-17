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
import { badRequest, serviceUnavailable } from "../../lib/errors"
import type {
	PaymentCheckout,
	PaymentEvent,
	PaymentEventKind,
	PaymentMethodOption,
	PaymentModule,
	PaymentOrderInput,
	PaymentSnapshot,
	WebhookRequest,
} from "../types"
import { createCasheraTransaction, getCasheraTransaction, verifyCasheraCredentials } from "./client"
import {
	CASHERA_CARD_MIN_MINOR,
	CASHERA_CURRENCY,
	CASHERA_ID,
	CASHERA_KNOWN_METHODS,
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

/**
 * The rails Cashera offers, as the checkout lists them.
 *
 * The card floor is the one thing a payer has to be told before they pick:
 * Cashera refuses a card payment under 100 ₽, and the 1 ₽ trial is exactly
 * the order that runs into it. `mastercard` and `cryptobot` exist in the API
 * but are not listed - they are narrower variants of the two rails above
 * them, and .env can still pin either.
 */
const METHODS: readonly PaymentMethodOption[] = [
	{ id: "all", label: "Все способы" },
	{ id: "sbp", label: "СБП" },
	{ id: "card", label: "Карта (от 100 ₽)", minimumMinor: CASHERA_CARD_MIN_MINOR },
	{ id: "crypto", label: "Криптовалюта" },
]

/**
 * Which rail this transaction is created for.
 *
 * The payer's choice wins over .env: "all" sends no `payment_method` and lets
 * them choose on Cashera's form, a known id pins that rail, and no choice at
 * all falls back to CASHERA_PAYMENT_METHOD. An unknown id is treated as no
 * choice, because passing one through is a rejected transaction.
 */
function checkoutMethod(asked: string | null | undefined): string {
	const value = (asked ?? "").trim().toLowerCase()
	if (!value) return paymentMethod()
	if (value === "all") return ""
	return CASHERA_KNOWN_METHODS.includes(value) ? value : paymentMethod()
}

/** The rails that carry Cashera's 100 ₽ floor. */
function isCardRail(method: string): boolean {
	return method === "card" || method === "mastercard"
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

	availableMethods(currency: string): PaymentMethodOption[] {
		// Roubles or nothing: a currency this gateway cannot settle has no rails.
		return currency.trim().toUpperCase() === CASHERA_CURRENCY ? [...METHODS] : []
	},

	async createCheckout(input: PaymentOrderInput): Promise<PaymentCheckout> {
		if (input.currency.toUpperCase() !== CASHERA_CURRENCY) {
			throw serviceUnavailable("This plan has no price in roubles")
		}
		const chosen = checkoutMethod(input.method)
		// Cashera answers a card payment under 100 ₽ with a refusal. Saying so
		// here is the difference between a clear message and a gateway error on
		// the 1 ₽ trial; the site greys the card out for the same reason.
		if (isCardRail(chosen) && input.amountMinor < CASHERA_CARD_MIN_MINOR) {
			throw badRequest("Card payments start at 100 ₽ - pay by SBP instead")
		}
		const transaction = await createCasheraTransaction({
			orderId: input.orderId,
			amountMinor: input.amountMinor,
			description: input.description,
			...(chosen ? { paymentMethod: chosen } : {}),
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
