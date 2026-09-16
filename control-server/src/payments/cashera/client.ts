/**
 * The Cashera REST client and its webhook credential check.
 *
 * Speaks Cashera and nothing else: minor units, RUB, lowercase statuses. The
 * translation into our vocabulary lives in `index.ts`.
 *
 * The API is refreshingly plain - `POST /integration/transactions` returns the
 * transaction as a top-level object with a `payment_url` - but it has two
 * sharp edges that the code below handles explicitly:
 *
 *   - `callback_url` must be HTTPS. An http:// address is answered with 403,
 *     and the transaction is not created at all.
 *   - `payment_url` is sometimes returned without a scheme, so it is
 *     normalised before anyone is redirected to it.
 */
import { serviceUnavailable } from "../../lib/errors"
import { apiBase, apiKey, timeoutMs, webhookSecret } from "./config"

/**
 * Cashera's transaction states: `pending` -> `paid` | `failed` | `expired`,
 * plus `refunded` and `chargeback` after the fact. Only `paid` is money.
 */
export type CasheraTransaction = {
	uuid: string
	status: string
	/** Minor units, as sent. */
	amount: number | null
	/** Our order id, echoed back. */
	externalId: string | null
	paymentUrl: string
	expiresAt: string | null
}

type CasheraResult<T> =
	| { ok: true; status: number; data: T }
	| { ok: false; status: number; message: string }

type CasheraRow = {
	uuid?: unknown
	status?: unknown
	amount?: unknown
	external_id?: unknown
	payment_url?: unknown
	expires_at?: unknown
	message?: unknown
	error?: unknown
	errors?: unknown
}

function text(value: unknown): string {
	if (typeof value === "string") return value.trim()
	if (typeof value === "number" && Number.isFinite(value)) return String(value)
	return ""
}

/** Cashera answers errors as `{ message }`, sometimes with `errors` detail. */
function errorText(body: CasheraRow | null, fallback: string): string {
	if (!body) return fallback
	const direct = text(body.message) || text(body.error)
	if (direct) return direct
	if (body.errors && typeof body.errors === "object") {
		const parts: string[] = []
		for (const value of Object.values(body.errors as Record<string, unknown>)) {
			if (typeof value === "string") parts.push(value)
			else if (Array.isArray(value)) parts.push(...value.filter((item): item is string => typeof item === "string"))
		}
		if (parts.length) return parts.join("; ")
	}
	return fallback
}

async function casheraRequest<T extends CasheraRow>(
	path: string,
	init: { method: "GET" | "POST"; body?: unknown },
): Promise<CasheraResult<T>> {
	const key = apiKey()
	if (!key) throw serviceUnavailable("Cashera is not configured")

	let response: Response
	try {
		response = await fetch(apiBase() + path, {
			method: init.method,
			headers: {
				// !! SECRET !! Server-side only.
				"X-Api-Key": key,
				accept: "application/json",
				...(init.body === undefined ? {} : { "content-type": "application/json" }),
			},
			...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
			signal: AbortSignal.timeout(timeoutMs()),
		})
	} catch {
		throw serviceUnavailable("Payment gateway did not respond")
	}

	const payload = (await response.json().catch(() => null)) as T | null
	if (!response.ok) {
		return {
			ok: false,
			status: response.status,
			message: errorText(payload, "Payment gateway error " + response.status),
		}
	}
	if (!payload) return { ok: false, status: response.status, message: "Payment gateway returned an empty body" }
	return { ok: true, status: response.status, data: payload }
}

/** A payment link with the scheme restored, or "" when there is none. */
function paymentLink(value: unknown): string {
	const raw = text(value)
	if (!raw) return ""
	if (/^https?:\/\//i.test(raw)) return raw
	return "https://" + raw.replace(/^\/+/, "")
}

export function toTransaction(row: CasheraRow | null): CasheraTransaction | null {
	if (!row) return null
	const uuid = text(row.uuid)
	if (!uuid) return null
	return {
		uuid,
		status: text(row.status).toLowerCase(),
		amount: typeof row.amount === "number" && Number.isFinite(row.amount) ? row.amount : null,
		externalId: text(row.external_id) || null,
		paymentUrl: paymentLink(row.payment_url),
		expiresAt: text(row.expires_at) || null,
	}
}

export type CreateCasheraTransactionInput = {
	/** Our order id. Travels as `external_id` and comes back on the webhook. */
	orderId: string
	/** Minor units (kopecks). */
	amountMinor: number
	description: string
	/** Empty lets the payer choose on Cashera's own form. */
	paymentMethod?: string
	/** Must be HTTPS or Cashera refuses the whole transaction with 403. */
	callbackUrl?: string
	successUrl?: string
	failUrl?: string
	metadata?: Record<string, unknown>
}

/** POST /integration/transactions - creates the payment and its hosted page. */
export async function createCasheraTransaction(
	input: CreateCasheraTransactionInput,
): Promise<CasheraTransaction> {
	if (!Number.isInteger(input.amountMinor) || input.amountMinor < 1) {
		throw serviceUnavailable("Amount must be whole kopecks")
	}

	// http:// is not merely ignored here: it is a 403 on create.
	const callbackUrl = input.callbackUrl && /^https:\/\//i.test(input.callbackUrl) ? input.callbackUrl : ""

	const result = await casheraRequest<CasheraRow>("/integration/transactions", {
		method: "POST",
		body: {
			amount: input.amountMinor,
			currency: "RUB",
			external_id: input.orderId,
			description: input.description.slice(0, 255),
			...(input.paymentMethod ? { payment_method: input.paymentMethod } : {}),
			...(callbackUrl ? { callback_url: callbackUrl } : {}),
			...(input.successUrl ? { success_url: input.successUrl } : {}),
			...(input.failUrl ? { fail_url: input.failUrl } : {}),
			...(input.metadata ? { metadata: input.metadata } : {}),
		},
	})

	if (!result.ok) throw serviceUnavailable(result.message)
	const transaction = toTransaction(result.data)
	if (!transaction?.paymentUrl) throw serviceUnavailable("Payment gateway returned no payment link")
	return transaction
}

/** GET /integration/transactions/{uuid} - the authority on what happened. */
export async function getCasheraTransaction(uuid: string): Promise<CasheraTransaction | null> {
	const result = await casheraRequest<CasheraRow>("/integration/transactions/" + encodeURIComponent(uuid), {
		method: "GET",
	})
	return result.ok ? toTransaction(result.data) : null
}

function headerText(headers: Record<string, unknown>, name: string): string {
	const raw = headers[name]
	if (typeof raw === "string") return raw.trim()
	if (Array.isArray(raw) && typeof raw[0] === "string") return raw[0].trim()
	return ""
}

/** Same length, then every byte - no early exit on the first difference. */
function sameSecret(expected: string, given: string): boolean {
	if (!expected || expected.length !== given.length) return false
	let diff = 0
	for (let i = 0; i < expected.length; i += 1) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i)
	return diff === 0
}

/**
 * Checks a delivery's credentials.
 *
 * Cashera does not sign the body; it repeats the merchant's own credentials in
 * `X-Api-Key` and `X-Secret` on every call. Both are compared in constant time
 * and neither is ever logged. Without `CASHERA_WEBHOOK_SECRET` (the `sk_` from
 * the dashboard) nothing can be verified, so nothing is accepted - the
 * alternative would be an open endpoint that grants subscriptions.
 */
export function verifyCasheraCredentials(headers: Record<string, unknown>): boolean {
	const secret = webhookSecret()
	if (!secret) return false
	if (!sameSecret(secret, headerText(headers, "x-secret"))) return false
	const key = apiKey()
	return key ? sameSecret(key, headerText(headers, "x-api-key")) : false
}
