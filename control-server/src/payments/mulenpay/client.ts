/**
 * The MulenPay REST client and its signature.
 *
 * Speaks MulenPay and nothing else: roubles as a decimal string, statuses as
 * integers, receipts as `items[]`. The translation into our own vocabulary is
 * in `index.ts`.
 *
 * Two details of this API deserve to be stated before the code, because both
 * are easy to get subtly wrong:
 *
 *   - the amount travels as a *string of roubles* ("149.00"), while our ledger
 *     counts kopecks. The same string is hashed into `sign`, so it is built
 *     once and reused - formatting it twice is how a signature ends up valid
 *     for a different number than the one that was sent.
 *   - `sign` is sha1(currency + amount + shopId + secretKey), a plain
 *     concatenation with no separators. It authenticates the request; the
 *     callback, by contrast, carries no signature at all, which is why every
 *     webhook is re-checked against `GET /payments/{id}` before anything is
 *     handed out.
 *   - answers arrive wrapped: the payment itself sits under `data`, while
 *     older answers are flat and a read may put it under `payment`. Every
 *     response is unwrapped before a single field is read out of it.
 */
import { createHash } from "node:crypto"
import { serviceUnavailable } from "../../lib/errors"
import {
	MULENPAY_API_CURRENCY,
	MULENPAY_MIN_KOPECKS,
	apiBase,
	apiKey,
	language,
	paymentMode,
	paymentSubject,
	secretKey,
	shopId,
	timeoutMs,
	vatCode,
} from "./config"

/**
 * MulenPay's payment states, as documented:
 *
 *   0 created, 1 in progress, 2 cancelled, 3 processed (paid),
 *   4 error, 5 / 6 hold (authorised, not captured).
 *
 * Only 3 is money in the account.
 */
export const MULENPAY_STATUS_PAID = 3

export type MulenpayCreatedPayment = {
	/** MulenPay's own payment id, stored on the order as providerRef. */
	id: string
	paymentUrl: string
}

export type MulenpayPaymentState = {
	/** The raw integer status; -1 when the API answered without one. */
	status: number
	amountMinor: number | null
}

/**
 * The callback body. Everything is `unknown`: it arrives from the network and
 * is not signed, so nothing here is trusted until the API confirms it.
 */
export type MulenpayWebhookEvent = {
	id?: unknown
	uuid?: unknown
	amount?: unknown
	currency?: unknown
	payment_status?: unknown
}

type MulenpayError = { error?: unknown; status?: unknown; message?: unknown }

type MulenpayResult<T> =
	| { ok: true; status: number; data: T }
	| { ok: false; status: number; message: string }

/** Kopecks as the API wants them: a decimal string of roubles. */
export function roublesText(amountKopecks: number): string {
	return (amountKopecks / 100).toFixed(2)
}

/**
 * sha1(currency + amount + shopId + secretKey).
 *
 * The three visible parts must be byte-identical to what goes into the body,
 * which is why this takes the already-formatted amount string.
 */
function signature(amountText: string): string {
	const payload = MULENPAY_API_CURRENCY + amountText + shopId() + secretKey()
	return createHash("sha1").update(payload, "utf8").digest("hex")
}

function errorText(body: MulenpayError | null, fallback: string): string {
	if (!body) return fallback
	for (const value of [body.error, body.message]) {
		if (typeof value === "string" && value.trim()) return value.trim()
		if (Array.isArray(value)) {
			const joined = value.filter((item) => typeof item === "string").join("; ")
			if (joined) return joined
		}
	}
	return fallback
}

/**
 * One call to the API.
 *
 * A refusal is returned rather than thrown so the caller can read the reason;
 * only "no answer at all" throws. The key travels as a bearer token -
 * `Authorization: Bearer <key>` - which is what the gateway accepts.
 */
async function mulenpayRequest<T>(
	path: string,
	init: { method: "GET" | "POST"; body?: unknown },
): Promise<MulenpayResult<T>> {
	const key = apiKey()
	if (!key) throw serviceUnavailable("MulenPay is not configured")

	let response: Response
	try {
		response = await fetch(apiBase() + path, {
			method: init.method,
			headers: {
				// !! SECRET !! Server-side only.
				Authorization: "Bearer " + key,
				accept: "application/json",
				...(init.body === undefined ? {} : { "content-type": "application/json" }),
			},
			...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
			signal: AbortSignal.timeout(timeoutMs()),
		})
	} catch {
		throw serviceUnavailable("Payment gateway did not respond")
	}

	const payload = (await response.json().catch(() => null)) as (T & MulenpayError) | null
	if (!response.ok) {
		return {
			ok: false,
			status: response.status,
			message: errorText(payload, "Payment gateway error " + response.status),
		}
	}
	if (!payload) return { ok: false, status: response.status, message: "Payment gateway returned an empty body" }
	return { ok: true, status: response.status, data: payload as T }
}

export type CreateMulenpayPaymentInput = {
	/** Our order id. Travels as `uuid` and comes back in the callback. */
	orderId: string
	amountKopecks: number
	description: string
	/** The buyer's e-mail, for the fiscal receipt. A string, not an object. */
	email?: string
	/** Shown on the payment page as the shop the payer came from. */
	websiteUrl?: string
}

/** A number or a numeric string, as an id. */
function idText(value: unknown): string {
	if (typeof value === "string") return value.trim()
	if (typeof value === "number" && Number.isFinite(value)) return String(value)
	return ""
}

/** A payment link with the scheme restored, or "" when there is none. */
function paymentLink(value: unknown): string {
	const raw = typeof value === "string" ? value.trim() : ""
	if (!raw) return ""
	if (/^https?:\/\//i.test(raw)) return raw
	return "https://" + raw.replace(/^\/+/, "")
}

/** A plain object out of an untyped payload, or null when it is not one. */
function record(value: unknown): Record<string, unknown> | null {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return null
	return value as Record<string, unknown>
}

/** The created payment: under `data` in the current API, flat in older answers. */
function createdBody(payload: unknown): Record<string, unknown> {
	const body = record(payload)
	if (!body) return {}
	return record(body.data) ?? body
}

/**
 * The payment object of a read: `data`, `payment`, or the body itself.
 *
 * Whichever of the three actually carries a `status` wins. When none of them
 * does, the answer said nothing about this payment, and the caller is told so
 * with null rather than with a status invented here.
 */
function paymentBody(payload: unknown): Record<string, unknown> | null {
	const body = record(payload)
	if (!body) return null
	for (const candidate of [record(body.data), record(body.payment), body]) {
		if (candidate && candidate.status !== undefined && candidate.status !== null) return candidate
	}
	return null
}

/** Roubles ("149.00" or 149) as whole kopecks. */
export function kopecksFrom(value: unknown): number | null {
	const amount = typeof value === "number" ? value : Number.parseFloat(String(value ?? "").replace(",", "."))
	if (!Number.isFinite(amount)) return null
	return Math.round(amount * 100)
}

/**
 * POST /payments.
 *
 * `items[]` is mandatory even for a single subscription: MulenPay issues the
 * 54-FZ receipt, and a receipt needs a line with a VAT code, a payment subject
 * and a payment mode. One line, priced in roubles, quantity 1 - and its price
 * has to equal the total, or the receipt does not add up.
 */
export async function createMulenpayPayment(input: CreateMulenpayPaymentInput): Promise<MulenpayCreatedPayment> {
	if (!Number.isInteger(input.amountKopecks)) throw serviceUnavailable("Amount must be whole kopecks")
	if (input.amountKopecks < MULENPAY_MIN_KOPECKS) throw serviceUnavailable("Amount is below the gateway minimum")

	const shop = Number.parseInt(shopId(), 10)
	if (!Number.isFinite(shop)) throw serviceUnavailable("MulenPay shop id is not configured")

	// One string, used for the body, the receipt line and the signature.
	const amountText = roublesText(input.amountKopecks)
	const description = input.description.slice(0, 255)

	const result = await mulenpayRequest<Record<string, unknown>>("/payments", {
		method: "POST",
		body: {
			currency: MULENPAY_API_CURRENCY,
			amount: amountText,
			uuid: input.orderId,
			shop_id: shop,
			description,
			sign: signature(amountText),
			language: language(),
			// No recurring billing: every renewal is a fresh order.
			subscribe: null,
			...(input.websiteUrl ? { website_url: input.websiteUrl } : {}),
			// The API takes the client as a bare e-mail string.
			...(input.email ? { client: input.email } : {}),
			items: [
				{
					description,
					quantity: 1,
					price: Number(amountText),
					vat_code: vatCode(),
					payment_subject: paymentSubject(),
					payment_mode: paymentMode(),
				},
			],
		},
	})

	if (!result.ok) throw serviceUnavailable(result.message)
	const data = createdBody(result.data)
	const paymentUrl = paymentLink(data.payment_url ?? data.paymentUrl)
	if (!paymentUrl) throw serviceUnavailable("Payment gateway returned no payment link")
	const paymentId = idText(data.id)
	return { id: paymentId, paymentUrl }
}

/**
 * GET /payments/{id} -> `{ success, data: { status, amount } }`.
 *
 * This is the authority on whether a payment happened. The callback only
 * prompts the question; this answers it.
 */
export async function getMulenpayPayment(id: string): Promise<MulenpayPaymentState | null> {
	const result = await mulenpayRequest<Record<string, unknown>>("/payments/" + encodeURIComponent(id), {
		method: "GET",
	})
	if (!result.ok) return null
	const row = paymentBody(result.data)
	if (!row) return null
	const status = typeof row.status === "number" ? row.status : Number.parseInt(String(row.status ?? ""), 10)
	return {
		status: Number.isFinite(status) ? status : -1,
		amountMinor: kopecksFrom(row.amount),
	}
}
