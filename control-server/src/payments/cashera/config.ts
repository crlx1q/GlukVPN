/**
 * Cashera's own settings.
 *
 * Read straight from the environment, like every gateway folder: these keys
 * belong to this directory and disappear with it.
 *
 * Two keys, and the difference matters:
 *
 *   - `pk_…` is the API key. It authenticates *our* calls to Cashera and is
 *     also echoed back on every webhook.
 *   - `sk_…` is the webhook secret. It only ever arrives, in `X-Secret`, and is
 *     what proves a delivery is genuine. It is issued in the merchant
 *     dashboard, not in the API response.
 *
 * Both are server-side secrets and neither is ever sent to a browser.
 */
import { envInt, envText } from "../env"

/** Folder name, env prefix and webhook path segment. All the same word. */
export const CASHERA_ID = "cashera"
export const CASHERA_LABEL = "Cashera"
/** The only currency the API accepts. */
export const CASHERA_CURRENCY = "RUB"

/**
 * The card rail has a 100 rouble floor; SBP and crypto start at one kopeck.
 *
 * The default is therefore the low one, so a 1 ₽ trial can go through - but a
 * payer who picks "card" on the universal form for a 1 ₽ order will be
 * refused by Cashera, which is why CASHERA_PAYMENT_METHOD=sbp is the sensible
 * pairing for trials. CASHERA_MIN_MINOR raises the floor when a shop only
 * wants cards.
 */
export const CASHERA_CARD_MIN_MINOR = 10000

export function apiBase(): string {
	return envText("CASHERA_API_BASE", "https://api.cashera.cash/api/v1").replace(/\/+$/, "")
}

/** !! SECRET !! The `pk_…` key, sent as `X-Api-Key`. */
export function apiKey(): string {
	return envText("CASHERA_API_KEY")
}

/** !! SECRET !! The `sk_…` webhook secret, expected in `X-Secret`. */
export function webhookSecret(): string {
	return envText("CASHERA_WEBHOOK_SECRET")
}

/** The merchant UUID. Informational: the key identifies the merchant. */
export function merchantId(): string {
	return envText("CASHERA_MERCHANT_ID")
}

/**
 * The rails the API recognises. Anything else is a rejected transaction, so
 * this list is the filter for both .env and a payer's own choice.
 */
export const CASHERA_KNOWN_METHODS: readonly string[] = ["sbp", "card", "mastercard", "crypto", "cryptobot"]

/**
 * Pin one rail, or leave empty to let the payer choose on Cashera's form.
 * Unknown values are ignored rather than passed through, because an
 * unrecognised `payment_method` is a rejected transaction.
 */
export function paymentMethod(): string {
	const value = envText("CASHERA_PAYMENT_METHOD").toLowerCase()
	return CASHERA_KNOWN_METHODS.includes(value) ? value : ""
}

/** The smallest charge this shop will send, in kopecks. */
export function minimumMinor(): number {
	const method = paymentMethod()
	const floor = method === "card" || method === "mastercard" ? CASHERA_CARD_MIN_MINOR : 1
	return envInt("CASHERA_MIN_MINOR", floor, 1, 100_000_000)
}

export function timeoutMs(): number {
	return envInt("CASHERA_TIMEOUT_MS", 15000, 1000, 60000)
}

/**
 * The API key is what "configured" means: it is the one thing without which
 * no transaction can be created. A missing webhook secret is a separate
 * problem, reported when a delivery arrives and cannot be trusted.
 */
export function isConfigured(): boolean {
	return apiKey().length > 0
}
