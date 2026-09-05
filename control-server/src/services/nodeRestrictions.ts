import type { BlockRuleKind, NodeBlockRule } from "@prisma/client"

/** Single source of truth, re-exported by policy.ts for existing callers. */
export const BUILTIN_RULES: ReadonlyArray<{ kind: BlockRuleKind; value: string; network: string | null; note: string }> = [
	{ kind: "PROTOCOL", value: "bittorrent", network: null, note: "BitTorrent / P2P — abuse letters from German rights holders" },
	{ kind: "PORT", value: "25", network: "tcp", note: "Outbound SMTP — keeps the node's IP out of spam blocklists" },
	{ kind: "PORT_RANGE", value: "6881:6999", network: null, note: "Common BitTorrent client/DHT ports (encrypted swarms evade the sniffer)" },
	{ kind: "PORT", value: "6969", network: null, note: "Classic BitTorrent tracker port" },
]
export type PublicRestriction = {
	kind: BlockRuleKind; value: string; network: string | null; source: "builtin" | "policy"
	code: "bittorrent" | "smtp25" | "p2p_ports" | "custom"; label: string
}
export function publicRestrictions(rows: ReadonlyArray<Pick<NodeBlockRule, "kind" | "value" | "network">>): PublicRestriction[] {
	const rules = [...BUILTIN_RULES.map((r) => ({ ...r, source: "builtin" as const })), ...rows.map((r) => ({ ...r, source: "policy" as const }))]
	const seen = new Set<string>()
	return rules.filter((r) => {
		const key = `${r.kind}|${r.value}|${r.network ?? ""}`
		if (seen.has(key)) return false
		seen.add(key)
		return true
	}).map((r) => {
		const code: PublicRestriction["code"] = r.kind === "PROTOCOL" && r.value === "bittorrent" ? "bittorrent"
			: r.kind === "PORT" && r.value === "25" && r.network !== "udp" ? "smtp25"
			: (r.kind === "PORT_RANGE" && r.value === "6881:6999") || (r.kind === "PORT" && r.value === "6969") ? "p2p_ports" : "custom"
		const label = code === "bittorrent" ? "Torrents prohibited" : code === "smtp25" ? "Outbound SMTP blocked"
			: code === "p2p_ports" ? "Known P2P ports blocked" : `${r.kind}: ${r.value}`
		return { kind: r.kind, value: r.value, network: r.network, source: r.source, code, label }
	})
}
