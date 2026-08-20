import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { generateSecret, hashSecret } from "../lib/crypto"
import { badRequest, conflict, notFound, unauthorized } from "../lib/errors"
import { gatewayIp, ipToInt, parseCidr } from "../lib/ip"
import { wireGuardKeySchema } from "../lib/wg"
import { clientIp, getAuthNode, requireNode } from "../middleware/auth"
import { prisma } from "../prisma"
import { claimPendingCommands, completeCommand } from "../services/nodeCommands"
import { ensureIpPool, releaseLease } from "../services/sessions"

const ipv4 = z.string().trim().refine((value) => {
	try {
		ipToInt(value)
		return true
	} catch {
		return false
	}
}, "Must be an IPv4 address")

const RegisterBody = z.object({
	// One-time enrollment token, issued by the admin CLI.
	enrollmentToken: z.string().min(16).max(400),
	name: z
		.string()
		.trim()
		.min(2)
		.max(40)
		.regex(/^[a-z0-9][a-z0-9-]*$/i, "Use letters, digits and dashes"),
	country: z.string().trim().min(2).max(60),
	countryCode: z.string().trim().length(2),
	// User-facing geography: the app renders these, never the node name.
	region: z.string().trim().max(80).optional(),
	city: z.string().trim().max(80).optional(),
	// Optional latency target; falls back to the node's public host.
	pingTarget: z.string().trim().max(255).optional(),
	hostname: z.string().trim().min(1).max(255),
	publicIp: ipv4,
	wireguardPublicKey: wireGuardKeySchema,
	wireguardPort: z.coerce.number().int().min(1).max(65535).default(51820),
	subnetCidr: z.string().trim().default("10.8.0.0/24"),
	dns: z.string().trim().max(120).default("1.1.1.1,1.0.0.1"),
	mtu: z.coerce.number().int().min(1280).max(1500).default(1420),
	capacity: z.coerce.number().int().min(1).max(1000).default(50),
	agentVersion: z.string().trim().max(30).optional(),
})

const HeartbeatBody = z
	.object({
		cpuPercent: z.coerce.number().min(0).max(100).optional(),
		ramPercent: z.coerce.number().min(0).max(100).optional(),
		uptimeSeconds: z.coerce.number().int().min(0).optional(),
		peerCount: z.coerce.number().int().min(0).max(10000).optional(),
		agentVersion: z.string().trim().max(30).optional(),
		wireguardPublicKey: wireGuardKeySchema.optional(),
	})
	.optional()

const ReportBody = z.object({
	peers: z
		.array(
			z.object({
				publicKey: wireGuardKeySchema,
				// Byte counters only. No URLs, no payloads, no DPI.
				bytesRx: z.coerce.number().int().min(0),
				bytesTx: z.coerce.number().int().min(0),
				lastHandshakeAt: z.string().datetime().nullable().optional(),
			}),
		)
		.max(1000),
})

const AckParams = z.object({ id: z.string().uuid("Invalid command id") })
const AckBody = z.object({
	ok: z.boolean(),
	error: z.string().max(300).optional(),
})

export async function nodeAgentRoutes(app: FastifyInstance): Promise<void> {
	/**
	 * Node enrollment: exchanges a one-time enrollment token for a per-node
	 * credential. The control server stores only the HMAC of that credential.
	 */
	app.post(
		"/api/node/register",
		{ config: { rateLimit: { max: 10, timeWindow: "10 minutes" } } },
		async (request, reply) => {
			const parsed = RegisterBody.safeParse(request.body)
			if (!parsed.success) {
				throw badRequest("Invalid node payload", parsed.error.flatten().fieldErrors)
			}
			const body = parsed.data
			const ip = clientIp(request)
			// Validates the prefix and throws a 400 for nonsense subnets.
			parseCidr(body.subnetCidr)

			const enrollment = await prisma.nodeEnrollmentToken.findUnique({
				where: { tokenHash: hashSecret(body.enrollmentToken) },
			})
			if (!enrollment) {
				await writeAudit({
					action: "node.register.rejected",
					ip,
					metadata: { reason: "unknown_enrollment_token", name: body.name },
				})
				throw unauthorized("Invalid enrollment token")
			}
			if (enrollment.usedAt) throw unauthorized("Enrollment token already used")
			if (enrollment.expiresAt.getTime() <= Date.now()) {
				throw unauthorized("Enrollment token expired")
			}

			// A node key must never collide with a device key.
			const deviceWithSameKey = await prisma.device.findUnique({
				where: { publicKey: body.wireguardPublicKey },
				select: { id: true },
			})
			if (deviceWithSameKey) throw badRequest("This key is already used by a device")

			const existing = await prisma.vpnNode.findUnique({ where: { name: body.name } })
			if (existing) {
				const allocated = await prisma.ipLease.count({
					where: { nodeId: existing.id, sessionId: { not: null } },
				})
				if (allocated > 0 && existing.subnetCidr !== body.subnetCidr) {
					throw conflict(
						"Node has active address leases; disconnect sessions before changing the subnet",
					)
				}
			}

			const now = new Date()
			const node = existing
				? await prisma.vpnNode.update({
						where: { id: existing.id },
						data: {
							country: body.country,
							countryCode: body.countryCode.toUpperCase(),
							// Absent fields keep whatever an operator set by hand.
							region: body.region ?? existing.region,
							city: body.city ?? existing.city,
							pingTarget: body.pingTarget ?? existing.pingTarget,
							hostname: body.hostname,
							publicIp: body.publicIp,
							wireguardPublicKey: body.wireguardPublicKey,
							wireguardPort: body.wireguardPort,
							subnetCidr: body.subnetCidr,
							dns: body.dns,
							mtu: body.mtu,
							capacity: body.capacity,
							agentVersion: body.agentVersion ?? existing.agentVersion,
							// Re-enrolling a disabled node does not silently re-enable it.
							status: existing.status === "DISABLED" ? "DISABLED" : "ONLINE",
							lastHeartbeat: now,
						},
					})
				: await prisma.vpnNode.create({
						data: {
							name: body.name,
							country: body.country,
							countryCode: body.countryCode.toUpperCase(),
							region: body.region ?? null,
							city: body.city ?? null,
							pingTarget: body.pingTarget ?? null,
							hostname: body.hostname,
							publicIp: body.publicIp,
							wireguardPublicKey: body.wireguardPublicKey,
							wireguardPort: body.wireguardPort,
							subnetCidr: body.subnetCidr,
							dns: body.dns,
							mtu: body.mtu,
							capacity: body.capacity,
							agentVersion: body.agentVersion ?? null,
							status: "ONLINE",
							lastHeartbeat: now,
						},
					})

			const rawToken = generateSecret(32)
			const expiresAt = new Date(
				Date.now() + config.NODE_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000,
			)
			await prisma.nodeToken.create({
				data: {
					nodeId: node.id,
					tokenHash: hashSecret(rawToken),
					label: "enrollment",
					expiresAt,
				},
			})
			await prisma.nodeEnrollmentToken.update({
				where: { id: enrollment.id },
				data: { usedAt: now, usedByNodeId: node.id },
			})
			await ensureIpPool(node)

			await writeAudit({
				action: existing ? "node.reregister" : "node.register",
				nodeId: node.id,
				ip,
				metadata: {
					name: node.name,
					country: node.country,
					city: node.city,
				},
			})

			const { prefix } = parseCidr(node.subnetCidr)
			return reply.code(201).send({
				nodeId: node.id,
				// Returned exactly once. The agent stores it in /etc/vpn-node-agent/agent.env (0600).
				nodeToken: rawToken,
				nodeTokenExpiresAt: expiresAt.toISOString(),
				heartbeatIntervalSec: config.NODE_HEARTBEAT_INTERVAL_SEC,
				offlineAfterSec: config.NODE_OFFLINE_AFTER_SEC,
				wireguard: {
					interfaceAddress: `${gatewayIp(node.subnetCidr)}/${prefix}`,
					subnetCidr: node.subnetCidr,
					listenPort: node.wireguardPort,
					mtu: node.mtu,
					dns: node.dns,
				},
			})
		},
	)

	/** Heartbeat doubles as the command poll: no inbound port is needed on the node. */
	app.post(
		"/api/node/heartbeat",
		{
			preHandler: requireNode,
			config: { rateLimit: { max: 120, timeWindow: "1 minute" } },
		},
		async (request, reply) => {
			const parsed = HeartbeatBody.safeParse(request.body ?? {})
			if (!parsed.success) throw badRequest("Invalid heartbeat payload")
			const { node, tokenId } = getAuthNode(request)
			const body = parsed.data ?? {}

			const updated = await prisma.vpnNode.update({
				where: { id: node.id },
				data: {
					lastHeartbeat: new Date(),
					status: node.status === "DISABLED" ? "DISABLED" : "ONLINE",
					cpuPercent: body.cpuPercent ?? node.cpuPercent,
					ramPercent: body.ramPercent ?? node.ramPercent,
					uptimeSeconds: body.uptimeSeconds ?? node.uptimeSeconds,
					activePeers: body.peerCount ?? node.activePeers,
					agentVersion: body.agentVersion ?? node.agentVersion,
					wireguardPublicKey: body.wireguardPublicKey ?? node.wireguardPublicKey,
				},
			})

			// Successful use of a token retires every older token of this node,
			// which makes rotation safe: the old token dies only once the new one works.
			await prisma.nodeToken.updateMany({
				where: { nodeId: node.id, id: { not: tokenId }, revokedAt: null },
				data: { revokedAt: new Date() },
			})

			const token = await prisma.nodeToken.findUnique({ where: { id: tokenId } })
			// A disabled node still gets its REMOVE_PEER commands, but never new peers.
			const commands = await claimPendingCommands(node.id, 10)

			return reply.send({
				ok: true,
				serverTime: new Date().toISOString(),
				nodeStatus: updated.status,
				heartbeatIntervalSec: config.NODE_HEARTBEAT_INTERVAL_SEC,
				nodeTokenExpiresAt: token?.expiresAt.toISOString() ?? null,
				commands: commands.map((command) => ({
					id: command.id,
					type: command.type,
					payload: command.payload,
				})),
			})
		},
	)

	/** Peer state + WireGuard byte counters. */
	app.post(
		"/api/node/report",
		{
			preHandler: requireNode,
			config: { rateLimit: { max: 60, timeWindow: "1 minute" } },
		},
		async (request, reply) => {
			const parsed = ReportBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("Invalid report payload")
			const { node } = getAuthNode(request)
			const { peers } = parsed.data

			const liveSessions = await prisma.session.findMany({
				where: { nodeId: node.id, status: { in: ["PENDING", "ACTIVE"] } },
			})
			const byKey = new Map(liveSessions.map((session) => [session.peerPublicKey, session]))
			const reportedKeys = new Set(peers.map((peer) => peer.publicKey))
			const unknownPeers: string[] = []

			for (const peer of peers) {
				const session = byKey.get(peer.publicKey)
				if (!session) {
					// Drift: a peer exists on the node with no live session behind it.
					unknownPeers.push(peer.publicKey)
					continue
				}
				const bytesRx = BigInt(peer.bytesRx)
				const bytesTx = BigInt(peer.bytesTx)
				await prisma.session.update({
					where: { id: session.id },
					data: {
						// Counters only move forward.
						bytesRx: bytesRx > session.bytesRx ? bytesRx : session.bytesRx,
						bytesTx: bytesTx > session.bytesTx ? bytesTx : session.bytesTx,
						lastHandshakeAt: peer.lastHandshakeAt
							? new Date(peer.lastHandshakeAt)
							: session.lastHandshakeAt,
					},
				})
				if (peer.lastHandshakeAt) {
					await prisma.device.update({
						where: { id: session.deviceId },
						data: { lastSeen: new Date(peer.lastHandshakeAt) },
					})
				}
			}

			// Sessions the control plane believes are live but the node has no peer for.
			const missingPeers = liveSessions
				.filter((session) => !reportedKeys.has(session.peerPublicKey))
				.map((session) => ({ sessionId: session.id, publicKey: session.peerPublicKey }))

			await prisma.vpnNode.update({
				where: { id: node.id },
				data: { activePeers: peers.length, lastHeartbeat: new Date() },
			})

			return reply.send({
				ok: true,
				// The agent removes these keys; peers are never created here.
				removePeers: unknownPeers,
				missingPeers,
			})
		},
	)

	/** Command acknowledgement: drives the session state machine. */
	app.post(
		"/api/node/commands/:id/ack",
		{
			preHandler: requireNode,
			config: { rateLimit: { max: 120, timeWindow: "1 minute" } },
		},
		async (request, reply) => {
			const params = AckParams.safeParse(request.params)
			if (!params.success) throw badRequest("Invalid command id")
			const body = AckBody.safeParse(request.body)
			if (!body.success) throw badRequest("Invalid ack payload")
			const { node } = getAuthNode(request)

			const command = await completeCommand({
				commandId: params.data.id,
				nodeId: node.id,
				ok: body.data.ok,
				result: body.data.error ? { error: body.data.error } : { ok: body.data.ok },
			})
			if (!command) throw notFound("Command not found")

			if (command.sessionId) {
				if (command.type === "ADD_PEER") {
					if (body.data.ok) {
						await prisma.session.updateMany({
							where: { id: command.sessionId, status: "PENDING" },
							data: { status: "ACTIVE" },
						})
					} else {
						await prisma.session.updateMany({
							where: { id: command.sessionId, status: "PENDING" },
							data: {
								status: "FAILED",
								disconnectedAt: new Date(),
								closeReason: "peer_add_failed",
							},
						})
						await releaseLease(command.sessionId)
					}
				}
				if (command.type === "REMOVE_PEER" && body.data.ok) {
					// The peer is really gone: the tunnel IP can be reused now.
					await releaseLease(command.sessionId)
				}
			}

			await writeAudit({
				action: `node.command.${body.data.ok ? "done" : "failed"}`,
				nodeId: node.id,
				ip: clientIp(request),
				metadata: {
					commandId: command.id,
					type: command.type,
					sessionId: command.sessionId,
					error: body.data.error ?? null,
				},
			})
			return reply.send({ ok: true })
		},
	)

	/** Voluntary credential rotation. The old token stays valid until the new one is used. */
	app.post(
		"/api/node/token/rotate",
		{
			preHandler: requireNode,
			config: { rateLimit: { max: 5, timeWindow: "1 hour" } },
		},
		async (request, reply) => {
			const { node } = getAuthNode(request)
			const rawToken = generateSecret(32)
			const expiresAt = new Date(
				Date.now() + config.NODE_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000,
			)
			await prisma.nodeToken.create({
				data: {
					nodeId: node.id,
					tokenHash: hashSecret(rawToken),
					label: "rotation",
					expiresAt,
				},
			})
			await writeAudit({
				action: "node.token.rotate",
				nodeId: node.id,
				ip: clientIp(request),
			})
			return reply.send({
				nodeToken: rawToken,
				nodeTokenExpiresAt: expiresAt.toISOString(),
				note: "Store this token, then send the next heartbeat with it. Older tokens are retired automatically.",
			})
		},
	)
}
