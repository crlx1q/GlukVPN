import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { generateSecret, hashPassword, hashSecret } from "../lib/crypto"
import { badRequest, conflict, notFound } from "../lib/errors"
import { clientIp, getAuthUser, requireAdmin } from "../middleware/auth"
import { bytesToNumber, prisma } from "../prisma"
import { effectiveNodeStatus, nodeEndpoint, nodeLoadPercent } from "../services/nodes"
import {
	closeSessionsForDevice,
	closeSessionsForNode,
	closeSessionsForUser,
} from "../services/sessions"
import { revokeRefreshTokens } from "../services/tokens"

const IdParams = z.object({ id: z.string().uuid("Invalid id") })

const CreateUserBody = z.object({
	username: z
		.string()
		.trim()
		.min(3)
		.max(32)
		.regex(/^[a-z0-9._@-]+$/i, "Use letters, digits, dot, dash, at-sign or underscore"),
	password: z.string().min(8).max(200),
	isAdmin: z.boolean().default(false),
	maxDevices: z.coerce.number().int().min(1).max(20).optional(),
	subscriptionDays: z.coerce.number().int().min(1).max(3650).default(365),
})

const EnrollmentTokenBody = z
	.object({ note: z.string().trim().max(120).optional() })
	.optional()

/** Free-text search over the public account number and the nickname. */
const ListUsersQuery = z
	.object({ q: z.string().trim().max(64).optional() })
	.optional()

export async function adminRoutes(app: FastifyInstance): Promise<void> {
	// Everything below requires an admin user token.
	app.addHook("preHandler", requireAdmin)

	app.get("/api/admin/overview", async (_request, reply) => {
		const [users, activeUsers, devices, activeDevices, nodes, liveSessions] =
			await Promise.all([
				prisma.user.count(),
				prisma.user.count({ where: { status: "ACTIVE" } }),
				prisma.device.count(),
				prisma.device.count({ where: { status: "ACTIVE" } }),
				prisma.vpnNode.findMany(),
				prisma.session.count({ where: { status: { in: ["PENDING", "ACTIVE"] } } }),
			])

		const traffic = await prisma.session.aggregate({
			_sum: { bytesRx: true, bytesTx: true },
		})

		return reply.send({
			users: { total: users, active: activeUsers },
			devices: { total: devices, active: activeDevices },
			nodes: {
				total: nodes.length,
				online: nodes.filter((node) => effectiveNodeStatus(node) === "ONLINE").length,
			},
			sessions: { live: liveSessions },
			traffic: {
				bytesRx: bytesToNumber(traffic._sum.bytesRx),
				bytesTx: bytesToNumber(traffic._sum.bytesTx),
			},
			offlineAfterSec: config.NODE_OFFLINE_AFTER_SEC,
			serverTime: new Date().toISOString(),
		})
	})

	app.get("/api/admin/nodes", async (_request, reply) => {
		const nodes = await prisma.vpnNode.findMany({ orderBy: { name: "asc" } })
		const items = await Promise.all(
			nodes.map(async (node) => {
				const [liveSessions, traffic, allocatedLeases] = await Promise.all([
					prisma.session.count({
						where: { nodeId: node.id, status: { in: ["PENDING", "ACTIVE"] } },
					}),
					prisma.session.aggregate({
						where: { nodeId: node.id },
						_sum: { bytesRx: true, bytesTx: true },
					}),
					prisma.ipLease.count({ where: { nodeId: node.id, sessionId: { not: null } } }),
				])
				return {
					id: node.id,
					name: node.name,
					country: node.country,
					countryCode: node.countryCode,
					endpoint: nodeEndpoint(node),
					publicIp: node.publicIp,
					storedStatus: node.status,
					status: effectiveNodeStatus(node),
					loadPercent: nodeLoadPercent(node),
					capacity: node.capacity,
					activePeers: node.activePeers,
					cpuPercent: node.cpuPercent,
					ramPercent: node.ramPercent,
					uptimeSeconds: node.uptimeSeconds,
					agentVersion: node.agentVersion,
					subnetCidr: node.subnetCidr,
					lastHeartbeat: node.lastHeartbeat?.toISOString() ?? null,
					liveSessions,
					allocatedLeases,
					bytesRx: bytesToNumber(traffic._sum.bytesRx),
					bytesTx: bytesToNumber(traffic._sum.bytesTx),
				}
			}),
		)
		return reply.send({ nodes: items })
	})

	/** One-time enrollment token for a new node agent. Returned once, stored hashed. */
	app.post("/api/admin/nodes/enrollment-token", async (request, reply) => {
		const parsed = EnrollmentTokenBody.safeParse(request.body ?? {})
		if (!parsed.success) throw badRequest("Invalid payload")
		const { user } = getAuthUser(request)

		const rawToken = generateSecret(32)
		const expiresAt = new Date(
			Date.now() + config.NODE_ENROLLMENT_TOKEN_TTL_MIN * 60 * 1000,
		)
		await prisma.nodeEnrollmentToken.create({
			data: {
				tokenHash: hashSecret(rawToken),
				note: parsed.data?.note ?? null,
				expiresAt,
			},
		})
		await writeAudit({
			action: "admin.node.enrollment_token.create",
			userId: user.id,
			ip: clientIp(request),
			metadata: { note: parsed.data?.note ?? null },
		})
		return reply.code(201).send({
			enrollmentToken: rawToken,
			expiresAt: expiresAt.toISOString(),
			note: "Shown once. Put it in NODE_ENROLLMENT_TOKEN on the node and run the enroll script.",
		})
	})

	app.post("/api/admin/nodes/:id/disable", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid node id")
		const { user } = getAuthUser(request)

		const node = await prisma.vpnNode.findUnique({ where: { id: parsed.data.id } })
		if (!node) throw notFound("Node not found")

		// Existing tunnels are torn down: REMOVE_PEER is queued for each session.
		const closedSessions = await closeSessionsForNode(node.id, "node_disabled")
		await prisma.vpnNode.update({
			where: { id: node.id },
			data: { status: "DISABLED" },
		})
		await writeAudit({
			action: "admin.node.disable",
			userId: user.id,
			nodeId: node.id,
			ip: clientIp(request),
			metadata: { closedSessions },
		})
		return reply.send({ ok: true, closedSessions })
	})

	app.post("/api/admin/nodes/:id/enable", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid node id")
		const { user } = getAuthUser(request)

		const node = await prisma.vpnNode.findUnique({ where: { id: parsed.data.id } })
		if (!node) throw notFound("Node not found")

		const updated = await prisma.vpnNode.update({
			where: { id: node.id },
			// The next heartbeat flips it to ONLINE.
			data: { status: node.lastHeartbeat ? "OFFLINE" : "PENDING" },
		})
		await writeAudit({
			action: "admin.node.enable",
			userId: user.id,
			nodeId: node.id,
			ip: clientIp(request),
		})
		return reply.send({ ok: true, status: updated.status })
	})

	/** Removes a node from the registry. Sessions are closed first. */
	app.delete("/api/admin/nodes/:id", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid node id")
		const { user } = getAuthUser(request)

		const node = await prisma.vpnNode.findUnique({ where: { id: parsed.data.id } })
		if (!node) throw notFound("Node not found")

		const live = await prisma.session.count({
			where: { nodeId: node.id, status: { in: ["PENDING", "ACTIVE"] } },
		})
		if (live > 0) {
			throw conflict(
				`Node still has ${live} live session(s). Disable it first, then delete.`,
			)
		}

		await prisma.nodeToken.updateMany({
			where: { nodeId: node.id, revokedAt: null },
			data: { revokedAt: new Date() },
		})
		await prisma.vpnNode.delete({ where: { id: node.id } })
		await writeAudit({
			action: "admin.node.delete",
			userId: user.id,
			ip: clientIp(request),
			metadata: { nodeName: node.name },
		})
		return reply.send({ ok: true })
	})

	app.get("/api/admin/users", async (request, reply) => {
		const parsedQuery = ListUsersQuery.safeParse(request.query ?? {})
		const term = parsedQuery.success ? (parsedQuery.data?.q ?? "").trim() : ""
		// "00000042", "42" and "alex" all work: digits match the account number,
		// text matches the nickname. Prefer the number when banning — a nickname
		// can be changed by the user at any moment, the number cannot.
		const digits = term.replace(/\D/g, "")
		const where = term
			? {
					OR: [
						{ username: { contains: term, mode: "insensitive" as const } },
						...(digits.length > 0 ? [{ publicId: { contains: digits } }] : []),
					],
				}
			: {}

		const users = await prisma.user.findMany({
			where,
			orderBy: { createdAt: "asc" },
			include: {
				subscriptions: { orderBy: { expiresAt: "desc" }, take: 1 },
				_count: { select: { devices: true, sessions: true } },
			},
		})
		const items = await Promise.all(
			users.map(async (user) => {
				const liveSessions = await prisma.session.count({
					where: { userId: user.id, status: { in: ["PENDING", "ACTIVE"] } },
				})
				const subscription = user.subscriptions[0] ?? null
				return {
					id: user.id,
					publicId: user.publicId,
					username: user.username,
					status: user.status,
					isAdmin: user.isAdmin,
					maxDevices: user.maxDevices,
					maxSessions: user.maxSessions,
					devices: user._count.devices,
					sessionsTotal: user._count.sessions,
					liveSessions,
					subscription: subscription
						? {
								status: subscription.status,
								expiresAt: subscription.expiresAt.toISOString(),
							}
						: null,
					createdAt: user.createdAt.toISOString(),
				}
			}),
		)
		return reply.send({ users: items })
	})

	app.post("/api/admin/users", async (request, reply) => {
		const parsed = CreateUserBody.safeParse(request.body)
		if (!parsed.success) {
			throw badRequest("Invalid user payload", parsed.error.flatten().fieldErrors)
		}
		const { user: admin } = getAuthUser(request)
		const body = parsed.data

		const existing = await prisma.user.findUnique({ where: { username: body.username } })
		if (existing) throw conflict("Username already exists")

		const created = await prisma.user.create({
			data: {
				username: body.username,
				passwordHash: await hashPassword(body.password),
				isAdmin: body.isAdmin,
				maxDevices: body.maxDevices ?? config.MAX_DEVICES_PER_USER,
				maxSessions: config.MAX_CONCURRENT_SESSIONS,
				subscriptions: {
					create: {
						plan: "test",
						status: "ACTIVE",
						expiresAt: new Date(
							Date.now() + body.subscriptionDays * 24 * 60 * 60 * 1000,
						),
					},
				},
			},
		})
		// The password itself is never logged or audited.
		await writeAudit({
			action: "admin.user.create",
			userId: admin.id,
			ip: clientIp(request),
			metadata: {
				createdUserId: created.id,
				publicId: created.publicId,
				username: created.username,
			},
		})
		return reply.code(201).send({
			user: {
				id: created.id,
				publicId: created.publicId,
				username: created.username,
				status: created.status,
			},
		})
	})

	app.post("/api/admin/users/:id/disable", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const { user: admin } = getAuthUser(request)

		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")
		if (target.id === admin.id) throw conflict("You cannot disable your own account")

		// Disable -> tunnels down, refresh tokens dead, new logins refused.
		const closedSessions = await closeSessionsForUser(target.id, "user_disabled")
		await prisma.user.update({
			where: { id: target.id },
			data: { status: "DISABLED" },
		})
		const revokedTokens = await revokeRefreshTokens({ userId: target.id })
		await writeAudit({
			action: "admin.user.disable",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { targetUserId: target.id, closedSessions, revokedTokens },
		})
		return reply.send({ ok: true, closedSessions, revokedTokens })
	})

	app.post("/api/admin/users/:id/enable", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const { user: admin } = getAuthUser(request)

		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")

		await prisma.user.update({ where: { id: target.id }, data: { status: "ACTIVE" } })
		await writeAudit({
			action: "admin.user.enable",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { targetUserId: target.id },
		})
		return reply.send({ ok: true })
	})

	app.get("/api/admin/devices", async (_request, reply) => {
		const devices = await prisma.device.findMany({
			orderBy: { createdAt: "desc" },
			take: 200,
			include: { user: { select: { id: true, publicId: true, username: true } } },
		})
		const items = await Promise.all(
			devices.map(async (device) => {
				const live = await prisma.session.findFirst({
					where: { deviceId: device.id, status: { in: ["PENDING", "ACTIVE"] } },
					include: { node: { select: { id: true, name: true } } },
				})
				return {
					id: device.id,
					deviceName: device.deviceName,
					platform: device.platform,
					status: device.status,
					user: device.user,
					node: live?.node ?? null,
					connected: live !== null,
					lastSeen: device.lastSeen?.toISOString() ?? null,
					createdAt: device.createdAt.toISOString(),
				}
			}),
		)
		return reply.send({ devices: items })
	})

	app.post("/api/admin/devices/:id/revoke", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid device id")
		const { user: admin } = getAuthUser(request)

		const device = await prisma.device.findUnique({ where: { id: parsed.data.id } })
		if (!device) throw notFound("Device not found")
		if (device.status === "REVOKED") {
			return reply.send({ ok: true, alreadyRevoked: true, closedSessions: 0 })
		}

		const closedSessions = await closeSessionsForDevice(device.id, "admin_revoked")
		await prisma.device.update({
			where: { id: device.id },
			data: { status: "REVOKED", revokedAt: new Date() },
		})
		const revokedTokens = await revokeRefreshTokens({
			userId: device.userId,
			deviceId: device.id,
		})
		await writeAudit({
			action: "admin.device.revoke",
			userId: admin.id,
			deviceId: device.id,
			ip: clientIp(request),
			metadata: { targetUserId: device.userId, closedSessions, revokedTokens },
		})
		return reply.send({ ok: true, closedSessions, revokedTokens })
	})

	app.get("/api/admin/sessions", async (request, reply) => {
		const query = z
			.object({ live: z.enum(["true", "false"]).optional() })
			.safeParse(request.query ?? {})
		const liveOnly = query.success && query.data.live === "true"

		const sessions = await prisma.session.findMany({
			where: liveOnly ? { status: { in: ["PENDING", "ACTIVE"] } } : undefined,
			orderBy: { connectedAt: "desc" },
			take: 100,
			include: {
				user: { select: { id: true, publicId: true, username: true } },
				device: { select: { id: true, deviceName: true } },
				node: { select: { id: true, name: true, countryCode: true } },
			},
		})
		return reply.send({
			sessions: sessions.map((session) => ({
				id: session.id,
				status: session.status,
				user: session.user,
				device: session.device,
				node: session.node,
				assignedVpnIp: session.assignedVpnIp,
				connectedAt: session.connectedAt.toISOString(),
				disconnectedAt: session.disconnectedAt?.toISOString() ?? null,
				lastHandshakeAt: session.lastHandshakeAt?.toISOString() ?? null,
				bytesRx: bytesToNumber(session.bytesRx),
				bytesTx: bytesToNumber(session.bytesTx),
				closeReason: session.closeReason,
			})),
		})
	})

	app.post("/api/admin/sessions/:id/close", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid session id")
		const { user: admin } = getAuthUser(request)

		const { closeSession } = await import("../services/sessions")
		const closed = await closeSession({
			sessionId: parsed.data.id,
			reason: "admin_closed",
			ip: clientIp(request),
		})
		if (!closed) throw notFound("Session not found")
		await writeAudit({
			action: "admin.session.close",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { sessionId: closed.id },
		})
		return reply.send({ ok: true })
	})

	app.get("/api/admin/audit", async (request, reply) => {
		const query = z
			.object({ limit: z.coerce.number().int().min(1).max(200).default(50) })
			.safeParse(request.query ?? {})
		const limit = query.success ? query.data.limit : 50

		const logs = await prisma.auditLog.findMany({
			orderBy: { createdAt: "desc" },
			take: limit,
			include: { user: { select: { publicId: true, username: true } } },
		})
		return reply.send({
			logs: logs.map((log) => ({
				id: log.id,
				action: log.action,
				username: log.user?.username ?? null,
				userPublicId: log.user?.publicId ?? null,
				deviceId: log.deviceId,
				nodeId: log.nodeId,
				ip: log.ip,
				// Sensitive keys were already redacted on write.
				metadata: log.metadata,
				createdAt: log.createdAt.toISOString(),
			})),
		})
	})
}
