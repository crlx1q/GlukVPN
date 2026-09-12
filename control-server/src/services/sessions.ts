import { randomUUID } from "node:crypto"
import type { Device, Session, Subscription, User, VpnNode } from "@prisma/client"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { conflict, forbidden, notFound, serviceUnavailable } from "../lib/errors"
import { usableHostIps } from "../lib/ip"
import { effectiveSessionLimit } from "../lib/sessionLimit"
import { bytesToNumber, prisma } from "../prisma"
import { resolveEntitlement } from "./entitlements"
import { quotaStatusFor } from "./quota"
import { enqueueCommand, hasOpenCommand } from "./nodeCommands"
import {
	effectiveNodeStatus,
	isNodeConnectable,
	nodeEndpoint,
	nodeHost,
} from "./nodes"
import { requestPolicySync } from "./policy"
import { maintenanceError, requireVpnAvailable, SERVICE_GATE_LOCK } from "./serviceControl"
import { tunnelAllowedIps } from "./tunnelRoutes"

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
	/** WireGuard: last handshake. VLESS: last observed connection ("activity"). */
	lastHandshakeAt: string | null
	bytesRx: number
	bytesTx: number
	durationSec: number
	/** "wireguard" | "vless" — inferred from what the node actually saw. */
	transport: string
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
		transport: session.transport,
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

/**
 * The subscription that currently entitles a user: active, unexpired, and the
 * highest tier if several overlap (a Pro month bought on top of a Basic one).
 */
export async function activeSubscription(userId: string): Promise<Subscription | null> {
	return prisma.subscription.findFirst({
		where: { userId, status: "ACTIVE", expiresAt: { gt: new Date() } },
		orderBy: [{ tier: "desc" }, { expiresAt: "desc" }],
	})
}

export async function hasActiveSubscription(userId: string): Promise<boolean> {
	return (await activeSubscription(userId)) !== null
}

/** Human name for a tier gate, for error messages and the server list. */
export function tierLabel(tier: number): string {
	if (tier >= 2) return "Pro"
	if (tier === 1) return "Basic"
	return "Free"
}

async function pickNode(nodeId: string | null | undefined, tier: number): Promise<VpnNode> {
	if (nodeId) {
		const node = await prisma.vpnNode.findUnique({ where: { id: nodeId } })
		if (!node) throw notFound("Node not found")
		if (node.status === "DISABLED") throw forbidden("Node is disabled")
		if (node.maintenance) throw maintenanceError(node.id)
		if (node.tier > tier) {
			throw forbidden(`This server requires the ${tierLabel(node.tier)} plan`)
		}
		if (!node.wireguardPublicKey) {
			throw serviceUnavailable("Node has not published its WireGuard key yet")
		}
		if (effectiveNodeStatus(node) !== "ONLINE") {
			throw serviceUnavailable(`Node ${node.name} is offline`)
		}
		return node
	}

	// No explicit choice: least loaded online node the plan is allowed to use.
	const candidates = await prisma.vpnNode.findMany({
		where: {
			status: { not: "DISABLED" },
			wireguardPublicKey: { not: null },
			tier: { lte: tier },
		},
		orderBy: [{ activePeers: "asc" }],
	})
	const online = candidates.filter((node) => isNodeConnectable(node))
	const chosen = online[0]
	if (!chosen && candidates.some((node) => node.maintenance)) throw maintenanceError()
	if (!chosen) throw serviceUnavailable("No VPN node is currently available")
	return chosen
}

/**
 * Personal VLESS credential for a device. Devices registered before the column
 * existed get one the first time they connect; the node policy is re-synced
 * so sing-box knows the new user before the client reaches it.
 */
export async function ensureDeviceVlessUuid(device: Device): Promise<Device> {
	if (device.vlessUuid) return device
	const updated = await prisma.device.update({
		where: { id: device.id },
		data: { vlessUuid: randomUUID() },
	})
	await requestPolicySync().catch(() => 0)
	return updated
}

/** One sold speed and the node port whose token bucket enforces it. */
export type ShapedGatewayTier = { mbps: number; port: number }

/**
 * Parses VLESS_SHAPED_PORTS ("30=2053,100=2083") into tiers sorted by speed.
 *
 * The legacy ROUND 27 path: one externally reachable port per tier. Kept for
 * nodes still deployed that way, but new nodes route by SNI on 443 instead -
 * see parseSpeedTiers below for why. A malformed entry is dropped rather than
 * thrown on: a typo in .env must not stop the fleet from connecting, it only
 * means that one tier is not enforced at the gateway.
 */
export function parseShapedGatewayPorts(spec: string): ShapedGatewayTier[] {
	const seenSpeeds = new Set<number>()
	const tiers: ShapedGatewayTier[] = []
	for (const raw of spec.split(",")) {
		const entry = raw.trim()
		if (entry === "") continue
		const match = /^(\d{1,6})\s*=\s*(\d{1,5})$/.exec(entry)
		if (!match) continue
		const mbps = Number(match[1])
		const port = Number(match[2])
		if (mbps <= 0 || port < 1 || port > 65535) continue
		// Two ports for one speed would make this choice ambiguous. First wins,
		// the same way the agent resolves it.
		if (seenSpeeds.has(mbps)) continue
		seenSpeeds.add(mbps)
		tiers.push({ mbps, port })
	}
	return tiers.sort((a, b) => a.mbps - b.mbps)
}

/**
 * The shaped port for a device capped at `mbps`, or `null` for "use the node's
 * own gateway port".
 *
 * The fastest listener that still respects the cap wins. A cap below every
 * configured tier falls back to the slowest listener instead of to the
 * unshaped port: giving away more speed than was sold is the bug this exists
 * to fix, while a little less than the plan is merely a slow tunnel. No cap,
 * or no tiers configured, changes nothing.
 */
export function shapedGatewayPort(
	mbps: number | null | undefined,
	tiers: ShapedGatewayTier[],
): number | null {
	if (mbps == null || mbps <= 0) return null
	let withinCap: ShapedGatewayTier | null = null
	let slowest: ShapedGatewayTier | null = null
	for (const tier of tiers) {
		if (slowest === null || tier.mbps < slowest.mbps) slowest = tier
		if (tier.mbps <= mbps && (withinCap === null || tier.mbps > withinCap.mbps)) withinCap = tier
	}
	const picked = withinCap ?? slowest
	return picked === null ? null : picked.port
}

/**
 * Parses VLESS_SPEED_TIERS ("30,50,100,250,500") into speeds sorted ascending.
 *
 * These are the speeds the node shapes behind its nginx SNI map, and the
 * reason they carry no port: a tier used to be a port, every port except 443
 * is closed in the Oracle VCN, and a capped desktop client therefore timed out
 * instead of connecting slowly.
 */
export function parseSpeedTiers(spec: string): number[] {
	const speeds: number[] = []
	for (const raw of spec.split(",")) {
		const entry = raw.trim()
		if (entry === "") continue
		// The agent's "<mbps>=<port>" spelling is tolerated so an operator who
		// pastes SHAPING_GATEWAY_SPEEDS in here gets the speeds instead of
		// nothing. The port is ignored on purpose: routing by port is exactly
		// what this replaced.
		const match = /^(\d{1,6})(?:\s*=\s*\d{1,5})?$/.exec(entry)
		if (!match) continue
		const mbps = Number(match[1])
		if (mbps <= 0 || speeds.includes(mbps)) continue
		speeds.push(mbps)
	}
	return speeds.sort((a, b) => a - b)
}

/**
 * The gateway SNI for a device capped at `mbps`, or `null` for "use the node's
 * plain gateway name".
 *
 * Tier choice is deliberately the same rule as shapedGatewayPort: the fastest
 * listener that still respects the cap wins, and a cap below every tier falls
 * back to the slowest one rather than to the unshaped name. Handing out more
 * speed than was sold is the bug this exists to fix; a little less is merely a
 * slow tunnel.
 *
 * `null` is also the answer for a base name that cannot carry a label - a bare
 * IP, or a name with no dot - because prefixing one produces a host that
 * resolves nowhere, and a client that cannot resolve its gateway is offline
 * rather than throttled.
 */
export function speedGatewaySni(
	mbps: number | null | undefined,
	tiers: number[],
	baseSni: string,
	prefix = "speed",
): string | null {
	if (mbps == null || mbps <= 0) return null
	if (tiers.length === 0) return null
	const host = baseSni.trim().toLowerCase().replace(/\.$/, "")
	if (!host.includes(".")) return null
	if (host.includes(":") || /^[\d.]+$/.test(host)) return null
	if (!/^[a-z0-9.-]+$/.test(host)) return null

	let withinCap: number | null = null
	let slowest: number | null = null
	for (const tier of tiers) {
		if (slowest === null || tier < slowest) slowest = tier
		if (tier <= mbps && (withinCap === null || tier > withinCap)) withinCap = tier
	}
	const picked = withinCap ?? slowest
	if (picked === null) return null
	const label = prefix.trim().toLowerCase() || "speed"
	if (!/^[a-z0-9-]*$/.test(label)) return null
	return `${label}${picked}.${host}`
}

/**
 * The gateway clients should use on this node. Per-node values reported by the
 * agent win; the .env VLESS_* block is the fallback for a node whose agent
 * predates the heartbeat field. `null` = no gateway, the client uses WireGuard.
 *
 * `speedLimitMbps` is the cap the caller already resolved, and this is where it
 * turns into something the client cannot argue with. A capped device is sent to
 * the speed subdomain of its tier - speed30.de-01.gluk.tech - which nginx
 * `ssl_preread` maps to the loopback relay that enforces 30 Mbit/s. The port
 * stays 443 for everyone: it is the only port open in the cloud firewall, and
 * ROUND 27's per-tier ports are why a capped desktop could not connect at all.
 *
 * Only the name moves. Port, credential, flow and the sing-box behind the relay
 * are the same for every tier, and the whole decision is made here, on the
 * server, from the plan in the database.
 */
export function gatewayFor(
	node: VpnNode,
	device: Device,
	speedLimitMbps?: number | null,
): ClientTunnelConfig["gateway"] | null {
	const uuid = (device.vlessUuid ?? config.VLESS_UUID).trim()
	if (!uuid) return null
	const speedTiers = parseSpeedTiers(config.VLESS_SPEED_TIERS)
	// The legacy port hop only runs while no speed subdomain is configured: the
	// two cannot both be right, because an SNI-routed client has to stay on the
	// port nginx is listening on.
	const legacyShapedPort = (): number | null =>
		shapedGatewayPort(speedLimitMbps, parseShapedGatewayPorts(config.VLESS_SHAPED_PORTS))

	if (node.gatewayHost && node.gatewayPort) {
		// The certificate is issued for the TLS name, so the speed label goes on
		// the SNI the node reported - falling back to the host when it matches.
		const shapedSni = speedGatewaySni(
			speedLimitMbps,
			speedTiers,
			node.gatewaySni ?? node.gatewayHost,
			config.VLESS_SPEED_SNI_PREFIX,
		)
		return {
			type: "vless",
			// The speed subdomain is an A record onto the same address, so this
			// dials the same node - only the SNI nginx routes on differs.
			host: shapedSni ?? node.gatewayHost,
			port: shapedSni ? node.gatewayPort : (legacyShapedPort() ?? node.gatewayPort),
			uuid,
			sni: shapedSni ?? node.gatewaySni ?? undefined,
			flow: (node.gatewayFlow ?? config.VLESS_FLOW).trim() || undefined,
		}
	}
	// Legacy fallback: one gateway for the fleet, configured in .env. Only when
	// the operator actually filled it in (VLESS_UUID is the historical switch).
	if (!config.VLESS_UUID.trim()) return null
	const host = config.VLESS_HOST.trim() || nodeHost(node)
	const sni = config.VLESS_SNI.trim()
	const legacySpeedSni = speedGatewaySni(
		speedLimitMbps,
		speedTiers,
		sni || host,
		config.VLESS_SPEED_SNI_PREFIX,
	)
	return {
		type: "vless",
		host: legacySpeedSni ?? host,
		port: legacySpeedSni ? config.VLESS_PORT : (legacyShapedPort() ?? config.VLESS_PORT),
		uuid,
		sni: legacySpeedSni ?? (sni || undefined),
		flow: config.VLESS_FLOW.trim() || undefined,
	}
}

/**
 * Allocates a free tunnel IP and creates the session row atomically, so two
 * parallel connects can never receive the same address.
 *
 * `plan` is the entitlement the caller already resolved. It is passed in rather
 * than looked up again because Free is the *absence* of a subscription: a
 * second lookup inside the gate finds no row for a Free account and used to
 * reject it outright.
 */
async function createSessionWithLease(params: {
	user: User
	device: Device
	node: VpnNode
	plan: { tier: number; maxSessions: number; speedMbps: number | null; speedPriority: number }
}): Promise<Session> {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		try {
			return await prisma.$transaction(async (tx) => {
				await tx.$queryRaw`SELECT pg_advisory_xact_lock_shared(${SERVICE_GATE_LOCK})::text`
				await tx.$queryRaw`SELECT id FROM users WHERE id = ${params.user.id}::uuid FOR UPDATE`
				await tx.$queryRaw`SELECT id FROM vpn_nodes WHERE id = ${params.node.id}::uuid FOR UPDATE`
				const [currentUser, currentDevice, currentNode] = await Promise.all([
					tx.user.findUnique({ where: { id: params.user.id } }),
					tx.device.findUnique({ where: { id: params.device.id } }),
					tx.vpnNode.findUnique({ where: { id: params.node.id } }),
				])
				if (!currentUser || currentUser.status !== "ACTIVE") throw forbidden("User is disabled")
				if (!currentDevice || currentDevice.status !== "ACTIVE" || currentDevice.tokenVersion !== params.device.tokenVersion) throw forbidden("Device is revoked")
				if (!currentNode) throw serviceUnavailable("Node is unavailable")
				// Tier gate only. There is no subscription to re-check here: a Free
				// account has no row, and demanding one is exactly what made every
				// Free connect fail with "No eligible subscription or node".
				if (params.plan.tier < currentNode.tier) throw forbidden(`This server requires ${tierLabel(currentNode.tier)}`)
				await requireVpnAvailable(currentNode, tx)
				if (!isNodeConnectable(currentNode)) throw serviceUnavailable("Node is unavailable")
				const allowed = Math.max(effectiveSessionLimit(currentUser), params.plan.maxSessions)
				if (await tx.session.count({ where: { userId: currentUser.id, status: { in: [...ACTIVE_SESSION_STATES] } } }) >= allowed) throw conflict("Maximum concurrent sessions reached. Disconnect another device first.")
				if (await tx.session.count({ where: { deviceId: currentDevice.id, status: { in: [...ACTIVE_SESSION_STATES] } } })) throw conflict("A connection is already being established for this device. Please retry.")
				if (await tx.session.count({ where: { nodeId: currentNode.id, status: { in: [...ACTIVE_SESSION_STATES] } } }) >= currentNode.capacity) throw conflict("Node is at capacity")
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
				// Queue inside the gate: a late ADD_PEER cannot follow maintenance's REMOVE_PEER.
				await tx.nodeCommand.create({ data: {
					nodeId: params.node.id, sessionId: session.id, type: "ADD_PEER",
					payload: {
						sessionId: session.id,
						publicKey: params.device.publicKey,
						deviceId: params.device.id,
						allowedIps: [`${session.assignedVpnIp}/32`],
						// What the node should shape this peer to. `null` travels as an
						// explicit "unshaped" so the agent never has to guess a default,
						// and an older agent simply ignores the field.
						shaping: { speedMbps: params.plan.speedMbps, priority: params.plan.speedPriority },
					},
				} })
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
	const { user } = params
	await requireVpnAvailable()

	if (user.status !== "ACTIVE") throw forbidden("User is disabled")
	if (params.device.status !== "ACTIVE") throw forbidden("Device is revoked")
	// Free is not a subscription: an account without one still connects, at tier 0
	// and with the Free device/session limits. The server resolves the plan, the
	// client never states it.
	const entitlement = await resolveEntitlement(user.id)

	// The monthly allowance is counted by the nodes, added up by the server and
	// enforced here: once it is spent there is no new tunnel until the window
	// resets. The client is told which window, so it can say "resumes on ..."
	// instead of retrying blindly - and it cannot talk its way past this by
	// reporting different numbers, because it reports none.
	const quota = await quotaStatusFor(user.id, entitlement)
	if (quota.exceeded && quota.limitBytes !== null) {
		const gb = Math.round((quota.limitBytes / (1024 * 1024 * 1024)) * 10) / 10
		throw forbidden(
			`Monthly traffic limit reached (${gb} GB). The allowance resets ${quota.period.end.toISOString()}.`,
		)
	}

	const device = await ensureDeviceVlessUuid(params.device)

	// A device may hold only one live session: reconnecting replaces the old one.
	const previous = await prisma.session.findMany({
		where: { deviceId: device.id, status: { in: [...ACTIVE_SESSION_STATES] } },
	})
	for (const session of previous) {
		await closeSession({ sessionId: session.id, reason: "reconnect" })
	}

	const planSessions = entitlement.maxSessions
	const maxSessions = Math.max(effectiveSessionLimit(user), planSessions)
	const liveSessions = await prisma.session.count({
		where: { userId: user.id, status: { in: [...ACTIVE_SESSION_STATES] } },
	})
	if (liveSessions >= maxSessions) {
		throw conflict(
			`Maximum concurrent sessions reached (${maxSessions}). Disconnect another device first.`,
		)
	}

	const node = await pickNode(params.nodeId ?? null, entitlement.tier)
	const nodeLive = await prisma.session.count({
		where: { nodeId: node.id, status: { in: [...ACTIVE_SESSION_STATES] } },
	})
	if (nodeLive >= node.capacity) throw conflict(`Node ${node.name} is at capacity`)

	await ensureIpPool(node)
	const created = await createSessionWithLease({
		user,
		device,
		node,
		plan: {
			tier: entitlement.tier,
			maxSessions: entitlement.maxSessions,
			speedMbps: entitlement.speedLimitMbps,
			speedPriority: entitlement.speedPriority,
		},
	})
	const session = params.ip
		? await prisma.session.update({
				where: { id: created.id },
				data: { clientIp: params.ip },
			})
		: created

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
	// simply does not advertise one. The credential is the device's own, and the
	// port is the one that enforces this plan's speed once shaping is wired up.
	const gateway = gatewayFor(node, device, entitlement.speedLimitMbps) ?? undefined
	await requireVpnAvailable(await prisma.vpnNode.findUnique({ where: { id: node.id } }))
	const current = await prisma.session.findUnique({ where: { id: session.id }, select: { status: true } })
	if (!current || (current.status !== "PENDING" && current.status !== "ACTIVE")) throw forbidden("This session was closed. Connect again.")

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
			// Everything except the control-plane addresses. A revoked peer must
			// not blind the client: it still has to be able to ask the server why
			// the tunnel went quiet, otherwise the UI can only guess by timeout.
			allowedIps: tunnelAllowedIps(config.TUNNEL_BYPASS_IPS),
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
				deviceId: session.deviceId,
				// The agent needs the address to drop the traffic-shaping class it
				// created for this peer; without it the class lingers until the same
				// IP is leased again.
				assignedVpnIp: session.assignedVpnIp,
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
