/**
 * Where a payer comes back to, and where a gateway writes to.
 *
 * Two different hosts, and the difference is not cosmetic:
 *
 *   - the *return* pages are static and live on app.gluk.tech (GitHub Pages),
 *     which keeps working in Russia on a day when the API's own domain does
 *     not. Nothing is granted there: the page only tells the payer what
 *     happened and asks the API about the order.
 *   - the *webhook* has to reach this server, so it is built from
 *     PUBLIC_API_URL. Pointing a gateway's callback at the static site would
 *     produce payments that never become subscriptions.
 */
import { config } from "../config"

function withoutTrailingSlash(url: string): string {
	return url.replace(/\/+$/, "")
}

/** The public app, with `path` appended. Falls back to the website. */
export function appUrl(path = "/"): string {
	const base = config.BILLING_APP_BASE_URL.trim() || config.SITE_BASE_URL
	return `${withoutTrailingSlash(base)}${path}`
}

export type ReturnUrls = {
	successUrl: string
	failUrl: string
}

/**
 * Where the hosted payment page sends the browser afterwards.
 *
 * A trial returns to /trial/ and an ordinary order to the account page,
 * because those are the two pages that can explain what just happened. The
 * order id travels in the query so the page can poll for the real status
 * instead of believing the redirect.
 *
 * BILLING_SUCCESS_URL / BILLING_CANCEL_URL pin both when an operator wants
 * one fixed landing page.
 */
export function returnUrls(params: { orderId: string; isTrial: boolean }): ReturnUrls {
	const page = params.isTrial ? "/trial/" : "/app/"
	return {
		successUrl: config.BILLING_SUCCESS_URL.trim() || appUrl(`${page}?paid=1&order=${params.orderId}`),
		failUrl: config.BILLING_CANCEL_URL.trim() || appUrl(`${page}?failed=1&order=${params.orderId}`),
	}
}

/**
 * The callback address of one gateway: /api/billing/webhook/<id> on the API
 * host.
 *
 * Gateways that take the address per payment are handed this string; the rest
 * have it typed into their dashboard, and it is the same string either way -
 * which is why it is computed in one place and printed in the docs from here.
 */
export function webhookUrl(providerId: string): string {
	return `${withoutTrailingSlash(config.PUBLIC_API_URL)}/api/billing/webhook/${providerId}`
}
