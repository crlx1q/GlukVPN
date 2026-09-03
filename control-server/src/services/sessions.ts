import type { Device, Session, User, VpnNode } from "@prisma/client"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { conflict, forbidden, notFound, serviceUnavailable } from "../lib/errors"
import { usableHostIps } from "../lib/ip"
import { bytesToNumber, prisma } from "../prisma"
import { enqueueCommand, hasOpenCommand } from "./nodeCommands"
import {
	effectiveNodeStatus,
	isNodeConnectable,
	nodeEndpoint,
	nodeHost,
} from "./nodes"

const ACTIVE_SESSION_STATES = ["PENDING", "ACTIVE"] as const

/** WireGuard config returned to the client. Never contains a private key. */
export type ClientTunnelConfig = {
	sessionId: string
	interfaceAddress: string
	dns: string[]
	mtu: number
	peerPublicKey: string
	endpoint: string
	allowedIps: string[]
	persistentKeepalive: number

	/**
	 * ROUND 24: the TLS gateway the Windows client should use instead of raw
	 * WireGuard. Absent when the operator has not configured one, and then the
	 * client behaves exactly as it did before.
	 */
	gateway?: {
		type: "vless"
		host: string
		port: number
		uuid: string
		sni?: string
		flow?: string
	}
}

export type SessionView = {
	id: string
	status: Session["status"]
	assignedVpnIp: string
	connectedAt: string
	disconnectedAt: string | null
	lastHandshakeAt: string | null
	bytesRx: number
	bytesTx: number
	durationSec: number
	node: { id: string; name: string; country: string; countryCode: string; host: string }
	deviceId: string
}

export function toSessionView(
	session: Session & { node: VpnNode },
): SessionView {
	const end = session.disconnectedAt ?? new Date()
	return {
		id: session.id,
		status: session.status,
		assignedVpnIp: session.assignedVpnIp,
		connectedAt: session.connectedAt.toISOString(),
		disconnectedAt: session.disconnectedAt?.toISOString() ?? null,
		lastHandshakeAt: session.lastHandshakeAt?.toISOString() ?? null,
		bytesRx: bytesToNumber(session.bytesRx),
		bytesTx: bytesToNumber(session.bytesTx),
		durationSec: Math.max(
			0,
			Math.floor((end.getTime() - session.connectedAt.getTime()) / 1000),
		),
		node: {
			id: session.node.id,
			name: session.node.name,
			country: session.node.country,
			countryCode: session.node.countryCode,
			host: session.node.hostname || session.node.publicIp,
		},
		deviceId: session.deviceId,
	}
}

/** Creates the address pool rows for a node the first time it is used. */
export async function ensureIpPool(node: VpnNode): Promise<void> {
	const existing = await prisma.ipLease.count({ where: { nodeId: node.id } })
	if (existing > 0) return
	// The first host address is the node itself (WireGuard gateway).
	const ips = usableHostIps(node.subnetCidr, 1)
	if (ips.length === 0) throw serviceUnavailable("Node subnet has no usable addresses")
	await prisma.ipLease.createMany({
		data: ips.map((ip) => ({ nodeId: node.id, ip })),
		skipDuplicates: true,
	})
}

export async function hasActiveSubscription(userId: string): Promise<boolean> {
	const subscription = await prisma.subscription.findFirst({
		where: { userId, status: "ACTIVE", expiresAt: { gt: new Date() } },
	})
	return subscription !== null
}

async function pickNode(nodeId?: string | null): Promise<VpnNode> {
	if (nodeId) {
		const node = await prisma.vpnNode.findUnique({ where: { id: nodeId } })
		if (!node) throw notFound("Node not found")
		if (node.status === "DISABLED") throw forbidden("Node is disabled")
		if (!node.wireguardPublicKey) {
			throw serviceUnavailable("Node has not published its WireGuard key yet")
		}
		if (effectiveNodeStatus(node) !== "ONLINE") {
			throw serviceUnavailable(`Node ${node.name} is offline`)
		}
		return node
	}

	// No explicit choice: least loaded online node.
	const candidates = await prisma.vpnNode.findMany({
		where: { status: { not: "DISABLED" }, wireguardPublicKey: { not: null } },
		orderBy: [{ activePeers: "asc" }],
	})
	const online = candidates.filter((node) => isNodeConnectable(node))
	const chosen = online[0]
	if (!chosen) throw serviceUnavailable("No VPN node is currently available")
	return chosen
}

/**
 * Allocates a free tunnel IP and creates the session row atomically, so two
 * parallel connects can never receive the same address.
 */
async function createSessionWithLease(params: {
	user: User
	device: Device
	node: VpnNode
}): Promise<Session> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		try {
			return await prisma.$transaction(async (tx) => {
				const lease = await tx.ipLease.findFirst({
					where: { nodeId: params.node.id, sessionId: null },
					orderBy: { ip: "asc" },
				})
				if (!lease) throw serviceUnavailable("Node has no free VPN addresses")

				const session = await tx.session.create({
					data: {
						userId: params.user.id,
						deviceId: params.device.id,
						nodeId: params.node.id,
						assignedVpnIp: lease.ip,
						peerPublicKey: params.device.publicKey,
						status: "PENDING",
					},
				})

				const claimed = await tx.ipLease.updateMany({
					where: { id: lease.id, sessionId: null },
					data: { sessionId: session.id, allocatedAt: new Date() },
				})
				if (claimed.count !== 1) throw conflict("Address lease was taken concurrently")
				return session
			})
		} catch (error) {
			const isRace =
				error instanceof Error && error.message.includes("taken concurrently")
			if (!isRace || attempt === 2) throw error
		}
	}
	throw serviceUnavailable("Could not allocate a VPN address, please retry")
}

export type ConnectResult = {
	session: Session
	node: VpnNode
	tunnel: ClientTunnelConfig
}

/**
 * Full connect flow (steps 6-11 of the client flow):
 * validate user/subscription/device -> pick node -> allocate IP -> create
 * session -> queue ADD_PEER for the node agent -> return tunnel parameters.
 */
export async function connectSession(params: {
	user: User
	device: Device
	nodeId?: string | null
	ip?: string | null
}): Promise<ConnectResult> {
	const { user, device } = params

	if (user.status !== "ACTIVE") throw forbidden("User is disabled")
	if (device.status !== "ACTIVE") throw forbidden("Device is revoked")
	if (!(await hasActiveSubscription(user.id))) {
		throw forbidden("No active subscription")
	}

	// A device may hold only one live session: reconnecting replaces the old one.
	const previous = await prisma.session.findMany({
		where: { deviceId: device.id, status: { in: [...ACTIVE_SESSION_STATES] } },
	})
	for (const session of previous) {
		await closeSession({ sessionId: session.id, reason: "reconnect" })
	}

	const maxSessions = Math.min(user.maxSessions, config.MAX_CONCURRENT_SESSIONS)
	const liveSessions = await prisma.session.count({
		where: { userId: user.id, status: { in: [...ACTIVE_SESSION_STATES] } },
	})
	if (liveSessions >= maxSessions) {
		throw conflict(
			`Maximum concurrent sessions reached (${maxSessions}). Disconnect another device first.`,
		)
	}

	const node = await pickNode(params.nodeId ?? null)
	const nodeLive = await prisma.session.count({
		where: { nodeId: node.id, status: { in: [...ACTIVE_SESSION_STATES] } },
	})
	if (nodeLive >= node.capacity) throw conflict(`Node ${node.name} is at capacity`)

	await ensureIpPool(node)
	const session = await createSessionWithLease({ user, device, node })

	await enqueueCommand({
		nodeId: node.id,
		sessionId: session.id,
		type: "ADD_PEER",
		payload: {
			sessionId: session.id,
			publicKey: device.publicKey,
			allowedIps: [`${session.assignedVpnIp}/32`],
		},
	})

	await prisma.device.update({
		where: { id: device.id },
		data: { lastSeen: new Date() },
	})

	await writeAudit({
		action: "vpn.connect",
		userId: user.id,
		deviceId: device.id,
		nodeId: node.id,
		ip: params.ip ?? null,
		metadata: { sessionId: session.id, assignedVpnIp: session.assignedVpnIp },
	})

	const wireguardPublicKey = node.wireguardPublicKey
	if (!wireguardPublicKey) {
		throw serviceUnavailable("Node has not published its WireGuard key yet")
	}

	// The gateway is optional on purpose: a node that has not been migrated yet
	// simply does not advertise one.
	const vlessUuid = config.VLESS_UUID.trim()
	const gateway = vlessUuid
		? {
				type: "vless" as const,
				host: config.VLESS_HOST.trim() || nodeHost(node),
				port: config.VLESS_PORT,
				uuid: vlessUuid,
				sni: config.VLESS_SNI.trim() || undefined,
				flow: config.VLESS_FLOW.trim() || undefined,
			}
		: undefined

	return {
		session,
		node,
		tunnel: {
			sessionId: session.id,
			// /32 keeps the client from claiming the whole tunnel subnet.
			interfaceAddress: `${session.assignedVpnIp}/32`,
			dns: node.dns.split(",").map((entry) => entry.trim()).filter(Boolean),
			mtu: node.mtu,
			peerPublicKey: wireguardPublicKey,
			endpoint: nodeEndpoint(node),
			allowedIps: ["0.0.0.0/0"],
			persistentKeepalive: 25,
			...(gateway ? { gateway } : {}),
		},
	}
}

/**
 * Closes a session and asks the node agent to remove the WireGuard peer.
 * The address lease is kept until the agent confirms removal (or until the
 * monitor reclaims it) so the same IP is never handed to two peers.
 */
export async function closeSession(params: {
	sessionId: string
	reason: string
	ip?: string | null
}): Promise<Session | null> {
	const session = await prisma.session.findUnique({
		where: { id: params.sessionId },
	})
	if (!session) return null
	if (session.status === "CLOSED" || session.status === "FAILED") return session

	const alreadyQueued = await hasOpenCommand({
		nodeId: session.nodeId,
		sessionId: session.id,
		type: "REMOVE_PEER",
	})
	if (!alreadyQueued) {
		await enqueueCommand({
			nodeId: session.nodeId,
			sessionId: session.id,
			type: "REMOVE_PEER",
			payload: {
				sessionId: session.id,
				publicKey: session.peerPublicKey,
			},
		})
	}

	const updated = await prisma.session.update({
		where: { id: session.id },
		data: {
			status: "CLOSED",
			disconnectedAt: new Date(),
			closeReason: params.reason,
		},
	})

	await writeAudit({
		action: "vpn.disconnect",
		userId: session.userId,
		deviceId: session.deviceId,
		nodeId: session.nodeId,
		ip: params.ip ?? null,
		metadata: { sessionId: session.id, reason: params.reason },
	})
	return updated
}

/** Releases the tunnel address back to the pool (after the peer is really gone). */
export async function releaseLease(sessionId: string): Promise<void> {
	await prisma.ipLease.updateMany({
		where: { sessionId },
		data: { sessionId: null, allocatedAt: null },
	})
}

export async function closeSessionsForDevice(
	deviceId: string,
	reason: string,
): Promise<number> {
	const sessions = await prisma.session.findMany({
		where: { deviceId, status: { in: [...ACTIVE_SESSION_STATES] } },
		select: { id: true },
	})
	for (const session of sessions) {
		await closeSession({ sessionId: session.id, reason })
	}
	return sessions.length
}

export async function closeSessionsForUser(
	userId: string,
	reason: string,
): Promise<number> {
	const sessions = await prisma.session.findMany({
		where: { userId, status: { in: [...ACTIVE_SESSION_STATES] } },
		select: { id: true },
	})
	for (const session of sessions) {
		await closeSession({ sessionId: session.id, reason })
	}
	return sessions.length
}

export async function closeSessionsForNode(
	nodeId: string,
	reason: string,
): Promise<number> {
	const sessions = await prisma.session.findMany({
		where: { nodeId, status: { in: [...ACTIVE_SESSION_STATES] } },
		select: { id: true },
	})
	for (const session of sessions) {
		await closeSession({ sessionId: session.id, reason })
	}
	return sessions.length
}

export async function findLiveSessionForDevice(
	deviceId: string,
): Promise<(Session & { node: VpnNode }) | null> {
	return prisma.session.findFirst({
		where: { deviceId, status: { in: [...ACTIVE_SESSION_STATES] } },
		include: { node: true },
		orderBy: { connectedAt: "desc" },
	})
}

export async function findLiveSessionsForUser(
	userId: string,
): Promise<Array<Session & { node: VpnNode }>> {
	return prisma.session.findMany({
		where: { userId, status: { in: [...ACTIVE_SESSION_STATES] } },
		include: { node: true },
		orderBy: { connectedAt: "desc" },
	})
}
