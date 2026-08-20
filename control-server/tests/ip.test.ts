import { describe, expect, it } from "vitest"
import {
	gatewayIp,
	intToIp,
	ipToInt,
	isIpInCidr,
	parseCidr,
	usableHostIps,
} from "../src/lib/ip"
import {
	assertDistinctKeys,
	isValidWireGuardKey,
	wireGuardKeySchema,
} from "../src/lib/wg"

const wgKey = (fill: number): string =>
	Buffer.from(new Uint8Array(32).fill(fill)).toString("base64")

describe("ipToInt / intToIp", () => {
	it("round-trips IPv4 addresses", () => {
		expect(ipToInt("10.8.0.1")).toBe(168296449)
		expect(intToIp(168296449)).toBe("10.8.0.1")
		expect(ipToInt("0.0.0.0")).toBe(0)
		expect(intToIp(0)).toBe("0.0.0.0")
		expect(ipToInt("255.255.255.255")).toBe(4294967295)
		expect(intToIp(4294967295)).toBe("255.255.255.255")
	})

	it("rejects malformed addresses", () => {
		expect(() => ipToInt("10.8.0")).toThrow()
		expect(() => ipToInt("10.8.0.1.2")).toThrow()
		expect(() => ipToInt("10.8.0.256")).toThrow()
		expect(() => ipToInt("10.8.0.x")).toThrow()
		expect(() => ipToInt("")).toThrow()
	})
})

describe("parseCidr", () => {
	it("masks host bits and reports the subnet size", () => {
		expect(parseCidr("10.8.0.0/24")).toEqual({
			network: ipToInt("10.8.0.0"),
			prefix: 24,
			size: 256,
		})
		// An address inside the subnet resolves to the same network.
		expect(parseCidr("10.8.0.37/24").network).toBe(ipToInt("10.8.0.0"))
		expect(parseCidr("10.9.0.0/16").size).toBe(65536)
		expect(parseCidr("10.8.0.0/30").size).toBe(4)
	})

	it("rejects prefixes outside /16../30 and malformed input", () => {
		expect(() => parseCidr("10.0.0.0/8")).toThrow()
		expect(() => parseCidr("10.8.0.0/31")).toThrow()
		expect(() => parseCidr("10.8.0.0/32")).toThrow()
		expect(() => parseCidr("10.8.0.0")).toThrow()
		expect(() => parseCidr("10.8.0.0/abc")).toThrow()
	})
})

describe("gatewayIp", () => {
	it("is the first address of the tunnel subnet", () => {
		expect(gatewayIp("10.8.0.0/24")).toBe("10.8.0.1")
		expect(gatewayIp("10.8.0.99/24")).toBe("10.8.0.1")
		expect(gatewayIp("10.9.4.0/22")).toBe("10.9.4.1")
	})
})

describe("usableHostIps", () => {
	it("excludes network, gateway and broadcast addresses", () => {
		const pool = usableHostIps("10.8.0.0/24")
		expect(pool).toHaveLength(253)
		expect(pool[0]).toBe("10.8.0.2")
		expect(pool[pool.length - 1]).toBe("10.8.0.254")
		expect(pool).not.toContain("10.8.0.0")
		expect(pool).not.toContain("10.8.0.1")
		expect(pool).not.toContain("10.8.0.255")
	})

	it("honours the reserved host count", () => {
		const pool = usableHostIps("10.8.0.0/24", 0)
		expect(pool).toHaveLength(254)
		expect(pool[0]).toBe("10.8.0.1")
	})

	it("handles the smallest supported subnet", () => {
		expect(usableHostIps("10.8.0.0/30")).toEqual(["10.8.0.2"])
	})

	it("returns unique addresses", () => {
		const pool = usableHostIps("10.8.0.0/24")
		expect(new Set(pool).size).toBe(pool.length)
	})
})

describe("isIpInCidr", () => {
	it("detects membership", () => {
		expect(isIpInCidr("10.8.0.2", "10.8.0.0/24")).toBe(true)
		expect(isIpInCidr("10.8.0.254", "10.8.0.0/24")).toBe(true)
		expect(isIpInCidr("10.8.1.2", "10.8.0.0/24")).toBe(false)
		expect(isIpInCidr("192.168.1.2", "10.8.0.0/24")).toBe(false)
	})
})

describe("WireGuard key validation", () => {
	it("accepts base64-encoded 32-byte keys", () => {
		expect(isValidWireGuardKey(wgKey(1))).toBe(true)
		expect(wireGuardKeySchema.safeParse(wgKey(7)).success).toBe(true)
	})

	it("rejects anything that is not a 32-byte base64 key", () => {
		const valid = wgKey(1)
		expect(isValidWireGuardKey(valid.slice(0, 43))).toBe(false) // missing padding
		expect(
			isValidWireGuardKey(Buffer.from(new Uint8Array(16)).toString("base64")),
		).toBe(false) // 16 bytes
		expect(isValidWireGuardKey(`${valid.slice(0, 42)}$=`)).toBe(false)
		expect(isValidWireGuardKey("")).toBe(false)
		expect(isValidWireGuardKey(null)).toBe(false)
		expect(isValidWireGuardKey(42)).toBe(false)
		expect(wireGuardKeySchema.safeParse("not-a-key").success).toBe(false)
	})

	it("refuses a device key that equals the node key", () => {
		const nodeKey = wgKey(9)
		expect(assertDistinctKeys(nodeKey, nodeKey)).toBe(false)
		expect(assertDistinctKeys(wgKey(3), nodeKey)).toBe(true)
		// A node that has not published its key yet cannot be impersonated.
		expect(assertDistinctKeys(wgKey(3), null)).toBe(true)
	})
})
