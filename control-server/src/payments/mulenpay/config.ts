/**
 * MulenPay's own settings.
 *
 * Read straight from the environment, like every gateway folder: the keys
 * belong to this directory and disappear with it.
 *
 * The fiscal fields are here rather than hard-coded because they are a
 * business decision, not a protocol detail: MulenPay issues a receipt for
 * every payment (54-FZ), and "which VAT rate, what kind of subject" is the
 * kind of thing an accountant changes without touching code.
 */
import { envInt, envText } from "../env"

/** Folder name, env prefix and webhook path segment. All the same word. */
export const MULENPAY_ID = "mulenpay"
export const MULENPAY_LABEL = "MulenPay"
/** What we settle in. The API spells it lowercase; the ledger does not. */
export const MULENPAY_CURRENCY = "RUB"
export const MULENPAY_API_CURRENCY = "rub"
/**
 * One rouble, in kopecks.
 *
 * The API takes the amount as a decimal string of roubles, so anything under a
 * rouble is a rounding accident waiting to happen - and 1 ₽ is exactly what the
 * trial charges.
 */
export const MULENPAY_MIN_KOPECKS = 100

/**
 * The version is part of the base URL, so a new API generation is an .env
 * edit. The default is the one this code was written against.
 */
export function apiBase(): string {
	return envText("MULENPAY_API_BASE", "https://api.mulenpay.com/api/v3").replace(/\/+$/, "")
}

/** !! SECRET !! Sent as the `Authorization` header. */
export function apiKey(): string {
	return envText("MULENPAY_API_KEY")
}

/** !! SECRET !! Only ever hashed into `sign`, never transmitted. */
export function secretKey(): string {
	return envText("MULENPAY_SECRET_KEY")
}

/** The shop id from the dashboard. Part of the signature, so it must match. */
export function shopId(): string {
	return envText("MULENPAY_SHOP_ID")
}

/**
 * An optional secret added to the callback URL as `?token=`.
 *
 * MulenPay's callback carries no signature of its own, so this is the only
 * thing that makes the URL hard to guess. It is a lock on the letterbox, not
 * proof of the sender: the status is re-read from the API before anything is
 * granted either way (see `confirmWebhookByStatus`).
 */
export function webhookToken(): string {
	return envText("MULENPAY_WEBHOOK_TOKEN")
}

/** Language of the hosted payment form. */
export function language(): string {
	return envText("MULENPAY_LANGUAGE", "ru")
}

/** 0 = no VAT, which is what a subscription sold without VAT needs. */
export function vatCode(): number {
	return envInt("MULENPAY_VAT_CODE", 0, 0, 7)
}

/** 4 = Услуга: a VPN subscription is a service, not goods. */
export function paymentSubject(): number {
	return envInt("MULENPAY_PAYMENT_SUBJECT", 4, 1, 26)
}

/** 4 = Полный расчёт: paid in full, delivered immediately. */
export function paymentMode(): number {
	return envInt("MULENPAY_PAYMENT_MODE", 4, 1, 7)
}

export function timeoutMs(): number {
	return envInt("MULENPAY_TIMEOUT_MS", 15000, 1000, 60000)
}

/**
 * All three are needed before a payment can be created: the key authenticates
 * the call, the shop id and the secret are what the signature is made of.
 */
export function isConfigured(): boolean {
	return apiKey().length > 0 && secretKey().length > 0 && /^\d+$/.test(shopId())
}
