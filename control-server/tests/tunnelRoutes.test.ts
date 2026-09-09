import { describe, expect, it } from "vitest"

import {
	parseBypassList,
	splitTunnelRoutes,
	tunnelAllowedIps,
} from "../src/services/tunnelRoutes"

const SPACE = 2 ** 32

function toNumber(ip: string): number {
	return ip.split(".").reduce((acc, part) => acc * 256 + Number(part), 0)
}

function ranges(routes: ReadonlyArray<string>): Array<{ start: number; end: number }> {
	return routes.map((route) => {
		const [address, bits] = route.split("/")
		const size = 2 ** (32 - Number(bits))
		const start = toNumber(address)
		return { start, end: start + size - 1 }
	})
}

function covers(routes: ReadonlyArray<string>, ip: string): boolean {
	const value = toNumber(ip)
	return ranges(routes).some((range) => value >= range.start && value <= range.end)
}

function addressCount(routes: ReadonlyArray<string>): number {
	return ranges(routes).reduce((acc, range) => acc + (range.end - range.start + 1), 0)
}

describe("splitTunnelRoutes", () => {
	it("stays a plain default route when nothing is excluded", () => {
		expect(splitTunnelRoutes([])).toEqual(["0.0.0.0/0"])
	})

	it("covers the whole address space except the control-plane host", () => {
		const routes = splitTunnelRoutes(["203.0.113.7"])
		expect(routes).not.toContain("0.0.0.0/0")
		expect(addressCount(routes)).toBe(SPACE - 1)
		expect(covers(routes, "203.0.113.7")).toBe(false)
		expect(covers(routes, "203.0.113.6")).toBe(true)
		expect(covers(routes, "203.0.113.8")).toBe(true)
		expect(covers(routes, "1.1.1.1")).toBe(true)
		expect(covers(routes, "0.0.0.0")).toBe(true)
		expect(covers(routes, "255.255.255.255")).toBe(true)
	})

	it("punches a hole for a whole subnet", () => {
		const routes = splitTunnelRoutes(["198.51.100.0/24"])
		expect(addressCount(routes)).toBe(SPACE - 256)
		expect(covers(routes, "198.51.100.0")).toBe(false)
		expect(covers(routes, "198.51.100.255")).toBe(false)
		expect(covers(routes, "198.51.101.0")).toBe(true)
	})

	it("snaps a host address down to its network and merges neighbours", () => {
		const routes = splitTunnelRoutes(["198.51.100.17/24", "198.51.101.0/24"])
		expect(addressCount(routes)).toBe(SPACE - 512)
		expect(covers(routes, "198.51.100.17")).toBe(false)
		expect(covers(routes, "198.51.101.200")).toBe(false)
		expect(covers(routes, "198.51.102.1")).toBe(true)
	})

	it("keeps two separate holes separate", () => {
		const routes = splitTunnelRoutes(["203.0.113.7", "10.11.12.13"])
		expect(addressCount(routes)).toBe(SPACE - 2)
		expect(covers(routes, "203.0.113.7")).toBe(false)
		expect(covers(routes, "10.11.12.13")).toBe(false)
		expect(covers(routes, "10.11.12.14")).toBe(true)
	})

	it("ignores junk instead of breaking the connect flow", () => {
		expect(splitTunnelRoutes(["not-an-ip", "999.1.1.1", "1.2.3", ""])).toEqual(["0.0.0.0/0"])
	})

	it("refuses an exclusion that would leave the client without routes", () => {
		expect(splitTunnelRoutes(["0.0.0.0/0"])).toEqual(["0.0.0.0/0"])
	})
})

describe("parseBypassList", () => {
	it("trims entries and drops empty ones", () => {
		expect(parseBypassList(" 203.0.113.7 , ,198.51.100.0/24,")).toEqual([
			"203.0.113.7",
			"198.51.100.0/24",
		])
	})
})

describe("tunnelAllowedIps", () => {
	it("falls back to the default route when the env value is empty", () => {
		expect(tunnelAllowedIps("")).toEqual(["0.0.0.0/0"])
	})

	it("builds routes straight from the env value", () => {
		const routes = tunnelAllowedIps("203.0.113.7")
		expect(covers(routes, "203.0.113.7")).toBe(false)
		expect(addressCount(routes)).toBe(SPACE - 1)
	})
})
