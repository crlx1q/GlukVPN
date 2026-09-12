import { describe, expect, it } from "vitest"

import { parseSpeedTiers, speedGatewaySni } from "../src/services/sessions"

// A speed cap used to be a port: 30 Mbit/s meant "dial 2053". Every port but
// 443 is closed in the Oracle VCN, so the capped client did not connect slowly
// - it did not connect at all. A tier is now a *name*, and nginx `ssl_preread`
// splits the one open port by SNI. That leaves the control plane two
// decisions, and these tests pin both: what VLESS_SPEED_TIERS means, and which
// name a given cap is sent to.
describe("parseSpeedTiers", () => {
	it("reads the sold speeds, slowest first", () => {
		expect(parseSpeedTiers("100,30,500,250,50")).toEqual([30, 50, 100, 250, 500])
	})

	it("survives the spacing a hand-edited .env actually has", () => {
		expect(parseSpeedTiers(" 30 , , 100, ")).toEqual([30, 100])
	})

	it("accepts the agent's speed=port spelling and ignores the port", () => {
		// An operator pasting SHAPING_GATEWAY_SPEEDS in here should get tiers,
		// not nothing. The port is the node's private business now.
		expect(parseSpeedTiers("30=8460,50=8461")).toEqual([30, 50])
	})

	it("reads an unset value as 'no shaped tiers'", () => {
		expect(parseSpeedTiers("")).toEqual([])
		expect(parseSpeedTiers("   ")).toEqual([])
		expect(parseSpeedTiers(",,")).toEqual([])
	})

	it("drops a malformed entry instead of guessing a cap", () => {
		// This runs on the connect path for every client: a typo must neither
		// throw nor invent a tier that was never sold.
		expect(parseSpeedTiers("thirty")).toEqual([])
		expect(parseSpeedTiers("30mbit")).toEqual([])
		expect(parseSpeedTiers("0")).toEqual([])
		expect(parseSpeedTiers("-30")).toEqual([])
		expect(parseSpeedTiers("30=")).toEqual([])
		expect(parseSpeedTiers("=8460")).toEqual([])
		expect(parseSpeedTiers("30,oops,100")).toEqual([30, 100])
	})

	it("keeps one entry when a speed is listed twice", () => {
		expect(parseSpeedTiers("30,30")).toEqual([30])
	})
})

describe("speedGatewaySni", () => {
	const tiers = parseSpeedTiers("30,50,100,250,500")
	const base = "de-01.gluk.tech"

	it("leaves an uncapped plan on the node's own gateway name", () => {
		// null means "send node.gatewayHost", i.e. straight to sing-box.
		expect(speedGatewaySni(null, tiers, base)).toBeNull()
		expect(speedGatewaySni(undefined, tiers, base)).toBeNull()
		expect(speedGatewaySni(0, tiers, base)).toBeNull()
	})

	it("changes nothing while the node has no shaped tiers", () => {
		// Fail open: there is no relay behind speed30.* on this node yet, and a
		// name that routes nowhere is an offline client, not a throttled one.
		expect(speedGatewaySni(30, [], base)).toBeNull()
	})

	it("uses the subdomain of the tier that matches the plan exactly", () => {
		expect(speedGatewaySni(30, tiers, base)).toBe("speed30.de-01.gluk.tech")
		expect(speedGatewaySni(100, tiers, base)).toBe("speed100.de-01.gluk.tech")
		expect(speedGatewaySni(500, tiers, base)).toBe("speed500.de-01.gluk.tech")
	})

	it("rounds a cap between two tiers down, never up", () => {
		// 60 Mbit/s on the 100 relay would give away 40 Mbit/s for free.
		expect(speedGatewaySni(60, tiers, base)).toBe("speed50.de-01.gluk.tech")
		expect(speedGatewaySni(249, tiers, base)).toBe("speed100.de-01.gluk.tech")
	})

	it("falls back to the slowest tier for a cap below every tier", () => {
		// A little slower than sold is a slow tunnel; unshaped is a refund.
		expect(speedGatewaySni(10, tiers, base)).toBe("speed30.de-01.gluk.tech")
	})

	it("keeps a cap above every tier on the fastest tier", () => {
		expect(speedGatewaySni(1000, tiers, base)).toBe("speed500.de-01.gluk.tech")
	})

	it("normalises the base name the way TLS will see it", () => {
		expect(speedGatewaySni(30, tiers, " DE-01.Gluk.Tech. ")).toBe(
			"speed30.de-01.gluk.tech",
		)
	})

	it("refuses a base name that cannot carry a label", () => {
		// Prefixing a bare IP or a dotless name produces a host that resolves
		// nowhere; the cap is not worth taking the client offline for.
		expect(speedGatewaySni(30, tiers, "138.2.186.223")).toBeNull()
		expect(speedGatewaySni(30, tiers, "localhost")).toBeNull()
		expect(speedGatewaySni(30, tiers, "")).toBeNull()
		expect(speedGatewaySni(30, tiers, "de-01.gluk.tech:443")).toBeNull()
		expect(speedGatewaySni(30, tiers, "de-01 .gluk.tech")).toBeNull()
		expect(speedGatewaySni(30, tiers, "[2a01:4f8::1]")).toBeNull()
	})

	it("honours a custom label prefix, and refuses one that is not a label", () => {
		// The prefix has to match what the nginx map and the certificate SANs
		// were generated with.
		expect(speedGatewaySni(30, tiers, base, "tier")).toBe("tier30.de-01.gluk.tech")
		expect(speedGatewaySni(30, tiers, base, "")).toBe("speed30.de-01.gluk.tech")
		expect(speedGatewaySni(30, tiers, base, "speed_")).toBeNull()
		expect(speedGatewaySni(30, tiers, base, "sp eed")).toBeNull()
	})

	it("builds a name one label deep, so one wildcard certificate covers it", () => {
		// *.de-01.gluk.tech or an --expand cert has to cover every tier: a
		// two-label name would fail the TLS handshake instead of the cap.
		for (const mbps of tiers) {
			const sni = speedGatewaySni(mbps, tiers, base)
			expect(sni).toBe(`speed${mbps}.${base}`)
			expect(sni?.split(".").length).toBe(base.split(".").length + 1)
		}
	})
})
