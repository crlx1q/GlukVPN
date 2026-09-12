/**
 * Which market a visitor belongs to: country, currency and language.
 *
 * Where the visitor is, in order of trust: the Cloudflare edge header, a GeoIP
 * lookup of the connecting address (`resolveMarketByIp`), the time zone the
 * client reports, and only then the region subtag of Accept-Language. That
 * order is deliberate: Cloudflare fronts the site but not the API, so
 * CF-IPCountry is missing on every direct API call, and a Russian-language
 * Windows in Almaty sends `ru-RU`, which says what the interface is translated
 * into and not where the device is. Believing that subtag is exactly how a
 * visitor in Kazakhstan ended up being quoted in roubles.
 *
 * Currency follows country, not language: a Russian-speaking visitor in
 * Kazakhstan pays in tenge, and someone reading the English site from Russia
 * still pays in roubles. The single exception is a country we hold no currency
 * for whose visitor switched the language by hand - somebody on a US address
 * reading the Russian site is quoted in roubles rather than dollars.
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
 * Country from the Cloudflare edge header, or "" when it says nothing usable.
 *
 * "XX" is "could not place this client" and "T1" is Tor. Both are worse than no
 * answer: they would pin such a visitor to a market instead of letting a
 * weaker signal, or the default, apply.
 */
function edgeCountry(request: FastifyRequest): string {
	const edge = headerValue(request, "cf-ipcountry").toUpperCase()
	return /^[A-Z]{2}$/.test(edge) && edge !== "XX" && edge !== "T1" ? edge : ""
}

/**
 * Region subtag of the *first* Accept-Language tag: "ru-KZ,ru;q=0.9" -> "KZ".
 *
 * The weakest signal we have and the one that used to misplace people: a
 * Russian-language Windows or Android in Almaty reports `ru-RU`, which is a
 * statement about the interface rather than about the country, so it is only
 * consulted once the edge, GeoIP and the time zone have all stayed silent.
 * Later tags are ignored on purpose - "ru,en-US;q=0.9" is a Russian speaker
 * who would also accept English, not somebody in the United States.
 */
function languageCountry(request: FastifyRequest): string {
	const firstTag = headerValue(request, "accept-language").split(",")[0] ?? ""
	const region = /[-_]([A-Za-z]{2})(?:$|[-_;])/.exec(firstTag)
	return region && region[1] ? region[1].toUpperCase() : ""
}

/**
 * The language the visitor picked by hand: `X-Client-Lang` or `?lang=`.
 *
 * Only a click on the language switch reaches this - the site never sends it
 * for a language it guessed itself. It overrides the language of the market,
 * and for a country we hold no currency for it also decides the currency: an
 * emigrant on a US address who switched to Russian is quoted in roubles.
 */
function clientLocaleChoice(request: FastifyRequest): "ru" | "en" | "" {
	const header = headerValue(request, "x-client-lang").toLowerCase()
	const query = request.query as { lang?: unknown } | undefined
	const asked =
		header || (typeof query?.lang === "string" ? query.lang.trim().toLowerCase() : "")
	return asked === "ru" || asked === "en" ? asked : ""
}

/** The connecting address, as close to the real client as the proxies allow. */
function clientAddress(request: FastifyRequest): string {
	const forwarded = (headerValue(request, "x-forwarded-for").split(",")[0] ?? "").trim()
	const raw = forwarded || headerValue(request, "x-real-ip") || request.ip || ""
	return raw.replace(/^::ffff:/i, "").trim()
}

/**
 * GeoIP answers, remembered for six hours.
 *
 * The provider is rate limited and every page of a session asks the same
 * question about the same address, so repeating the lookup would be both slow
 * and wasteful. Empty answers are cached too: when GeoIP is switched off or
 * down, the next request should fall through to the time zone at once instead
 * of waiting for another timeout.
 */
const GEOIP_TTL_MS = 6 * 60 * 60 * 1000
const GEOIP_CACHE_MAX = 2000
const geoipCache = new Map<string, { country: string; at: number }>()

/**
 * Country for an IP address, or "" when GeoIP is disabled, the address is
 * private, or the provider says nothing usable. Never throws: a market decided
 * by the time zone is far better than a page that cannot price itself.
 */
async function countryForAddress(ip: string): Promise<string> {
	if (!ip) return ""
	const cached = geoipCache.get(ip)
	if (cached && Date.now() - cached.at < GEOIP_TTL_MS) return cached.country

	let country = ""
	try {
		// Imported lazily: services/geo pulls in Prisma and the config, which a
		// unit test of the pricing rules has no business loading.
		const { lookupOrigin } = await import("./geo")
		const origin = await lookupOrigin(ip)
		const code = (origin?.countryCode ?? "").toUpperCase()
		if (/^[A-Z]{2}$/.test(code)) country = code
	} catch {
		country = ""
	}

	if (geoipCache.size >= GEOIP_CACHE_MAX) geoipCache.clear()
	geoipCache.set(ip, { country, at: Date.now() })
	return country
}

/**
 * Two-letter country code, uppercased, or "" when nothing usable was sent.
 *
 * Synchronous, so no GeoIP: the edge header, then the zone the client reports,
 * then the region of Accept-Language. The zone outranks the language subtag
 * because a device in Almaty is far more likely to lie about `ru-RU` than
 * about `Asia/Almaty`. `resolveMarketByIp` is the variant that also asks
 * GeoIP; this one stays cheap for callers that only need a guess.
 */
export function resolveCountry(request: FastifyRequest): string {
	return (
		edgeCountry(request) ||
		countryForTimeZone(clientTimeZone(request)) ||
		languageCountry(request)
	)
}

export type Market = {
	/** "" when the country could not be determined. */
	country: string
	currency: SupportedCurrency
	/** UI language to open with: "ru" or "en". */
	locale: string
	/** Where the country came from, for debugging a wrong price. */
	source: "cloudflare" | "geoip" | "timezone" | "language" | "default"
}

/** Currency and language for a country, honouring a hand-picked language. */
function marketFor(country: string, chosen: "ru" | "en" | "", source: Market["source"]): Market {
	return {
		country,
		// A country we price -> its currency. Anything else is quoted in dollars
		// unless the visitor asked for Russian by hand: tenge for an unknown
		// country would be a price most of the world cannot pay, but somebody
		// who chose the Russian site can pay in roubles.
		currency: COUNTRY_CURRENCY[country] ?? (chosen === "ru" ? "RUB" : DEFAULT_CURRENCY),
		locale: chosen || (RUSSIAN_SPEAKING.has(country) ? "ru" : DEFAULT_LOCALE),
		source,
	}
}

/** Country, currency and language for one request, without GeoIP. Never throws. */
export function resolveMarket(request: FastifyRequest): Market {
	const chosen = clientLocaleChoice(request)
	const edge = edgeCountry(request)
	if (edge) return marketFor(edge, chosen, "cloudflare")
	const zone = countryForTimeZone(clientTimeZone(request))
	if (zone) return marketFor(zone, chosen, "timezone")
	const language = languageCountry(request)
	if (language) return marketFor(language, chosen, "language")
	return marketFor("", chosen, "default")
}

/**
 * The same answer, but allowed to ask GeoIP about the connecting address.
 *
 * This is what the billing routes use. api.gluk.tech is reached directly, so
 * CF-IPCountry is absent there and the address is the only signal that a VPN
 * cannot fake by hand - the time zone and the language are both self-reported.
 * Requires GEOIP_ENABLED; without it the answer is the synchronous one.
 */
export async function resolveMarketByIp(request: FastifyRequest): Promise<Market> {
	const chosen = clientLocaleChoice(request)
	const edge = edgeCountry(request)
	if (edge) return marketFor(edge, chosen, "cloudflare")
	const byIp = await countryForAddress(clientAddress(request))
	if (byIp) return marketFor(byIp, chosen, "geoip")
	return resolveMarket(request)
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
