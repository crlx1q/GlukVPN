/**
 * MulenPay - hosted checkout for roubles with a fiscal receipt.
 *
 * The flow is the familiar one:
 *
 *   1. POST /payments with our order id as `uuid`, the amount as a string of
 *      roubles, a receipt line and a sha1 signature -> the gateway answers
 *      with `paymentUrl` and its own payment id;
 *   2. the browser goes to `paymentUrl`, MulenPay's own page (cards, SBP);
 *   3. the result arrives as a callback to the URL configured in the shop
 *      dashboard - not per payment, so it is set once by hand.
 *
 * What makes this gateway different from TabPay, and what the code here is
 * shaped around: **the callback is not signed**. It carries `{ id, amount,
 * currency, uuid, payment_status }` and nothing that proves the sender. So a
 * delivery is treated as a hint, never as evidence: `confirmWebhookByStatus`
 * makes the billing layer re-read `GET /payments/{id}` and grant the plan only
 * if MulenPay itself says status 3. An optional `?token=` on the callback URL
 * keeps the address from being trivially guessable, which is a lock on the
 * letterbox and not a signature.
 */
import { serviceUnavailable } from "../../lib/errors"
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
import {
	MULENPAY_STATUS_PAID,
	type MulenpayWebhookEvent,
	createMulenpayPayment,
	getMulenpayPayment,
	kopecksFrom,
} from "./client"
import {
	MULENPAY_CURRENCY,
	MULENPAY_ID,
	MULENPAY_LABEL,
	MULENPAY_MIN_KOPECKS,
	isConfigured,
	webhookToken,
} from "./config"

/**
 * MulenPay's integer statuses in our vocabulary.
 *
 * A hold (5, 6) is money reserved and not taken, so it counts as pending: the
 * plan is granted when it is captured. An unlisted number is "unknown" - the
 * event is acknowledged and nothing is handed out on a guess.
 */
function statusKind(status: number): PaymentEventKind {
	switch (status) {
		case MULENPAY_STATUS_PAID:
			return "paid"
		case 2:
			return "canceled"
		case 4:
			return "failed"
		case 0:
		case 1:
		case 5:
		case 6:
			return "pending"
		default:
			return "unknown"
	}
}

/** The callback's own wording. Only "success" is worth re-checking as paid. */
function callbackKind(status: string): PaymentEventKind {
	switch (status) {
		case "success":
			return "paid"
		case "cancel":
		case "canceled":
		case "cancelled":
			return "canceled"
		case "fail":
		case "failed":
		case "error":
			return "failed"
		case "expired":
			return "expired"
		case "refund":
		case "refunded":
			return "refunded"
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

function parseBody(rawBody: string): MulenpayWebhookEvent {
	try {
		const parsed = JSON.parse(rawBody) as unknown
		return typeof parsed === "object" && parsed !== null ? (parsed as MulenpayWebhookEvent) : {}
	} catch {
		return {}
	}
}

/** Same length, then every byte - no early exit on the first difference. */
function sameToken(expected: string, given: string): boolean {
	if (expected.length !== given.length) return false
	let diff = 0
	for (let i = 0; i < expected.length; i += 1) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i)
	return diff === 0
}

/**
 * The one rail this gateway can be asked for: its own page, with everything
 * on it.
 *
 * MulenPay's hosted form takes cards and SBP, but `POST /payments` documents
 * no field for choosing between them - the body is currency, amount, uuid,
 * shopId, description, sign, language, subscribe, website_url, client and
 * items[], and nothing else. Inventing a `payment_method` would risk a
 * validation error on *every* payment, so the checkout offers the universal
 * form only and the payer picks the rail on MulenPay's own page. When the
 * field is documented, adding it here and in `createCheckout` is the whole
 * change.
 */
const METHODS: readonly PaymentMethodOption[] = [{ id: "all", label: "Все способы" }]

/** The shop's own site, for the payment page. Derived from the return URL. */
function websiteUrl(successUrl: string): string {
	try {
		return new URL(successUrl).origin
	} catch {
		return ""
	}
}

export const paymentModule: PaymentModule = {
	id: MULENPAY_ID,
	label: MULENPAY_LABEL,
	currency: MULENPAY_CURRENCY,
	minimumMinor: MULENPAY_MIN_KOPECKS,
	configured: isConfigured,

	availableMethods(currency: string): PaymentMethodOption[] {
		return currency.trim().toUpperCase() === MULENPAY_CURRENCY ? [...METHODS] : []
	},
	// The callback is unsigned: never grant on its word alone.
	confirmWebhookByStatus: true,

	async createCheckout(input: PaymentOrderInput): Promise<PaymentCheckout> {
		if (input.currency.toUpperCase() !== MULENPAY_CURRENCY) {
			// The plan has no rouble price; sending the tenge number would charge
			// roughly a sixth of the real price.
			throw serviceUnavailable("This plan has no price in roubles")
		}
		const site = websiteUrl(input.successUrl)
		const payment = await createMulenpayPayment({
			orderId: input.orderId,
			amountKopecks: input.amountMinor,
			description: input.description,
			...(input.customer.email ? { email: input.customer.email } : {}),
			...(site ? { websiteUrl: site } : {}),
		})
		return {
			paymentUrl: payment.paymentUrl,
			providerRef: payment.id || null,
			manual: false,
			instructions: null,
		}
	},

	async fetchStatus(ref): Promise<PaymentSnapshot | null> {
		// The API is addressed by MulenPay's own id only: there is no lookup by
		// our `uuid`, so an order that never got a reference cannot be asked
		// about. It is left alone rather than guessed at.
		if (!ref.providerRef) return null
		const state = await getMulenpayPayment(ref.providerRef)
		if (!state) return null
		return {
			providerRef: ref.providerRef,
			status: String(state.status),
			kind: statusKind(state.status),
			amountMinor: state.amountMinor,
		}
	},

	/**
	 * There is no signature to check, so this only enforces the optional URL
	 * token. With no token configured every delivery is accepted and the
	 * status re-read from the API - which is the check that actually matters.
	 */
	verifyWebhook(request: WebhookRequest): boolean {
		const expected = webhookToken()
		if (!expected) return true
		const given = text(request.query?.token) || text(request.headers["x-webhook-token"])
		return sameToken(expected, given)
	},

	parseWebhook(request: WebhookRequest): PaymentEvent {
		const event = parseBody(request.rawBody)
		const orderId = text(event.uuid)
		const providerRef = text(event.id)
		const status = text(event.payment_status).toLowerCase()
		return {
			kind: callbackKind(status),
			orderId: orderId || null,
			providerRef: providerRef || null,
			status,
			amountMinor: kopecksFrom(event.amount),
		}
	},
}
