import type { VpnNode } from "@prisma/client"
import { config } from "../config"
import { prisma } from "../prisma"

export type NodeAvailability = "PENDING" | "ONLINE" | "OFFLINE" | "DISABLED"

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

/** A node can accept a new peer only when it is online and below capacity. */
export function isNodeConnectable(node: VpnNode): boolean {
	return effectiveNodeStatus(node) === "ONLINE" && node.activePeers < node.capacity
}

export type PublicNodeView = {
	id: string
	name: string
	country: string
	countryCode: string
	host: string
	port: number
	status: NodeAvailability
	online: boolean
	connectable: boolean
	loadPercent: number
	activePeers: number
	capacity: number
	cpuPercent: number | null
	ramPercent: number | null
	uptimeSeconds: number | null
	agentVersion: string | null
	lastHeartbeat: string | null
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
		host: nodeHost(node),
		port: node.wireguardPort,
		status,
		online: status === "ONLINE",
		connectable: isNodeConnectable(node),
		loadPercent: nodeLoadPercent(node),
		activePeers: node.activePeers,
		capacity: node.capacity,
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
		orderBy: [{ country: "asc" }, { name: "asc" }],
	})
}
