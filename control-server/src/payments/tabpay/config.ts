/**
 * TabPay's own settings.
 *
 * Read straight from the environment rather than through the central config
 * schema: these keys belong to a folder that may be deleted, and a validated
 * schema entry for a gateway that no longer exists is exactly the kind of
 * leftover this refactor is meant to remove.
 *
 * Every value is a function, not a constant, so filling a key in and
 * restarting is enough - nothing is frozen at import time.
 */
import { envInt, envText } from "../env"

/** Folder name, env prefix and webhook path segment. All the same word. */
export const TABPAY_ID = "tabpay"
export const TABPAY_LABEL = "TabPay"
/** TabPay accepts roubles and nothing else. */
export const TABPAY_CURRENCY = "RUB"
/** Smallest payment the gateway accepts: 1 rouble. */
export const TABPAY_MIN_KOPECKS = 100
/** Largest payment the gateway accepts: 100 million roubles. */
export const TABPAY_MAX_KOPECKS = 10_000_000_000
/** Webhook freshness window for the v2 signature scheme, in seconds. */
export const SIGNATURE_WINDOW_SEC = 300

export function apiBase(): string {
	return envText("TABPAY_API_BASE", "https://tabpay.org").replace(/\/+$/, "")
}

/** !! SECRET !! Server-side only: it never reaches a browser. */
export function apiKey(): string {
	return envText("TABPAY_API_KEY")
}

/** !! SECRET !! Signs the webhooks. Without it no delivery is trusted. */
export function webhookSecret(): string {
	return envText("TABPAY_WEBHOOK_SECRET")
}

/**
 * Which shop the key belongs to. Informational: the API identifies the shop by
 * the key, but having the id in env makes a mismatch obvious.
 */
export function shopId(): string {
	return envText("TABPAY_SHOP_ID")
}

/** Pin a single method ("SBP" or "CARD"); empty lets the payer choose. */
export function method(): string {
	const value = envText("TABPAY_METHOD").toUpperCase()
	return value === "SBP" || value === "CARD" ? value : ""
}

export function timeoutMs(): number {
	return envInt("TABPAY_TIMEOUT_MS", 15000, 1000, 60000)
}

/**
 * Holding an API key is what "configured" means here. The webhook secret is
 * checked separately, when a delivery arrives: a shop that can create payments
 * but cannot verify callbacks is misconfigured, not uninstalled, and the
 * difference belongs in the admin panel rather than in a silent refusal.
 */
export function isConfigured(): boolean {
	return apiKey().length > 0
}
