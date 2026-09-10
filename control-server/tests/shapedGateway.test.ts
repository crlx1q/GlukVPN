import { describe, expect, it } from "vitest"

import { parseShapedGatewayPorts, shapedGatewayPort } from "../src/services/sessions"

// The speed cap used to be a promise the desktop client was trusted to keep,
// and it did not: a 30 Mbit/s account measured ~300. The cap is now a port -
// one shaped listener per sold speed on the node - so what is left for the
// control plane are two decisions, and these tests pin both: what the
// operator's VLESS_SHAPED_PORTS means, and which port a given cap is sent to.
describe("parseShapedGatewayPorts", () => {
	it("reads the configured pairs, slowest first", () => {
		expect(parseShapedGatewayPorts("100=2083,30=2053")).toEqual([
			{ mbps: 30, port: 2053 },
			{ mbps: 100, port: 2083 },
		])
	})

	it("survives the spacing a hand-edited .env actually has", () => {
		expect(parseShapedGatewayPorts(" 30 = 2053 , , 100=2083, ")).toEqual([
			{ mbps: 30, port: 2053 },
			{ mbps: 100, port: 2083 },
		])
	})

	it("reads an unset value as 'no shaped listeners'", () => {
		expect(parseShapedGatewayPorts("")).toEqual([])
		expect(parseShapedGatewayPorts("   ")).toEqual([])
	})

	it("drops a malformed entry instead of guessing a cap", () => {
		// This runs on the connect path for every client: a typo must neither
		// throw nor invent a tier that was never sold.
		expect(parseShapedGatewayPorts("thirty=2053")).toEqual([])
		expect(parseShapedGatewayPorts("30=port")).toEqual([])
		expect(parseShapedGatewayPorts("30")).toEqual([])
		expect(parseShapedGatewayPorts("0=2053")).toEqual([])
		expect(parseShapedGatewayPorts("30=0")).toEqual([])
		expect(parseShapedGatewayPorts("30=70000")).toEqual([])
	})

	it("keeps the first port when one speed is listed twice", () => {
		expect(parseShapedGatewayPorts("30=2053,30=2087")).toEqual([{ mbps: 30, port: 2053 }])
	})
})

describe("shapedGatewayPort", () => {
	const tiers = parseShapedGatewayPorts("30=2053,100=2083,250=2087")

	it("leaves an uncapped plan on the node's own gateway", () => {
		expect(shapedGatewayPort(null, tiers)).toBeNull()
		expect(shapedGatewayPort(undefined, tiers)).toBeNull()
		expect(shapedGatewayPort(0, tiers)).toBeNull()
	})

	it("changes nothing while no listener is configured", () => {
		// Fail open: there is no shaped port to send this client to yet.
		expect(shapedGatewayPort(30, [])).toBeNull()
	})

	it("uses the listener that matches the plan exactly", () => {
		expect(shapedGatewayPort(30, tiers)).toBe(2053)
		expect(shapedGatewayPort(100, tiers)).toBe(2083)
		expect(shapedGatewayPort(250, tiers)).toBe(2087)
	})

	it("rounds a cap between two tiers down, never up", () => {
		// 60 Mbit/s on the 100 listener would give away 40 Mbit/s for free.
		expect(shapedGatewayPort(60, tiers)).toBe(2053)
		expect(shapedGatewayPort(249, tiers)).toBe(2083)
	})

	it("falls back to the slowest listener for a cap below every tier", () => {
		// A little slower than sold is a slow tunnel; unshaped is a refund.
		expect(shapedGatewayPort(10, tiers)).toBe(2053)
	})

	it("keeps a cap above every tier on the fastest listener", () => {
		expect(shapedGatewayPort(1000, tiers)).toBe(2087)
	})
})
