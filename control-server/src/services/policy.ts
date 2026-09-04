/**
 * Node policy: what the sing-box gateway on a node should enforce.
 *
 * Two things travel from the control plane to a node's `singbox.json`:
 *
 *   1. the VLESS user list - one personal credential per active device (plus
 *      the legacy fleet-wide "gluk" user while VLESS_LEGACY_USER_ENABLED);
 *   2. "reject" rules for the sing-box router - the built-in ones the agent
 *      always emits (BitTorrent, outbound SMTP, well-known torrent ports) and
 *      the admin-managed rows in `node_block_rules` (global or per node).
 *
 * The agent never receives anything it could turn into a redirect: every rule
 * becomes `{ <field>: [value], "action": "reject" }` and the outbound list is
 * one `direct` per device. What it *can* do is refuse traffic and count it.
 *
 * `version` is a hash of the whole document. The heartbeat carries the desired
 * version, the agent compares it with what it last applied, and only a change
 * costs a config rewrite and a sing-box reload.
 */
import { createHash } from "node:crypto"
import type { BlockRuleKind, NodeBlockRule, VpnNode } from "@prisma/client"
import { config } from "../config"
import { badRequest } from "../lib/errors"
import { parseCidr } from "../lib/ip"
import { prisma } from "../prisma"
import { enqueueCommand, hasOpenCommand } from "./nodeCommands"
import { isHeartbeatFresh } from "./nodes"

/** sing-box sniffer protocols a PROTOCOL rule may name. */
export const SNIFFED_PROTOCOLS = [
	"bittorrent",
	"quic",
	"dns",
	"stun",
	"ssh",
	"rdp",
	"dtls",
	"ntp",
	"http",
	"tls",
] as const

/** Rules the agent always emits, shown in the panel as read-only. */
export const BUILTIN_RULES: ReadonlyArray<{
	kind: BlockRuleKind
	value: string
	network: string | null
	note: string
}> = [
	{
		kind: "PROTOCOL",
		value: "bittorrent",
		network: null,
		note: "BitTorrent / P2P — abuse letters from German rights holders",
	},
	{
		kind: "PORT",
		value: "25",
		network: "tcp",
		note: "Outbound SMTP — keeps the node's IP out of spam blocklists",
	},
	{
		kind: "PORT_RANGE",
		value: "6881:6999",
		network: null,
		note: "Common BitTorrent client/DHT ports (encrypted swarms evade the sniffer)",
	},
	{
		kind: "PORT",
		value: "6969",
		network: null,
		note: "Classic BitTorrent tracker port",
	},
]

const DOMAIN_RE = /^(?=.{1,253}$)([a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i
const PORT_RE = /^\d{1,5}$/
const PORT_RANGE_RE = /^(\d{1,5}):(\d{1,5})$/

export type NormalizedRule = { kind: BlockRuleKind; value: string; network: string | null }

/** Validates and canonicalises one rule. Throws a 400 with a plain message. */
export function normalizeRule(input: {
	kind: BlockRuleKind
	value: string
	network?: string | null
}): NormalizedRule {
	const value = String(input.value ?? "").trim()
	const network = input.network ? String(input.network).trim().toLowerCase() : null
	if (network !== null && network !== "tcp" && network !== "udp" && network !== "") {
		throw badRequest("network must be tcp, udp or empty")
	}
	const net = network === "" ? null : network
	if (!value) throw badRequest("A rule value is required")
	if (value.length > 200) throw badRequest("Rule value is too long")

	switch (input.kind) {
		case "PROTOCOL": {
			const lower = value.toLowerCase()
			if (!(SNIFFED_PROTOCOLS as readonly string[]).includes(lower)) {
				throw badRequest(`Unknown protocol. Use one of: ${SNIFFED_PROTOCOLS.join(", ")}`)
			}
			return { kind: input.kind, value: lower, network: net }
		}
		case "DOMAIN":
		case "DOMAIN_SUFFIX": {
			const lower = value.toLowerCase().replace(/^\.+/, "").replace(/\.+$/, "")
			if (!DOMAIN_RE.test(lower)) throw badRequest("Not a valid domain name")
			return { kind: input.kind, value: lower, network: net }
		}
		case "DOMAIN_KEYWORD": {
			const lower = value.toLowerCase()
			if (lower.length < 3) throw badRequest("A keyword needs at least 3 characters")
			if (!/^[a-z0-9.-]+$/.test(lower)) throw badRequest("Keywords may contain letters, digits, dots and dashes")
			return { kind: input.kind, value: lower, network: net }
		}
		case "DOMAIN_REGEX": {
			try {
				// RE2 (Go) is stricter than JS, but a JS syntax error is a certain
				// Go syntax error, which is what we can check here.
				new RegExp(value)
			} catch {
				throw badRequest("Not a valid regular expression")
			}
			if (/\(\?[<=!]/.test(value)) throw badRequest("Lookaround is not supported by sing-box")
			return { kind: input.kind, value, network: net }
		}
		case "IP_CIDR": {
			const cidr = value.includes("/") ? value : `${value}/32`
			try {
				parseCidr(cidr)
			} catch {
				throw badRequest("Not a valid IPv4 address or CIDR")
			}
			return { kind: input.kind, value: cidr, network: net }
		}
		case "PORT": {
			if (!PORT_RE.test(value)) throw badRequest("Port must be a number")
			const port = Number(value)
			if (port < 1 || port > 65535) throw badRequest("Port must be between 1 and 65535")
			return { kind: input.kind, value: String(port), network: net }
		}
		case "PORT_RANGE": {
			const match = PORT_RANGE_RE.exec(value.replace("-", ":"))
			if (!match) throw badRequest("Port range must look like 6881:6999")
			const from = Number(match[1])
			const to = Number(match[2])
			if (from < 1 || to > 65535 || from > to) throw badRequest("Port range is out of order")
			return { kind: input.kind, value: `${from}:${to}`, network: net }
		}
		default:
			throw badRequest("Unknown rule kind")
	}
}

export type PolicyUser = { name: string; uuid: string; flow: string }

export type NodePolicy = {
	version: string
	generatedAt: string
	users: PolicyUser[]
	/** Fleet-wide credential from .env; null when disabled or unset. */
	legacyUser: PolicyUser | null
	rules: NormalizedRule[]
	builtinRules: NormalizedRule[]
	domainStats: boolean
	flow: string
}

/** sing-box user name for a device. Stable, and the reverse lookup is trivial. */
export function vlessUserName(deviceId: string): string {
	return `dev_${deviceId}`
}

export function deviceIdFromUserName(name: string): string | null {
	const match = /^dev_([0-9a-f-]{36})$/i.exec(String(name ?? "").trim())
	return match ? (match[1] as string).toLowerCase() : null
}

function policyVersion(document: Omit<NodePolicy, "version" | "generatedAt">): string {
	const canonical = JSON.stringify({
		users: [...document.users].sort((a, b) => a.name.localeCompare(b.name)),
		legacyUser: document.legacyUser,
		rules: [...document.rules].sort((a, b) =>
			`${a.kind}|${a.value}|${a.network ?? ""}`.localeCompare(`${b.kind}|${b.value}|${b.network ?? ""}`),
		),
		builtinRules: document.builtinRules,
		domainStats: document.domainStats,
		flow: document.flow,
	})
	return createHash("sha256").update(canonical).digest("hex").slice(0, 16)
}

/**
 * The full document for one node. Devices are included when they are ACTIVE,
 * their owner is ACTIVE and holds an active subscription whose tier meets the
 * node's tier - the same test /api/vpn/connect applies, so a device that is
 * allowed to connect is provisioned before it tries.
 */
export async function buildNodePolicy(node: VpnNode): Promise<NodePolicy> {
	const flow = (node.gatewayFlow ?? config.VLESS_FLOW).trim() || "xtls-rprx-vision"
	const now = new Date()

	const [devices, rows] = await Promise.all([
		prisma.device.findMany({
			where: {
				status: "ACTIVE",
				vlessUuid: { not: null },
				user: {
					status: "ACTIVE",
					subscriptions: {
						some: { status: "ACTIVE", expiresAt: { gt: now }, tier: { gte: node.tier } },
					},
				},
			},
			select: { id: true, vlessUuid: true },
			orderBy: { createdAt: "asc" },
		}),
		prisma.nodeBlockRule.findMany({
			where: { enabled: true, OR: [{ nodeId: null }, { nodeId: node.id }] },
			orderBy: { createdAt: "asc" },
		}),
	])

	const users: PolicyUser[] = devices
		.filter((device) => device.vlessUuid)
		.map((device) => ({ name: vlessUserName(device.id), uuid: device.vlessUuid as string, flow }))

	const legacyUuid = config.VLESS_UUID.trim()
	const legacyUser: PolicyUser | null =
		config.VLESS_LEGACY_USER_ENABLED && legacyUuid ? { name: "gluk", uuid: legacyUuid, flow } : null

	const rules = rows.map((row: NodeBlockRule) => ({
		kind: row.kind,
		value: row.value,
		network: row.network,
	}))
	const builtinRules = BUILTIN_RULES.map((rule) => ({
		kind: rule.kind,
		value: rule.value,
		network: rule.network,
	}))

	const body = {
		users,
		legacyUser,
		rules,
		builtinRules,
		domainStats: config.DOMAIN_STATS_ENABLED,
		flow,
	}
	return { version: policyVersion(body), generatedAt: now.toISOString(), ...body }
}

/**
 * Queues SYNC_POLICY for every node that is alive (or one node), so a device
 * registration or a new rule reaches sing-box on the next heartbeat rather
 * than whenever the version comparison happens to notice. Idempotent: a node
 * with a SYNC_POLICY already waiting does not get a second one.
 */
export async function requestPolicySync(nodeId?: string | null): Promise<number> {
	const nodes = await prisma.vpnNode.findMany({
		where: nodeId ? { id: nodeId } : { status: { not: "DISABLED" } },
		select: { id: true, lastHeartbeat: true, status: true },
	})
	let queued = 0
	for (const node of nodes) {
		if (!nodeId && !isHeartbeatFresh(node.lastHeartbeat)) continue
		const open = await prisma.nodeCommand.count({
			where: { nodeId: node.id, type: "SYNC_POLICY", status: { in: ["PENDING", "DELIVERED"] } },
		})
		if (open > 0) continue
		await enqueueCommand({ nodeId: node.id, type: "SYNC_POLICY", payload: {} })
		queued += 1
	}
	return queued
}

// `hasOpenCommand` is session-scoped; re-exported here so callers dealing with
// policy do not need to know where the queue lives.
export { hasOpenCommand }
