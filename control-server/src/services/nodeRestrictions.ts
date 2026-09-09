import type { BlockRuleKind, NodeBlockRule } from "@prisma/client"

/** Single source of truth, re-exported by policy.ts for existing callers. */
export const BUILTIN_RULES: ReadonlyArray<{ kind: BlockRuleKind; value: string; network: string | null; note: string }> = [
	{ kind: "PROTOCOL", value: "bittorrent", network: null, note: "BitTorrent / P2P — abuse letters from German rights holders" },
	{ kind: "PORT", value: "25", network: "tcp", note: "Outbound SMTP — keeps the node's IP out of spam blocklists" },
	{ kind: "PORT_RANGE", value: "6881:6999", network: null, note: "Common BitTorrent client/DHT ports (encrypted swarms evade the sniffer)" },
	{ kind: "PORT", value: "6969", network: null, note: "Classic BitTorrent tracker port" },
]

export type RestrictionCode = "bittorrent" | "smtp25" | "p2p_ports" | "custom"

/**
 * One line of the "what is forbidden on this server" list, shared by every
 * surface: the extension popup, the site, both Flutter clients and the admin
 * table.
 *
 * One row per router rule is what the node needs, not what a human reads: the
 * two port rules that fence off BitTorrent arrived as two chips with the very
 * same text, which is the duplicate visible in the UI today. The list is now
 * grouped by `code` — one line per restriction, with the rules behind it spelled
 * out in `rules` and the reason in `detail`.
 */
export type PublicRestriction = {
	kind: BlockRuleKind
	value: string
	network: string | null
	source: "builtin" | "policy"
	code: RestrictionCode
	/** Short title. Clients that ship translations key off `code` instead. */
	label: string
	/** The comment under the title: what exactly is refused, and why. */
	detail: string
	/** Router rules folded into this line, e.g. ["6881-6999", "6969"]. */
	rules: string[]
}

type RuleRow = Pick<NodeBlockRule, "kind" | "value" | "network"> & { note?: string | null }

const KNOWN: Record<Exclude<RestrictionCode, "custom">, { label: string; detail: string }> = {
	bittorrent: {
		label: "Torrents prohibited",
		detail: "The node recognises the BitTorrent handshake and drops it. Rights holders bill the host for every abuse letter, so seeding never works through this exit.",
	},
	smtp25: {
		label: "Outbound SMTP blocked",
		detail: "Mail sent straight to port 25 is refused — that is what keeps the exit address out of spam blocklists. Submission over 465 and 587 still works.",
	},
	p2p_ports: {
		label: "Known P2P ports blocked",
		detail: "The classic BitTorrent tracker and DHT ports are refused as well, because an encrypted swarm slips past protocol sniffing.",
	},
}

/** "PORT_RANGE 6881:6999" → "6881-6999", "PORT 25 tcp" → "25/tcp". */
export function ruleText(rule: RuleRow): string {
	const network = rule.network ? `/${rule.network}` : ""
	if (rule.kind === "PORT_RANGE") return `${rule.value.replace(":", "-")}${network}`
	if (rule.kind === "PROTOCOL") return rule.value
	return `${rule.value}${network}`
}

function codeFor(rule: RuleRow): RestrictionCode {
	if (rule.kind === "PROTOCOL" && rule.value === "bittorrent") return "bittorrent"
	if (rule.kind === "PORT" && rule.value === "25" && rule.network !== "udp") return "smtp25"
	if (rule.kind === "PORT_RANGE" && rule.value === "6881:6999") return "p2p_ports"
	if (rule.kind === "PORT" && rule.value === "6969") return "p2p_ports"
	return "custom"
}

export function publicRestrictions(rows: ReadonlyArray<RuleRow>): PublicRestriction[] {
	const rules = [
		...BUILTIN_RULES.map((r) => ({ ...r, source: "builtin" as const })),
		...rows.map((r) => ({ ...r, source: "policy" as const })),
	]
	const byKey = new Map<string, PublicRestriction>()
	const out: PublicRestriction[] = []
	for (const rule of rules) {
		const code = codeFor(rule)
		// A known restriction is one line no matter how many rules enforce it;
		// a custom one keeps its own line, but never repeats the same rule.
		const key = code === "custom" ? `custom|${rule.kind}|${rule.value}|${rule.network ?? ""}` : code
		const text = ruleText(rule)
		const existing = byKey.get(key)
		if (existing) {
			if (!existing.rules.includes(text)) existing.rules.push(text)
			continue
		}
		const known = code === "custom" ? null : KNOWN[code]
		const note = (rule.note ?? "").trim()
		const entry: PublicRestriction = {
			kind: rule.kind,
			value: rule.value,
			network: rule.network,
			source: rule.source,
			code,
			label: known ? known.label : `${rule.kind}: ${rule.value}`,
			detail: known ? known.detail : note || "Added for this server by an administrator.",
			rules: [text],
		}
		byKey.set(key, entry)
		out.push(entry)
	}
	return out
}
