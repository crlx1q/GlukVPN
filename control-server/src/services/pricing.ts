/**
 * Which market a visitor belongs to: country, currency and language.
 *
 * Cloudflare sits in front of the site and adds CF-IPCountry to every request,
 * which is both cheaper and more accurate than a GeoIP lookup of our own - it
 * is resolved at the edge from the connecting address. When the header is
 * absent (a client talking to the API directly, or a dev checkout) the region
 * subtag of Accept-Language is the next best guess, and after that we fall back
 * to the default market rather than guessing wrongly.
 *
 * Currency follows country, not language: a Russian-speaking visitor in
 * Kazakhstan pays in tenge, and someone reading the English site from Russia
 * still pays in roubles.
 */
import type { FastifyRequest } from "fastify"
import type { Plan, PlanPrice } from "@prisma/client"

/** Currencies we actually hold prices in. Anything else falls back. */
export const SUPPORTED_CURRENCIES = ["KZT", "RUB", "USD"] as const
export type SupportedCurrency = (typeof SUPPORTED_CURRENCIES)[number]

/** What a visitor in a country we have not priced separately pays. */
export const DEFAULT_CURRENCY: SupportedCurrency = "USD"

/**
 * What a visitor we could not place at all pays.
 *
 * This is deliberately not DEFAULT_CURRENCY. CF-IPCountry only exists on
 * requests that actually pass through Cloudflare, and the apps and the site
 * talk to the API on its own host - so "country unknown" is the normal case
 * here, not an exotic one. Kazakh visitors were being quoted $1.99 for Basic
 * because a browser that sends plain "ru" (no region) left the country empty
 * and the default was dollars. price.md is written in tenge, so the home
 * market is the honest fallback: a Kazakh user seeing 790 ₸ is right, and a
 * German user seeing tenge is at least a price we actually charge.
 */
export const HOME_CURRENCY: SupportedCurrency = "KZT"

export const DEFAULT_LOCALE = "en"

// Only the markets we price separately need an entry; everything else is USD
// and English, which is what "US and the rest of the world" means on the
// pricing page. Neighbours that overwhelmingly read Russian get the Russian
// site but still pay in dollars, because we do not hold their currency.
const COUNTRY_CURRENCY: Record<string, SupportedCurrency> = {
	KZ: "KZT",
	RU: "RUB",
}

const RUSSIAN_SPEAKING = new Set([
	"KZ",
	"RU",
	"BY",
	"KG",
	"UZ",
	"TJ",
	"AM",
	"AZ",
	"GE",
	"MD",
	"TM",
])

function headerValue(request: FastifyRequest, name: string): string {
	const raw = request.headers[name]
	if (typeof raw === "string") return raw.trim()
	if (Array.isArray(raw) && typeof raw[0] === "string") return raw[0].trim()
	return ""
}

/**
 * Two-letter country code, uppercased, or "" when nothing usable was sent.
 *
 * Cloudflare uses "XX" for a client it cannot place and "T1" for Tor, both of
 * which are worse than no answer: they would pin such a visitor to a market
 * instead of letting the default apply.
 */
export function resolveCountry(request: FastifyRequest): string {
	const edge = headerValue(request, "cf-ipcountry").toUpperCase()
	if (/^[A-Z]{2}$/.test(edge) && edge !== "XX" && edge !== "T1") return edge

	// "ru-KZ,ru;q=0.9,en;q=0.8" -> KZ. Only the first tag is considered: the
	// rest are fallbacks the browser would accept, not where the user is.
	const language = headerValue(request, "accept-language")
	const firstTag = language.split(",")[0] ?? ""
	const region = /[-_]([A-Za-z]{2})(?:$|[-_;])/.exec(firstTag)
	if (region && region[1]) return region[1].toUpperCase()

	return ""
}

export type Market = {
	/** "" when the country could not be determined. */
	country: string
	currency: SupportedCurrency
	/** UI language to open with: "ru" or "en". */
	locale: string
	/** Where the country came from, for debugging a wrong price. */
	source: "cloudflare" | "language" | "default"
}

/** Country, currency and language for one request. Never throws. */
export function resolveMarket(request: FastifyRequest): Market {
	const edge = headerValue(request, "cf-ipcountry").toUpperCase()
	const country = resolveCountry(request)
	const source: Market["source"] = !country
		? "default"
		: /^[A-Z]{2}$/.test(edge) && edge !== "XX" && edge !== "T1"
			? "cloudflare"
			: "language"

	return {
		country,
		// Known country -> its currency, or dollars for a market we have not
		// priced. Unknown country -> the home market, never dollars by accident.
		currency: COUNTRY_CURRENCY[country] ?? (country ? DEFAULT_CURRENCY : HOME_CURRENCY),
		locale: RUSSIAN_SPEAKING.has(country) ? "ru" : DEFAULT_LOCALE,
		source,
	}
}

/** Normalise anything a client sends as `?currency=` onto a currency we hold. */
export function normalizeCurrency(raw: string | undefined | null): SupportedCurrency | null {
	if (!raw) return null
	const upper = raw.trim().toUpperCase()
	return (SUPPORTED_CURRENCIES as readonly string[]).includes(upper)
		? (upper as SupportedCurrency)
		: null
}

export type PlanWithPrices = Plan & { prices?: PlanPrice[] }

export type ResolvedPrice = { priceMinor: number; currency: string }

/**
 * What this plan costs in `currency`.
 *
 * Falls back to the plan's own price rather than refusing to answer: a market
 * that has not been priced yet should still see a catalogue, and showing the
 * base tenge price is far better than showing nothing or a zero that reads as
 * "free". A free plan is free in every currency, so it short-circuits.
 */
export function resolvePlanPrice(
	plan: PlanWithPrices,
	currency?: string | null,
): ResolvedPrice {
	if (plan.priceMinor === 0) {
		return { priceMinor: 0, currency: currency ?? plan.currency }
	}
	const wanted = normalizeCurrency(currency)
	if (!wanted) return { priceMinor: plan.priceMinor, currency: plan.currency }
	if (wanted === plan.currency.toUpperCase()) {
		return { priceMinor: plan.priceMinor, currency: plan.currency }
	}

	const match = (plan.prices ?? []).find(
		(price) => price.currency.toUpperCase() === wanted,
	)
	return match
		? { priceMinor: match.priceMinor, currency: wanted }
		: { priceMinor: plan.priceMinor, currency: plan.currency }
}
