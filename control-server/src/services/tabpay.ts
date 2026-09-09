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
 * roubles only; `settlementCurrency()` in billing.ts is what keeps a visitor
 * quoted in tenge from being charged "790" of something else.
 *
 * A test shop behaves exactly like a live one: same API, same signatures, same
 * webhooks, only `isTest: true` and buttons instead of a real bank on the
 * payment page. Going live is therefore an .env change (TABPAY_API_KEY,
 * TABPAY_SHOP_ID, TABPAY_WEBHOOK_SECRET) and nothing else.
 */
import { createHmac, timingSafeEqual } from "node:crypto"
import { config } from "../config"
import { serviceUnavailable } from "../lib/errors"
import type { CheckoutResult, PaymentProvider } from "./billing"

/** TabPay accepts roubles and nothing else. */
export const TABPAY_CURRENCY = "RUB"
/** Smallest payment the gateway accepts: 1 rouble. */
export const TABPAY_MIN_KOPECKS = 100
/** Largest payment the gateway accepts: 100 million roubles. */
export const TABPAY_MAX_KOPECKS = 10_000_000_000
/** Webhook freshness window for the v2 signature scheme, in seconds. */
const SIGNATURE_WINDOW_SEC = 300

export type TabpayStatus =
	| "CREATED"
	| "PENDING"
	| "SUCCESS"
	| "FAILED"
	| "EXPIRED"
	| "REFUNDED"
	| "CANCELED"

export type TabpayPayment = {
	id: string
	orderId: string
	status: TabpayStatus | string
	amountKopecks: number
	commissionKopecks?: number | null
	description?: string | null
	method?: string | null
	telegramId?: string | null
	metadata?: Record<string, unknown> | null
	successUrl?: string | null
	failUrl?: string | null
	payUrl: string
	/** True for a sandbox shop: the outcome is chosen on the payment page. */
	isTest?: boolean
	paidAt?: string | null
	createdAt?: string
}

/**
 * The webhook body. Every field is `unknown` because it arrives from the
 * network: the route validates before trusting anything.
 *
 * `test` is a value to read, never a field to detect - a sandbox payment is a
 * real event that must hand out the plan, while the dashboard's "send test
 * webhook" button is not (its `id` carries a `test-` prefix instead of a UUID).
 */
export type TabpayWebhookEvent = {
	id?: unknown
	orderId?: unknown
	status?: unknown
	amountKopecks?: unknown
	telegramId?: unknown
	metadata?: unknown
	test?: unknown
}

type TabpayError = { statusCode?: number; message?: string | string[]; error?: string }

type TabpayResult<T> =
	| { ok: true; status: number; data: T }
	| { ok: false; status: number; message: string }

function apiUrl(path: string): string {
	return `${config.TABPAY_API_BASE.replace(/\/+$/, "")}${path}`
}

function siteUrl(path: string): string {
	return `${config.SITE_BASE_URL.replace(/\/+$/, "")}${path}`
}

/** TabPay returns `{statusCode, message, error}`; message may be a list. */
function errorText(body: TabpayError | null, fallback: string): string {
	if (!body) return fallback
	if (Array.isArray(body.message)) return body.message.join("; ") || fallback
	if (typeof body.message === "string" && body.message.trim()) return body.message.trim()
	return body.error?.trim() || fallback
}

/**
 * One call to the TabPay REST API.
 *
 * A refusal (4xx) is returned rather than thrown, because the caller often
 * knows what to do with it - a 409 on create means "this order already has a
 * payment", which is a success in disguise. Only "no answer at all" throws.
 */
async function tabpayRequest<T>(
	path: string,
	init: { method: "GET" | "POST"; body?: unknown },
): Promise<TabpayResult<T>> {
	const key = config.TABPAY_API_KEY.trim()
	if (!key) throw serviceUnavailable("TabPay is not configured")

	let response: Response
	try {
		response = await fetch(apiUrl(path), {
			method: init.method,
			headers: {
				// The key is a server-side secret: it never reaches a browser.
				"x-api-key": key,
				accept: "application/json",
				...(init.body === undefined ? {} : { "content-type": "application/json" }),
			},
			...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
			signal: AbortSignal.timeout(config.TABPAY_TIMEOUT_MS),
		})
	} catch {
		throw serviceUnavailable("Payment gateway did not respond")
	}

	const payload = (await response.json().catch(() => null)) as (T & TabpayError) | null
	if (!response.ok) {
		return {
			ok: false,
			status: response.status,
			message: errorText(payload, `Payment gateway error ${response.status}`),
		}
	}
	if (!payload) return { ok: false, status: response.status, message: "Payment gateway returned an empty body" }
	return { ok: true, status: response.status, data: payload as T }
}

export type CreateTabpayPaymentInput = {
	/** Our order id. Unique per shop forever: a repeat is answered with 409. */
	orderId: string
	amountKopecks: number
	description?: string
	email?: string
	telegramId?: string
	metadata?: Record<string, unknown>
	successUrl?: string
	failUrl?: string
	/** "SBP" or "CARD" to pin the method; omitted, the payer chooses. */
	method?: string
}

/** GET /api/v1/payments?orderId=... — our own id, so no mapping table. */
export async function findTabpayPaymentByOrderId(orderId: string): Promise<TabpayPayment | null> {
	const result = await tabpayRequest<TabpayPayment>(
		`/api/v1/payments?orderId=${encodeURIComponent(orderId)}`,
		{ method: "GET" },
	)
	return result.ok && result.data?.id ? result.data : null
}

/** GET /api/v1/payments/{id} — used for reconciliation, never in a poll loop. */
export async function getTabpayPayment(id: string): Promise<TabpayPayment | null> {
	const result = await tabpayRequest<TabpayPayment>(`/api/v1/payments/${encodeURIComponent(id)}`, {
		method: "GET",
	})
	return result.ok && result.data?.id ? result.data : null
}

/**
 * POST /api/v1/payments.
 *
 * Duplicate protection is the documented contract: repeating an orderId is
 * answered with 409 instead of charging twice, and the payment that already
 * exists is the one to send the customer to. That is also the recovery path
 * after a timeout, which is why the lookup is here and not at the call site.
 */
export async function createTabpayPayment(input: CreateTabpayPaymentInput): Promise<TabpayPayment> {
	if (!Number.isInteger(input.amountKopecks)) throw serviceUnavailable("Amount must be whole kopecks")
	if (input.amountKopecks < TABPAY_MIN_KOPECKS) throw serviceUnavailable("Amount is below the gateway minimum")
	if (input.amountKopecks > TABPAY_MAX_KOPECKS) throw serviceUnavailable("Amount is above the gateway maximum")

	const result = await tabpayRequest<TabpayPayment>("/api/v1/payments", {
		method: "POST",
		body: {
			orderId: input.orderId,
			amountKopecks: input.amountKopecks,
			...(input.description ? { description: input.description.slice(0, 255) } : {}),
			...(input.email ? { email: input.email } : {}),
			...(input.telegramId ? { telegramId: input.telegramId } : {}),
			...(input.metadata ? { metadata: input.metadata } : {}),
			...(input.successUrl ? { successUrl: input.successUrl } : {}),
			...(input.failUrl ? { failUrl: input.failUrl } : {}),
			...(input.method ? { method: input.method } : {}),
		},
	})
	if (result.ok && result.data?.payUrl) return result.data

	if (!result.ok && result.status === 409) {
		const existing = await findTabpayPaymentByOrderId(input.orderId)
		if (existing?.payUrl) return existing
	}
	throw serviceUnavailable(result.ok ? "Payment gateway returned no payment link" : result.message)
}

/**
 * POST /api/v1/payments/{id}/cancel — only before the customer starts paying.
 * A 409 means "the payment may still go through", so the caller waits for the
 * final webhook instead of assuming the order is dead.
 */
export async function cancelTabpayPayment(id: string): Promise<{ cancelled: boolean; message?: string }> {
	const result = await tabpayRequest<TabpayPayment>(`/api/v1/payments/${encodeURIComponent(id)}/cancel`, {
		method: "POST",
	})
	return result.ok ? { cancelled: true } : { cancelled: false, message: result.message }
}

function headerText(headers: Record<string, unknown>, name: string): string {
	const raw = headers[name]
	if (typeof raw === "string") return raw.trim()
	if (Array.isArray(raw) && typeof raw[0] === "string") return raw[0].trim()
	return ""
}

function hmacHex(secret: string, payload: string): string {
	return createHmac("sha256", secret).update(payload, "utf8").digest("hex")
}

function sameSignature(expected: string, candidate: string): boolean {
	const given = candidate.trim().toLowerCase()
	if (given.length !== expected.length) return false
	const a = Buffer.from(expected, "utf8")
	const b = Buffer.from(given, "utf8")
	return a.length === b.length && timingSafeEqual(a, b)
}

/**
 * Verifies a webhook against the shop's signing secret.
 *
 * Two schemes are sent on every delivery and both are checked here:
 *
 *   - `X-Signature-V2` = HMAC-SHA256 over `${X-Timestamp}.${raw body}`. This is
 *     the one to trust: the timestamp is regenerated for every delivery
 *     attempt, so a five-minute window makes a captured webhook useless to
 *     replay. It requires the server clock to be on NTP.
 *   - `X-Signature` = HMAC-SHA256 over the raw body alone, kept by TabPay for
 *     compatibility and accepted here only when v2 is absent.
 *
 * The body must be the raw bytes as received: re-serialising the JSON changes
 * key order and whitespace, and the signature stops matching.
 */
export function verifyTabpaySignature(rawBody: string, headers: Record<string, unknown>): boolean {
	const secret = config.TABPAY_WEBHOOK_SECRET.trim()
	if (!secret) return false

	const v2 = headerText(headers, "x-signature-v2")
	if (v2) {
		const timestamp = headerText(headers, "x-timestamp")
		const seconds = Number(timestamp)
		if (!/^\d{1,15}$/.test(timestamp) || !Number.isFinite(seconds)) return false
		if (Math.abs(Date.now() / 1000 - seconds) > SIGNATURE_WINDOW_SEC) return false
		return sameSignature(hmacHex(secret, `${timestamp}.${rawBody}`), v2)
	}

	const v1 = headerText(headers, "x-signature")
	return v1 ? sameSignature(hmacHex(secret, rawBody), v1) : false
}

/** Order metadata, defensively: it is JSON from the database. */
function orderMeta(value: unknown): Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: {}
}

export const tabpayProvider: PaymentProvider = {
	name: "tabpay",
	async createCheckout(order, plan, user): Promise<CheckoutResult> {
		if (order.currency.toUpperCase() !== TABPAY_CURRENCY) {
			// Reaching this means the catalogue has no rouble price for the plan;
			// charging the tenge number as roubles would be a silent 6x discount.
			throw serviceUnavailable("This plan has no price in roubles")
		}

		const meta = orderMeta(order.metadata)
		const isTrial = meta.source === "trial"
		const description = `GlukVPN ${plan.name}, ${plan.days} дн. (заказ ${order.id.slice(0, 8).toUpperCase()})`
		// Telegram ids are digits; anything else is not one and is left out.
		const telegramId = /^\d{1,20}$/.test(user.telegramId ?? "") ? (user.telegramId as string) : undefined
		// Where the payment page sends the browser back to. The operator can pin
		// both in .env; by default a trial returns to /trial/ and a normal order
		// to the account, because those are the two pages that can explain what
		// just happened.
		const successUrl =
			config.BILLING_SUCCESS_URL.trim() ||
			siteUrl(isTrial ? `/trial/?paid=1&order=${order.id}` : `/app/?paid=1&order=${order.id}`)
		const failUrl =
			config.BILLING_CANCEL_URL.trim() ||
			siteUrl(isTrial ? `/trial/?failed=1&order=${order.id}` : `/pricing/?failed=1&order=${order.id}`)

		const payment = await createTabpayPayment({
			orderId: order.id,
			amountKopecks: order.amountMinor,
			description,
			...(user.email ? { email: user.email } : {}),
			...(telegramId ? { telegramId } : {}),
			// Echoed back in the webhook, so the handler never has to guess.
			metadata: {
				orderId: order.id,
				userId: user.id,
				planCode: plan.code,
				channel: config.CHANNEL,
				...(isTrial ? { source: "trial" } : {}),
			},
			successUrl,
			failUrl,
			...(config.TABPAY_METHOD ? { method: config.TABPAY_METHOD } : {}),
		})

		return { paymentUrl: payment.payUrl, providerRef: payment.id, manual: false, instructions: null }
	},
}
