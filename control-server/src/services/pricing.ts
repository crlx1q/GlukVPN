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

export const DEFAULT_LOCALE = "en"

// Only the markets we price separately need an entry; everything else is USD
// and English, which is what "US and the rest of the world" means on the
// pricing page.
//
// Belarus and Kyrgyzstan are quoted in roubles instead of dollars: they share
// a payment area with Russia, so a rouble price is one they can actually pay.
// The other neighbours still open the Russian site (see RUSSIAN_SPEAKING) but
// pay in dollars, because we hold no catalogue row in their currency.
const COUNTRY_CURRENCY: Record<string, SupportedCurrency> = {
	KZ: "KZT",
	RU: "RUB",
	BY: "RUB",
	KG: "RUB",
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
 * IANA time zone -> country, for the markets where the price differs.
 *
 * Deliberately not a complete zone database: the job is to tell a visitor in
 * Almaty from one in Frankfurt, so only the zones of the countries we price
 * separately and their neighbours are listed. Anything unlisted stays unknown
 * and is quoted in dollars.
 */
const TIMEZONE_COUNTRY: Record<string, string> = {
	"Asia/Almaty": "KZ",
	"Asia/Aqtau": "KZ",
	"Asia/Aqtobe": "KZ",
	"Asia/Atyrau": "KZ",
	"Asia/Oral": "KZ",
	"Asia/Qostanay": "KZ",
	"Asia/Qyzylorda": "KZ",
	// Legacy aliases still sent by older Android and Windows builds.
	"Asia/Alma-Ata": "KZ",
	"Asia/Kashgar": "KZ",
	"Europe/Moscow": "RU",
	"Europe/Kaliningrad": "RU",
	"Europe/Samara": "RU",
	"Europe/Saratov": "RU",
	"Europe/Astrakhan": "RU",
	"Europe/Volgograd": "RU",
	"Europe/Kirov": "RU",
	"Europe/Ulyanovsk": "RU",
	"Asia/Yekaterinburg": "RU",
	"Asia/Omsk": "RU",
	"Asia/Novosibirsk": "RU",
	"Asia/Barnaul": "RU",
	"Asia/Tomsk": "RU",
	"Asia/Novokuznetsk": "RU",
	"Asia/Krasnoyarsk": "RU",
	"Asia/Irkutsk": "RU",
	"Asia/Chita": "RU",
	"Asia/Yakutsk": "RU",
	"Asia/Khandyga": "RU",
	"Asia/Vladivostok": "RU",
	"Asia/Ust-Nera": "RU",
	"Asia/Magadan": "RU",
	"Asia/Sakhalin": "RU",
	"Asia/Srednekolymsk": "RU",
	"Asia/Kamchatka": "RU",
	"Asia/Anadyr": "RU",
	"Europe/Minsk": "BY",
	"Asia/Bishkek": "KG",
	"Asia/Tashkent": "UZ",
	"Asia/Samarkand": "UZ",
	"Asia/Dushanbe": "TJ",
	"Asia/Ashgabat": "TM",
	"Asia/Baku": "AZ",
	"Asia/Yerevan": "AM",
	"Asia/Tbilisi": "GE",
	"Europe/Kyiv": "UA",
	"Europe/Kiev": "UA",
	"Europe/Chisinau": "MD",
}

/** The IANA zone the client says it is in: `X-Client-Timezone` or `?tz=`. */
function clientTimeZone(request: FastifyRequest): string {
	const header = headerValue(request, "x-client-timezone")
	if (header) return header.slice(0, 64)
	const query = request.query as { tz?: unknown } | undefined
	return typeof query?.tz === "string" ? query.tz.trim().slice(0, 64) : ""
}

/** Country for an IANA zone name, case-insensitively. "" when unlisted. */
function countryForTimeZone(zone: string): string {
	const name = zone.trim()
	if (!name) return ""
	const exact = TIMEZONE_COUNTRY[name]
	if (exact) return exact
	const lower = name.toLowerCase()
	for (const [key, country] of Object.entries(TIMEZONE_COUNTRY)) {
		if (key.toLowerCase() === lower) return country
	}
	return ""
}

/**
 * Two-letter country code, uppercased, or "" when nothing usable was sent.
 *
 * Tried in order: the Cloudflare edge header, the region of the first
 * Accept-Language tag, then the client's own time zone. The last one is a
 * self-reported hint, so it is only consulted when both better sources are
 * silent - but it is the one that actually works here: Cloudflare fronts the
 * site, not the API, so CF-IPCountry is absent on every direct API call, and a
 * browser that asks for plain "ru" carries no region either. That combination
 * is exactly how a visitor in Kazakhstan ended up being quoted $1.99.
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

	return countryForTimeZone(clientTimeZone(request))
}

export type Market = {
	/** "" when the country could not be determined. */
	country: string
	currency: SupportedCurrency
	/** UI language to open with: "ru" or "en". */
	locale: string
	/** Where the country came from, for debugging a wrong price. */
	source: "cloudflare" | "language" | "timezone" | "default"
}

/** Country, currency and language for one request. Never throws. */
export function resolveMarket(request: FastifyRequest): Market {
	const edge = headerValue(request, "cf-ipcountry").toUpperCase()
	const edgeKnown = /^[A-Z]{2}$/.test(edge) && edge !== "XX" && edge !== "T1"
	const firstTag = headerValue(request, "accept-language").split(",")[0] ?? ""
	const languageKnown = /[-_]([A-Za-z]{2})(?:$|[-_;])/.test(firstTag)
	const country = resolveCountry(request)
	const source: Market["source"] = !country
		? "default"
		: edgeKnown
			? "cloudflare"
			: languageKnown
				? "language"
				: "timezone"

	return {
		country,
		// A country we price -> its currency. Anything else, including a visitor
		// we could not place at all, is quoted in dollars: tenge for an unknown
		// country would be a price most of the world cannot pay.
		currency: COUNTRY_CURRENCY[country] ?? DEFAULT_CURRENCY,
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
