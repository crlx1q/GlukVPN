import { describe, expect, it } from "vitest"
import { BUILTIN_RULES, publicRestrictions, ruleText } from "../src/services/nodeRestrictions"

// The "what is forbidden on this server" list is read by humans in four places
// (extension popup, site map, both Flutter clients, admin table), so it has to
// stay one line per restriction even though the node needs one rule per row.
describe("publicRestrictions", () => {
	it("folds the four builtin rules into three readable lines", () => {
		const list = publicRestrictions([])
		expect(BUILTIN_RULES).toHaveLength(4)
		expect(list.map((r) => r.code)).toEqual(["bittorrent", "smtp25", "p2p_ports"])
		expect(list.every((r) => r.source === "builtin")).toBe(true)
		expect(list.every((r) => r.label.length > 0 && r.detail.length > 0)).toBe(true)
	})

	it("spells out every rule behind a line instead of repeating the line", () => {
		const list = publicRestrictions([])
		const p2p = list.find((r) => r.code === "p2p_ports")
		// This is the duplicate the admin table used to show twice.
		expect(p2p?.rules).toEqual(["6881-6999", "6969"])
		expect(list.find((r) => r.code === "smtp25")?.rules).toEqual(["25/tcp"])
		expect(list.find((r) => r.code === "bittorrent")?.rules).toEqual(["bittorrent"])
	})

	it("keeps the administrator's own comment as the line's detail", () => {
		const list = publicRestrictions([
			{ kind: "PORT", value: "3389", network: "tcp", note: "  RDP scanners hammer this port  " },
		])
		const custom = list.find((r) => r.code === "custom")
		expect(custom?.source).toBe("policy")
		expect(custom?.label).toBe("PORT: 3389")
		expect(custom?.detail).toBe("RDP scanners hammer this port")
		expect(custom?.rules).toEqual(["3389/tcp"])
	})

	it("explains a custom rule that arrived without a comment", () => {
		const [custom] = publicRestrictions([{ kind: "PROTOCOL", value: "quic", network: null }])
			.filter((r) => r.code === "custom")
		expect(custom?.detail).toBe("Added for this server by an administrator.")
	})

	it("adds no line when a policy row repeats a builtin rule", () => {
		const list = publicRestrictions([
			{ kind: "PORT", value: "6969", network: null, note: "tracker" },
			{ kind: "PORT_RANGE", value: "6881:6999", network: null, note: "swarm" },
		])
		expect(list).toHaveLength(3)
		expect(list.find((r) => r.code === "p2p_ports")?.rules).toEqual(["6881-6999", "6969"])
	})
})

describe("ruleText", () => {
	it("writes a rule the way a person would read it", () => {
		expect(ruleText({ kind: "PORT_RANGE", value: "6881:6999", network: null })).toBe("6881-6999")
		expect(ruleText({ kind: "PORT", value: "25", network: "tcp" })).toBe("25/tcp")
		expect(ruleText({ kind: "PORT", value: "6969", network: null })).toBe("6969")
		expect(ruleText({ kind: "PROTOCOL", value: "bittorrent", network: null })).toBe("bittorrent")
	})
})
