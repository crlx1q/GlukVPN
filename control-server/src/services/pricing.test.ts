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
		expect(resolveMarket(request({ "cf-ipcountry": "KG" }))).toMatchObject({
			currency: "USD",
			locale: "ru",
		})
	})

	it("reports where the country came from", () => {
		expect(resolveMarket(request({ "accept-language": "ru-RU" })).source).toBe("language")
		expect(resolveMarket(request({})).source).toBe("default")
		expect(resolveMarket(request({})).currency).toBe(DEFAULT_CURRENCY)
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
