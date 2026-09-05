import type { VpnNode } from "@prisma/client"
import { config } from "../config"
import { prisma } from "../prisma"
import { nodeLocation, type MapLocation } from "./insightMath"
import { publicRestrictions, type PublicRestriction } from "./nodeRestrictions"

export type NodeAvailability = "PENDING" | "ONLINE" | "OFFLINE" | "DISABLED" | "MAINTENANCE"

export function isHeartbeatFresh(lastHeartbeat: Date | null): boolean {
	if (!lastHeartbeat) return false
	return Date.now() - lastHeartbeat.getTime() <= config.NODE_OFFLINE_AFTER_SEC * 1000
}

/**
 * Status as the control plane sees it right now. The stored `status` column is
 * updated by heartbeats and the monitor loop, but a node whose heartbeat just
 * went stale must already read as OFFLINE for clients.
 */
export function effectiveNodeStatus(node: VpnNode): NodeAvailability {
	if (node.status === "DISABLED") return "DISABLED"
	if (node.maintenance) return "MAINTENANCE"
	if (!node.wireguardPublicKey) return "PENDING"
	return isHeartbeatFresh(node.lastHeartbeat) ? "ONLINE" : "OFFLINE"
}

export function nodeLoadPercent(node: VpnNode): number {
	if (node.capacity <= 0) return 100
	return Math.min(100, Math.round((node.activePeers / node.capacity) * 100))
}

export function nodeHost(node: VpnNode): string {
	const hostname = node.hostname.trim()
	return hostname.length > 0 ? hostname : node.publicIp
}

export function nodeEndpoint(node: VpnNode): string {
	return `${nodeHost(node)}:${node.wireguardPort}`
}

/**
 * What the app puts on the first line of a server row: the country. Never the
 * internal node name — "de-01" means nothing to a user.
 */
export function nodeTitle(node: VpnNode): string {
	return node.country.trim().length > 0 ? node.country.trim() : node.countryCode
}

/** Second line: city, else region, else the country code as a last resort. */
export function nodeSubtitle(node: VpnNode): string {
	const city = node.city?.trim() ?? ""
	if (city.length > 0) return city
	const region = node.region?.trim() ?? ""
	if (region.length > 0) return region
	return node.countryCode
}

/**
 * Host the app measures latency against before a tunnel exists. Explicit
 * `pingTarget` wins so an operator can point at an ICMP-friendly address.
 */
export function nodePingTarget(node: VpnNode): string {
	const target = node.pingTarget?.trim() ?? ""
	return target.length > 0 ? target : nodeHost(node)
}

/** A node can accept a new peer only when it is online and below capacity. */
export function isNodeConnectable(node: VpnNode): boolean {
	return effectiveNodeStatus(node) === "ONLINE" && node.activePeers < node.capacity
}

export type PublicNodeView = {
	id: string
	/** Internal handle ("de-01"). Admin/debug only — the app never renders it. */
	name: string
	country: string
	countryCode: string
	region: string | null
	city: string | null
	/** Primary line in the server list, e.g. "Germany". */
	title: string
	/** Secondary line, e.g. "Frankfurt"; falls back to region, then country code. */
	subtitle: string
	/** Host to measure latency against before the tunnel is up. */
	pingTarget: string
	host: string
	publicIp: string
	gatewayPort: number | null
	gatewayHost: string | null
	maintenance: boolean
	location: MapLocation | null
	restrictions: PublicRestriction[]
	port: number
	status: NodeAvailability
	online: boolean
	connectable: boolean
	loadPercent: number
	activePeers: number
	capacity: number
	/** Minimum plan tier that may connect here (0 = free). */
	tier: number
	tierLabel: string
	/** True when the node runs the sing-box VLESS-over-TLS gateway. */
	hasGateway: boolean
	cpuPercent: number | null
	ramPercent: number | null
	uptimeSeconds: number | null
	agentVersion: string | null
	lastHeartbeat: string | null
}

export function nodeTierLabel(tier: number): string {
	if (tier >= 2) return "Pro"
	if (tier === 1) return "Basic"
	return "Free"
}

/**
 * Client-facing projection. Deliberately omits internal fields (subnet, DNS,
 * WireGuard public key); those are handed out only by /api/vpn/connect for a
 * session that was actually authorised.
 */
export function toPublicNode(node: VpnNode): PublicNodeView {
	const status = effectiveNodeStatus(node)
	return {
		id: node.id,
		name: node.name,
		country: node.country,
		countryCode: node.countryCode,
		region: node.region ?? null,
		city: node.city ?? null,
		title: nodeTitle(node),
		subtitle: nodeSubtitle(node),
		pingTarget: nodePingTarget(node),
		host: nodeHost(node),
		publicIp: node.publicIp,
		gatewayPort: node.gatewayPort ?? null,
		gatewayHost: node.gatewayHost ?? null,
		maintenance: Boolean(node.maintenance),
		location: nodeLocation(node),
		restrictions: publicRestrictions([]),
		port: node.wireguardPort,
		status,
		online: status === "ONLINE",
		connectable: isNodeConnectable(node),
		loadPercent: nodeLoadPercent(node),
		activePeers: node.activePeers,
		capacity: node.capacity,
		tier: node.tier,
		tierLabel: nodeTierLabel(node.tier),
		hasGateway: Boolean(node.gatewayHost && node.gatewayPort),
		cpuPercent: node.cpuPercent ?? null,
		ramPercent: node.ramPercent ?? null,
		uptimeSeconds: node.uptimeSeconds ?? null,
		agentVersion: node.agentVersion ?? null,
		lastHeartbeat: node.lastHeartbeat?.toISOString() ?? null,
	}
}

/** Nodes visible to clients: disabled nodes are hidden entirely. */
export async function listSelectableNodes(): Promise<VpnNode[]> {
	return prisma.vpnNode.findMany({
		where: { status: { not: "DISABLED" } },
		orderBy: [{ country: "asc" }, { city: "asc" }, { name: "asc" }],
	})
}

/** One query for node-local and global restrictions, never an account's rules. */
export async function loadPublicNodes(nodes: VpnNode[]): Promise<PublicNodeView[]> {
	if (!nodes.length) return []
	const rows = await prisma.nodeBlockRule.findMany({
		where: { enabled: true, OR: [{ nodeId: null }, { nodeId: { in: nodes.map((n) => n.id) } }] },
		orderBy: { createdAt: "asc" },
	})
	return nodes.map((node) => ({
		...toPublicNode(node),
		restrictions: publicRestrictions(rows.filter((r) => !r.nodeId || r.nodeId === node.id)),
	}))
}
