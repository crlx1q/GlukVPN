import { describe, expect, it } from "vitest"
import type { FastifyRequest } from "fastify"

import {
	DEFAULT_CURRENCY,
	normalizeCurrency,
	resolveCountry,
	resolveMarket,
	resolvePlanPrice,
	type PlanWithPrices,
} from "./pricing"

const request = (headers: Record<string, string>): FastifyRequest =>
	({ headers }) as unknown as FastifyRequest

// Only the fields the pricing code reads. The rest of Plan is irrelevant here
// and filling it in would just make the test harder to read than the code.
const plan = (
	priceMinor: number,
	currency: string,
	prices: Array<[string, number]> = [],
): PlanWithPrices =>
	({
		priceMinor,
		currency,
		prices: prices.map(([code, minor]) => ({ currency: code, priceMinor: minor })),
	}) as unknown as PlanWithPrices

const pro = () => plan(149000, "KZT", [["RUB", 29000], ["USD", 399]])

describe("resolveCountry", () => {
	it("trusts the Cloudflare edge header first", () => {
		expect(resolveCountry(request({ "cf-ipcountry": "kz" }))).toBe("KZ")
	})

	// XX is "could not place this client" and T1 is Tor. Both are worse than no
	// answer: they would pin the visitor to a market instead of the default.
	it("ignores the placeholders Cloudflare sends when it cannot tell", () => {
		expect(resolveCountry(request({ "cf-ipcountry": "XX" }))).toBe("")
		expect(resolveCountry(request({ "cf-ipcountry": "T1" }))).toBe("")
	})

	it("falls back to the region of the first language tag", () => {
		expect(resolveCountry(request({ "accept-language": "ru-KZ,ru;q=0.9,en;q=0.8" }))).toBe("KZ")
	})

	// "ru,en-US;q=0.9" must not be read as the United States: the user asked for
	// Russian first and only listed en-US as an acceptable fallback.
	it("does not take a region from a later language tag", () => {
		expect(resolveCountry(request({ "accept-language": "ru,en-US;q=0.9" }))).toBe("")
	})

	// The API is not behind Cloudflare, so the zone the client reports is
	// usually the only thing left to place a visitor with - and it outranks the
	// language subtag, which says nothing reliable about the country.
	it("falls back to the time zone the client reports", () => {
		expect(resolveCountry(request({ "x-client-timezone": "Asia/Almaty" }))).toBe("KZ")
		expect(resolveCountry(request({ "x-client-timezone": "asia/qyzylorda" }))).toBe("KZ")
		expect(resolveCountry(request({ "x-client-timezone": "Europe/Moscow" }))).toBe("RU")
		expect(resolveCountry(request({ "x-client-timezone": "Europe/Berlin" }))).toBe("")
	})

	// The edge resolves the country from the connecting address, so it wins
	// over everything the client says about itself.
	it("prefers the edge header over the reported zone", () => {
		expect(
			resolveCountry(request({ "cf-ipcountry": "DE", "x-client-timezone": "Asia/Almaty" })),
		).toBe("DE")
	})

	// A Russian-language Windows or Android in Almaty sends "ru-RU": that is the
	// language of the interface, not the country of the device. Reading a
	// country out of it is what quoted a visitor in Kazakhstan in roubles.
	it("does not read the country off a ru-RU interface", () => {
		const headers = { "accept-language": "ru-RU", "x-client-timezone": "Asia/Almaty" }
		expect(resolveCountry(request(headers))).toBe("KZ")
		// Still the last resort: with no zone to go on, the subtag is all there is.
		expect(resolveCountry(request({ "accept-language": "ru-RU" }))).toBe("RU")
	})

	it("reads the zone from the query string too", () => {
		const withQuery = { headers: {}, query: { tz: "Asia/Almaty" } } as unknown as FastifyRequest
		expect(resolveCountry(withQuery)).toBe("KZ")
	})

	it("returns nothing when there is nothing to go on", () => {
		expect(resolveCountry(request({}))).toBe("")
	})
})

describe("resolveMarket", () => {
	it("prices Kazakhstan in tenge and opens in Russian", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "KZ" }))).toMatchObject({
			country: "KZ",
			currency: "KZT",
			locale: "ru",
			source: "cloudflare",
		})
	})

	it("prices Russia in roubles", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "RU" }))).toMatchObject({
			currency: "RUB",
			locale: "ru",
		})
	})

	it("prices everywhere else in dollars, in English", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "US" }))).toMatchObject({
			currency: "USD",
			locale: "en",
		})
		expect(resolveMarket(request({ "cf-ipcountry": "DE" }))).toMatchObject({
			currency: "USD",
			locale: "en",
		})
	})

	// Currency follows the country, language follows the region: a neighbour we
	// hold no currency for still reads Russian but pays in dollars.
	it("separates language from currency", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "UZ" }))).toMatchObject({
			currency: "USD",
			locale: "ru",
		})
	})

	// Belarus and Kyrgyzstan share a payment area with Russia, so they are
	// quoted in a currency they can actually pay in rather than in dollars.
	it("quotes the rouble area in roubles", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "BY" })).currency).toBe("RUB")
		expect(resolveMarket(request({ "cf-ipcountry": "KG" })).currency).toBe("RUB")
	})

	it("reports where the country came from", () => {
		expect(resolveMarket(request({ "accept-language": "ru-RU" })).source).toBe("language")
		expect(resolveMarket(request({ "x-client-timezone": "Asia/Almaty" })).source).toBe(
			"timezone",
		)
		expect(resolveMarket(request({})).source).toBe("default")
	})

	// A visitor we cannot place pays in dollars, never in tenge: the home price
	// is the wrong guess for most of the world. Kazakhstan is recognised by its
	// time zone instead, which is what actually fixed the $1.99 quote.
	it("quotes dollars when the country is unknown", () => {
		expect(resolveMarket(request({})).currency).toBe(DEFAULT_CURRENCY)
		expect(resolveMarket(request({ "accept-language": "ru,en-US;q=0.9" })).currency).toBe(
			DEFAULT_CURRENCY,
		)
		expect(resolveMarket(request({ "cf-ipcountry": "XX" })).currency).toBe(DEFAULT_CURRENCY)
		expect(resolveMarket(request({ "cf-ipcountry": "DE" })).currency).toBe(DEFAULT_CURRENCY)
	})

	// The whole point of the zone fallback: a browser in Almaty that asks for
	// plain "ru" must be quoted 790 ₸, not $1.99.
	it("quotes tenge for a visitor placed by time zone alone", () => {
		expect(
			resolveMarket(
				request({ "accept-language": "ru", "x-client-timezone": "Asia/Almaty" }),
			),
		).toMatchObject({ country: "KZ", currency: "KZT", locale: "ru", source: "timezone" })
	})

	// A language the visitor picked by hand is the one thing allowed to override
	// the market: an emigrant on a US address who switched the site to Russian
	// is quoted in roubles, which is a currency they can actually pay in.
	it("honours a language the visitor picked by hand", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "US", "x-client-lang": "ru" }))).toMatchObject({
			currency: "RUB",
			locale: "ru",
		})
		expect(resolveMarket(request({ "cf-ipcountry": "DE", "x-client-lang": "ru" }))).toMatchObject({
			currency: "RUB",
			locale: "ru",
		})
	})

	// ...but never the currency of a market we do price: Kazakhstan is quoted in
	// tenge whichever language the visitor reads the site in.
	it("keeps the country's own currency when the language changes", () => {
		expect(resolveMarket(request({ "cf-ipcountry": "KZ", "x-client-lang": "en" }))).toMatchObject({
			country: "KZ",
			currency: "KZT",
			locale: "en",
		})
		expect(resolveMarket(request({ "cf-ipcountry": "RU", "x-client-lang": "en" })).currency).toBe(
			"RUB",
		)
	})

	it("reads the chosen language from the query string too", () => {
		const withQuery = { headers: {}, query: { lang: "ru" } } as unknown as FastifyRequest
		expect(resolveMarket(withQuery)).toMatchObject({ country: "", currency: "RUB", locale: "ru" })
	})
})

describe("normalizeCurrency", () => {
	it("accepts the currencies we hold prices in", () => {
		expect(normalizeCurrency("kzt")).toBe("KZT")
		expect(normalizeCurrency(" rub ")).toBe("RUB")
		expect(normalizeCurrency("USD")).toBe("USD")
	})

	it("rejects anything else rather than inventing a price", () => {
		expect(normalizeCurrency("EUR")).toBeNull()
		expect(normalizeCurrency("")).toBeNull()
		expect(normalizeCurrency(undefined)).toBeNull()
	})
})

describe("resolvePlanPrice", () => {
	it("quotes the price for the asked currency", () => {
		expect(resolvePlanPrice(pro(), "RUB")).toEqual({ priceMinor: 29000, currency: "RUB" })
		expect(resolvePlanPrice(pro(), "USD")).toEqual({ priceMinor: 399, currency: "USD" })
	})

	it("uses the plan's own price when that is what was asked for", () => {
		expect(resolvePlanPrice(pro(), "KZT")).toEqual({ priceMinor: 149000, currency: "KZT" })
	})

	// Showing the base price is much better than showing nothing, and far better
	// than showing a zero that reads as "free".
	it("falls back to the base price for an unpriced currency", () => {
		expect(resolvePlanPrice(plan(149000, "KZT"), "USD")).toEqual({
			priceMinor: 149000,
			currency: "KZT",
		})
		expect(resolvePlanPrice(pro(), "EUR")).toEqual({ priceMinor: 149000, currency: "KZT" })
		expect(resolvePlanPrice(pro(), null)).toEqual({ priceMinor: 149000, currency: "KZT" })
	})

	it("keeps a free plan free in every currency", () => {
		expect(resolvePlanPrice(plan(0, "KZT"), "USD")).toEqual({ priceMinor: 0, currency: "USD" })
	})
})
