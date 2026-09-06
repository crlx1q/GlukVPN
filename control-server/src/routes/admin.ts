import type { BlockRuleKind } from "@prisma/client"
import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { generateSecret, hashPassword, hashSecret } from "../lib/crypto"
import { badRequest, conflict, notFound } from "../lib/errors"
import { clientIp, getAuthUser, requireAdmin } from "../middleware/auth"
import { bytesToNumber, prisma } from "../prisma"
import { cancelOrder, grantPlan, markOrderPaid, orderView } from "../services/billing"
import { purgeStaleDevices } from "../services/deviceAccess"
import { categoryLabel } from "../services/domainCategories"
import { egressBudgetView } from "../services/egressBudget"
import {
	entitlementPayload,
	FREE_PLAN_CODE,
	isGrantablePlanCode,
	planDisplayName,
	planShape,
	resolveEntitlement,
} from "../services/entitlements"
import { effectiveNodeStatus, nodeEndpoint, nodeLoadPercent } from "../services/nodes"
import { publicRestrictions } from "../services/nodeRestrictions"
import {
	BUILTIN_RULES,
	SNIFFED_PROTOCOLS,
	buildNodePolicy,
	normalizeRule,
	requestPolicySync,
} from "../services/policy"
import {
	closeSessionsForDevice,
	closeSessionsForNode,
	closeSessionsForUser,
} from "../services/sessions"
import { clearClientErrors, listClientErrors } from "../services/telemetry"
import { revokeRefreshTokens } from "../services/tokens"

const IdParams = z.object({ id: z.string().uuid("Invalid id") })

const RULE_KINDS = [
	"PROTOCOL",
	"DOMAIN",
	"DOMAIN_SUFFIX",
	"DOMAIN_KEYWORD",
	"DOMAIN_REGEX",
	"IP_CIDR",
	"PORT",
	"PORT_RANGE",
] as const

const CreateRuleBody = z.object({
	// Null / absent = every node.
	nodeId: z.string().uuid().nullable().optional(),
	kind: z.enum(RULE_KINDS),
	value: z.string().trim().min(1).max(200),
	network: z.enum(["tcp", "udp", ""]).nullable().optional(),
	note: z.string().trim().max(200).optional(),
	enabled: z.boolean().optional(),
})

const UpdateRuleBody = z.object({
	enabled: z.boolean().optional(),
	note: z.string().trim().max(200).nullable().optional(),
})

const BlockBody = z
	.object({ reason: z.string().trim().max(300).optional() })
	.optional()

const TesterBody = z.object({ enabled: z.boolean() })

const TierBody = z.object({ tier: z.coerce.number().int().min(0).max(9) })

const GrantBody = z.object({
	planCode: z.string().trim().min(2).max(32),
	days: z.coerce.number().int().min(1).max(3650).optional(),
	/**
	 * "extend" adds the term on top of the days already left, "replace" starts a
	 * fresh term now. The panel asks for one or the other explicitly instead of
	 * silently stacking, which is what made grants unpredictable.
	 */
	mode: z.enum(["extend", "replace"]).default("extend"),
})

const ActivityQuery = z
	.object({
		limit: z.coerce.number().int().min(1).max(500).default(100),
		userId: z.string().uuid().optional(),
		deviceId: z.string().uuid().optional(),
		category: z.string().trim().max(32).optional(),
	})
	.optional()

/** Rule row -> panel row. */
function ruleView(rule: {
	id: string
	nodeId: string | null
	kind: BlockRuleKind
	value: string
	network: string | null
	enabled: boolean
	note: string | null
	createdAt: Date
	node?: { name: string } | null
	createdBy?: { username: string } | null
}) {
	return {
		id: rule.id,
		nodeId: rule.nodeId,
		nodeName: rule.node?.name ?? null,
		kind: rule.kind,
		value: rule.value,
		network: rule.network,
		enabled: rule.enabled,
		note: rule.note,
		createdBy: rule.createdBy?.username ?? null,
		createdAt: rule.createdAt.toISOString(),
	}
}

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
				const policy = await buildNodePolicy(node)
				return {
					id: node.id,
					name: node.name,
					country: node.country,
					countryCode: node.countryCode,
					endpoint: nodeEndpoint(node),
					publicIp: node.publicIp,
					storedStatus: node.status,
					maintenance: Boolean(node.maintenance),
					restrictions: publicRestrictions(policy.rules),
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
					tier: node.tier,
					gateway: node.gatewayHost
						? {
								host: node.gatewayHost,
								port: node.gatewayPort,
								sni: node.gatewaySni,
								flow: node.gatewayFlow,
								updatedAt: node.gatewayUpdatedAt?.toISOString() ?? null,
							}
						: null,
					policy: {
						desiredVersion: policy.version,
						appliedVersion: node.policyVersion,
						appliedAt: node.policyAppliedAt?.toISOString() ?? null,
						inSync: node.policyVersion === policy.version,
						users: policy.users.length,
						rules: policy.rules.length + policy.builtinRules.length,
					},
				}
			}),
		)
		return reply.send({ nodes: items })
	})

	/** Minimum plan tier for a node (0 = everyone). */
	app.post("/api/admin/nodes/:id/tier", async (request, reply) => {
		const params = IdParams.safeParse(request.params)
		if (!params.success) throw badRequest("Invalid node id")
		const body = TierBody.safeParse(request.body)
		if (!body.success) throw badRequest("tier must be 0..9")
		const { user } = getAuthUser(request)
		const node = await prisma.vpnNode.findUnique({ where: { id: params.data.id } })
		if (!node) throw notFound("Node not found")
		await prisma.vpnNode.update({ where: { id: node.id }, data: { tier: body.data.tier } })
		await requestPolicySync(node.id).catch(() => 0)
		await writeAudit({
			action: "admin.node.tier",
			userId: user.id,
			nodeId: node.id,
			ip: clientIp(request),
			metadata: { from: node.tier, to: body.data.tier },
		})
		return reply.send({ ok: true, tier: body.data.tier })
	})

	// ------------------------------------------------------------ policy ----

	/** Built-in + admin rules. `?nodeId=` narrows to one node plus the global rows. */
	app.get("/api/admin/policy/rules", async (request, reply) => {
		const query = z
			.object({ nodeId: z.string().uuid().optional() })
			.safeParse(request.query ?? {})
		const nodeId = query.success ? query.data.nodeId : undefined
		const rules = await prisma.nodeBlockRule.findMany({
			where: nodeId ? { OR: [{ nodeId: null }, { nodeId }] } : undefined,
			include: { node: { select: { name: true } }, createdBy: { select: { username: true } } },
			orderBy: [{ nodeId: "asc" }, { createdAt: "asc" }],
		})
		return reply.send({
			builtin: BUILTIN_RULES,
			protocols: SNIFFED_PROTOCOLS,
			kinds: RULE_KINDS,
			rules: rules.map(ruleView),
		})
	})

	app.post("/api/admin/policy/rules", async (request, reply) => {
		const parsed = CreateRuleBody.safeParse(request.body)
		if (!parsed.success) {
			throw badRequest("Invalid rule", parsed.error.flatten().fieldErrors)
		}
		const { user } = getAuthUser(request)
		const body = parsed.data
		if (body.nodeId) {
			const node = await prisma.vpnNode.findUnique({ where: { id: body.nodeId } })
			if (!node) throw notFound("Node not found")
		}
		const normalized = normalizeRule({
			kind: body.kind,
			value: body.value,
			network: body.network ?? null,
		})
		const duplicate = await prisma.nodeBlockRule.findFirst({
			where: {
				nodeId: body.nodeId ?? null,
				kind: normalized.kind,
				value: normalized.value,
				network: normalized.network,
			},
		})
		if (duplicate) throw conflict("An identical rule already exists")

		const rule = await prisma.nodeBlockRule.create({
			data: {
				nodeId: body.nodeId ?? null,
				kind: normalized.kind,
				value: normalized.value,
				network: normalized.network,
				note: body.note?.trim() || null,
				enabled: body.enabled ?? true,
				createdById: user.id,
			},
			include: { node: { select: { name: true } }, createdBy: { select: { username: true } } },
		})
		await requestPolicySync(body.nodeId ?? null).catch(() => 0)
		await writeAudit({
			action: "admin.policy.rule.create",
			userId: user.id,
			nodeId: body.nodeId ?? null,
			ip: clientIp(request),
			metadata: { ruleId: rule.id, kind: rule.kind, value: rule.value, network: rule.network },
		})
		return reply.code(201).send({ rule: ruleView(rule) })
	})

	app.post("/api/admin/policy/rules/:id", async (request, reply) => {
		const params = IdParams.safeParse(request.params)
		if (!params.success) throw badRequest("Invalid rule id")
		const body = UpdateRuleBody.safeParse(request.body ?? {})
		if (!body.success) throw badRequest("Invalid payload")
		const { user } = getAuthUser(request)
		const existing = await prisma.nodeBlockRule.findUnique({ where: { id: params.data.id } })
		if (!existing) throw notFound("Rule not found")
		const rule = await prisma.nodeBlockRule.update({
			where: { id: existing.id },
			data: {
				...(body.data.enabled === undefined ? {} : { enabled: body.data.enabled }),
				...(body.data.note === undefined ? {} : { note: body.data.note?.trim() || null }),
			},
			include: { node: { select: { name: true } }, createdBy: { select: { username: true } } },
		})
		await requestPolicySync(existing.nodeId).catch(() => 0)
		await writeAudit({
			action: "admin.policy.rule.update",
			userId: user.id,
			nodeId: existing.nodeId,
			ip: clientIp(request),
			metadata: { ruleId: rule.id, enabled: rule.enabled },
		})
		return reply.send({ rule: ruleView(rule) })
	})

	app.delete("/api/admin/policy/rules/:id", async (request, reply) => {
		const params = IdParams.safeParse(request.params)
		if (!params.success) throw badRequest("Invalid rule id")
		const { user } = getAuthUser(request)
		const existing = await prisma.nodeBlockRule.findUnique({ where: { id: params.data.id } })
		if (!existing) return reply.send({ ok: true, alreadyRemoved: true })
		await prisma.nodeBlockRule.delete({ where: { id: existing.id } })
		await requestPolicySync(existing.nodeId).catch(() => 0)
		await writeAudit({
			action: "admin.policy.rule.delete",
			userId: user.id,
			nodeId: existing.nodeId,
			ip: clientIp(request),
			metadata: { ruleId: existing.id, kind: existing.kind, value: existing.value },
		})
		return reply.send({ ok: true })
	})

	/** Push the current policy to every live node right now. */
	app.post("/api/admin/policy/sync", async (request, reply) => {
		const { user } = getAuthUser(request)
		const queued = await requestPolicySync()
		await writeAudit({
			action: "admin.policy.sync",
			userId: user.id,
			ip: clientIp(request),
			metadata: { queued },
		})
		return reply.send({ ok: true, queued })
	})

	// ----------------------------------------------------- traffic budget ----

	/**
	 * Outbound traffic for the current PAYG billing cycle against Oracle's free
	 * allowance: used, remaining, percent, and whether anything has been charged.
	 *
	 * Served from the stored figure rather than by calling Oracle here. The meter
	 * is polled in the background every OCI_POLL_INTERVAL_MIN minutes, so an
	 * admin holding down refresh cannot make us hammer a rate-limited API - and
	 * the reply stays fast enough to sit on a dashboard that auto-refreshes.
	 *
	 * `configured: false` means no Oracle credentials or no cycle anchor date;
	 * the panel should say so rather than render a confident 0%.
	 */
	app.get("/api/admin/traffic-budget", async (_request, reply) => {
		return reply.send(await egressBudgetView())
	})

	// ---------------------------------------------------------- activity ----

	/**
	 * Which sites which device talked to, newest first. Domain + counters only.
	 * `?userId=` for one account, `?deviceId=` for one device, `?category=` to
	 * filter, `?limit=` up to 500.
	 */
	app.get("/api/admin/activity", async (request, reply) => {
		const parsed = ActivityQuery.safeParse(request.query ?? {})
		const query: { limit?: number; userId?: string; deviceId?: string; category?: string } =
			parsed.success ? (parsed.data ?? {}) : {}
		const limit = query.limit ?? 100
		const rows = await prisma.trafficDomainStat.findMany({
			where: {
				...(query.userId ? { userId: query.userId } : {}),
				...(query.deviceId ? { deviceId: query.deviceId } : {}),
				...(query.category ? { category: query.category } : {}),
			},
			include: {
				user: { select: { id: true, publicId: true, username: true } },
				device: { select: { id: true, deviceName: true, platform: true } },
				node: { select: { id: true, name: true, countryCode: true } },
				session: { select: { id: true, status: true, transport: true, assignedVpnIp: true } },
			},
			orderBy: { lastSeenAt: "desc" },
			take: limit,
		})

		// Category totals over the same window, for the summary strip.
		const categories = new Map<string, { bytes: number; connections: number; domains: number }>()
		for (const row of rows) {
			const key = row.category ?? "other"
			const entry = categories.get(key) ?? { bytes: 0, connections: 0, domains: 0 }
			entry.bytes += bytesToNumber(row.bytesRx) + bytesToNumber(row.bytesTx)
			entry.connections += row.connections
			entry.domains += 1
			categories.set(key, entry)
		}

		return reply.send({
			enabled: config.DOMAIN_STATS_ENABLED,
			retentionDays: config.DOMAIN_STATS_RETENTION_DAYS,
			categories: [...categories.entries()]
				.map(([code, totals]) => ({ code, label: categoryLabel(code), ...totals }))
				.sort((a, b) => b.bytes - a.bytes),
			items: rows.map((row) => ({
				id: row.id,
				domain: row.domain,
				category: row.category ?? "other",
				categoryLabel: categoryLabel(row.category),
				bytesRx: bytesToNumber(row.bytesRx),
				bytesTx: bytesToNumber(row.bytesTx),
				connections: row.connections,
				firstSeenAt: row.firstSeenAt.toISOString(),
				lastSeenAt: row.lastSeenAt.toISOString(),
				user: row.user,
				device: row.device,
				node: row.node,
				session: row.session,
			})),
		})
	})

	/** Everything the panel shows when an admin opens one account. */
	app.get("/api/admin/users/:id/activity", async (request, reply) => {
		const params = IdParams.safeParse(request.params)
		if (!params.success) throw badRequest("Invalid user id")
		const user = await prisma.user.findUnique({
			where: { id: params.data.id },
			include: {
				subscriptions: { orderBy: { expiresAt: "desc" }, take: 5 },
				identityLinks: true,
			},
		})
		if (!user) throw notFound("User not found")

		const [devices, sessions, domains, orders] = await Promise.all([
			prisma.device.findMany({
				where: { userId: user.id },
				orderBy: [{ status: "asc" }, { createdAt: "desc" }],
			}),
			prisma.session.findMany({
				where: { userId: user.id },
				include: {
					node: { select: { id: true, name: true, countryCode: true } },
					device: { select: { id: true, deviceName: true, platform: true } },
				},
				orderBy: { connectedAt: "desc" },
				take: 30,
			}),
			prisma.trafficDomainStat.findMany({
				where: { userId: user.id },
				include: { device: { select: { id: true, deviceName: true, platform: true } } },
				orderBy: { lastSeenAt: "desc" },
				take: 200,
			}),
			prisma.order.findMany({
				where: { userId: user.id },
				include: { plan: true },
				orderBy: { createdAt: "desc" },
				take: 20,
			}),
		])

		return reply.send({
			user: {
				id: user.id,
				publicId: user.publicId,
				username: user.username,
				email: user.email,
				status: user.status,
				isAdmin: user.isAdmin,
				isTester: user.isTester,
				blockedAt: user.blockedAt?.toISOString() ?? null,
				blockedReason: user.blockedReason,
				telegramUsername: user.telegramUsername,
				telegramLinked: Boolean(user.telegramId),
				googleLinked: user.identityLinks.some((link) => link.provider === "GOOGLE"),
				maxDevices: user.maxDevices,
				maxSessions: user.maxSessions,
				origin: { country: user.lastCountry, countryCode: user.lastCountryCode, region: user.lastRegion },
				createdAt: user.createdAt.toISOString(),
			},
			subscriptions: user.subscriptions.map((sub) => ({
				id: sub.id,
				plan: sub.plan,
				tier: sub.tier,
				source: sub.source,
				status: sub.status,
				expiresAt: sub.expiresAt.toISOString(),
			})),
			devices: devices.map((device) => ({
				id: device.id,
				deviceName: device.deviceName,
				platform: device.platform,
				status: device.status,
				hasVlessCredential: Boolean(device.vlessUuid),
				lastSeen: device.lastSeen?.toISOString() ?? null,
				createdAt: device.createdAt.toISOString(),
			})),
			sessions: sessions.map((session) => ({
				id: session.id,
				status: session.status,
				transport: session.transport,
				node: session.node,
				device: session.device,
				assignedVpnIp: session.assignedVpnIp,
				clientIp: session.clientIp,
				connectedAt: session.connectedAt.toISOString(),
				disconnectedAt: session.disconnectedAt?.toISOString() ?? null,
				lastHandshakeAt: session.lastHandshakeAt?.toISOString() ?? null,
				bytesRx: bytesToNumber(session.bytesRx),
				bytesTx: bytesToNumber(session.bytesTx),
				closeReason: session.closeReason,
			})),
			domains: domains.map((row) => ({
				id: row.id,
				domain: row.domain,
				category: row.category ?? "other",
				categoryLabel: categoryLabel(row.category),
				bytesRx: bytesToNumber(row.bytesRx),
				bytesTx: bytesToNumber(row.bytesTx),
				connections: row.connections,
				firstSeenAt: row.firstSeenAt.toISOString(),
				lastSeenAt: row.lastSeenAt.toISOString(),
				device: row.device,
				sessionId: row.sessionId,
			})),
			orders: orders.map(orderView),
		})
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
				// Show what is actually live. The counters used to include revoked
				// devices and PENDING sessions that never came up, which is how the
				// panel ended up printing "58 / 5" and "4 / 3" for a single laptop.
				const [activeDevices, liveSessions] = await Promise.all([
					prisma.device.count({ where: { userId: user.id, status: "ACTIVE" } }),
					prisma.session.count({ where: { userId: user.id, status: "ACTIVE" } }),
				])
				const subscription = user.subscriptions[0] ?? null
				// What the account is really entitled to. Legacy "free" rows are not
				// subscriptions, so the panel reads them as "no subscription" rather
				// than "Free, active until 2028".
				const entitlement = await resolveEntitlement(user.id)
				return {
					id: user.id,
					publicId: user.publicId,
					username: user.username,
					email: user.email,
					status: user.status,
					isAdmin: user.isAdmin,
					isTester: user.isTester,
					blockedReason: user.blockedReason,
					maxDevices: user.maxDevices,
					maxSessions: user.maxSessions,
					devices: activeDevices,
					sessionsTotal: user._count.sessions,
					liveSessions,
					subscription: subscription
						? {
								status: subscription.status,
								plan: subscription.plan,
								tier: subscription.tier,
								expiresAt: subscription.expiresAt.toISOString(),
							}
						: null,
					entitlement: entitlementPayload(entitlement),
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

		await prisma.user.update({
			where: { id: target.id },
			data: { status: "ACTIVE", blockedAt: null, blockedReason: null },
		})
		await requestPolicySync().catch(() => 0)
		await writeAudit({
			action: "admin.user.enable",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { targetUserId: target.id, previousStatus: target.status },
		})
		return reply.send({ ok: true })
	})

	/**
	 * Instant block: tunnels down, tokens dead, VLESS credential pulled from
	 * every node, new logins refused with an explicit "blocked" message.
	 */
	app.post("/api/admin/users/:id/block", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const body = BlockBody.safeParse(request.body ?? {})
		if (!body.success) throw badRequest("Invalid payload")
		const { user: admin } = getAuthUser(request)

		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")
		if (target.id === admin.id) throw conflict("You cannot block your own account")

		const reason = body.data?.reason?.trim() || null
		const closedSessions = await closeSessionsForUser(target.id, "user_blocked")
		await prisma.user.update({
			where: { id: target.id },
			data: { status: "BLOCKED", blockedAt: new Date(), blockedReason: reason },
		})
		const revokedTokens = await revokeRefreshTokens({ userId: target.id })
		// The policy excludes devices of non-ACTIVE users, so the next sync
		// removes their VLESS users from sing-box on every node.
		const queued = await requestPolicySync().catch(() => 0)
		await writeAudit({
			action: "admin.user.block",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { targetUserId: target.id, reason, closedSessions, revokedTokens, nodesQueued: queued },
		})
		return reply.send({ ok: true, closedSessions, revokedTokens })
	})

	app.post("/api/admin/users/:id/unblock", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const { user: admin } = getAuthUser(request)
		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")
		await prisma.user.update({
			where: { id: target.id },
			data: { status: "ACTIVE", blockedAt: null, blockedReason: null },
		})
		await requestPolicySync().catch(() => 0)
		await writeAudit({
			action: "admin.user.unblock",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { targetUserId: target.id },
		})
		return reply.send({ ok: true })
	})

	/** Beta-tester flag: shows the PROD/BETA switch in every client. */
	app.post("/api/admin/users/:id/tester", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const body = TesterBody.safeParse(request.body)
		if (!body.success) throw badRequest("enabled is required")
		const { user: admin } = getAuthUser(request)
		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")
		await prisma.user.update({
			where: { id: target.id },
			data: { isTester: body.data.enabled },
		})
		await writeAudit({
			action: "admin.user.tester",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { targetUserId: target.id, enabled: body.data.enabled },
		})
		return reply.send({ ok: true, isTester: body.data.enabled })
	})

	/** Hand a plan to an account by hand (support, promo, cash payment). */
	app.post("/api/admin/users/:id/subscription", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const body = GrantBody.safeParse(request.body)
		if (!body.success) throw badRequest("planCode is required")
		const { user: admin } = getAuthUser(request)
		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")
		// Free is not a subscription - "Free, active, 790 days left" is nonsense,
		// and this endpoint is how it used to be produced. Taking a plan away is the
		// DELETE below, never a grant of "free".
		if (!isGrantablePlanCode(body.data.planCode)) {
			throw badRequest("Free is not a subscription: deactivate the subscription instead")
		}
		const plan = await prisma.plan.findFirst({ where: { code: body.data.planCode.toLowerCase() } })
		if (!plan) throw notFound("Plan not found")
		const granted = await grantPlan({
			userId: target.id,
			plan,
			days: body.data.days,
			source: "manual",
			mode: body.data.mode,
		})
		await writeAudit({
			action: "admin.user.subscription.grant",
			userId: admin.id,
			ip: clientIp(request),
			metadata: {
				targetUserId: target.id,
				plan: plan.code,
				mode: body.data.mode,
				days: body.data.days ?? plan.days,
				expiresAt: granted.expiresAt.toISOString(),
			},
		})
		return reply.send({
			ok: true,
			plan: plan.code,
			planName: planDisplayName(plan.code),
			mode: body.data.mode,
			expiresAt: granted.expiresAt.toISOString(),
			entitlement: entitlementPayload(await resolveEntitlement(target.id)),
		})
	})

	/**
	 * Turn a subscription off completely.
	 *
	 * The account is not moved onto a "Free plan", because no such row exists:
	 * Free is the absence of a subscription. Every active row is superseded, the
	 * device/session allowances fall back to the Free matrix and live tunnels are
	 * closed so no node keeps honouring the old tier.
	 */
	app.delete("/api/admin/users/:id/subscription", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid user id")
		const { user: admin } = getAuthUser(request)
		const target = await prisma.user.findUnique({ where: { id: parsed.data.id } })
		if (!target) throw notFound("User not found")
		const disabled = await prisma.subscription.updateMany({
			where: { userId: target.id, status: "ACTIVE" },
			data: { status: "DISABLED" },
		})
		const free = planShape(FREE_PLAN_CODE)
		await prisma.user.update({
			where: { id: target.id },
			data: { maxDevices: free.maxDevices, maxSessions: free.maxSessions },
		})
		const closedSessions = await closeSessionsForUser(target.id, "subscription_expired")
		await requestPolicySync()
		await writeAudit({
			action: "admin.user.subscription.revoke",
			userId: admin.id,
			ip: clientIp(request),
			metadata: {
				targetUserId: target.id,
				subscriptionsDisabled: disabled.count,
				closedSessions,
			},
		})
		return reply.send({
			ok: true,
			subscriptionsDisabled: disabled.count,
			closedSessions,
			entitlement: entitlementPayload(await resolveEntitlement(target.id)),
		})
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

	// Чистка кеша старых устройств: отозванные надгробия и строки, которыми
	// давно никто не пользовался. Активные устройства не трогаем: days=0
	// убирает всё мёртвое сразу, days=N оставляет окно в N дней.
	app.delete("/api/admin/devices/stale", async (request, reply) => {
		const PurgeQuery = z.object({
			days: z.coerce.number().int().min(0).max(3650).optional().default(0),
		})
		const parsed = PurgeQuery.safeParse(request.query ?? {})
		if (!parsed.success) throw badRequest("Invalid retention window")
		const { user: admin } = getAuthUser(request)
		const removed = await purgeStaleDevices({ retentionDays: parsed.data.days })
		await writeAudit({
			action: "admin.devices.purge",
			userId: admin.id,
			ip: clientIp(request),
			metadata: { removed, retentionDays: parsed.data.days },
		})
		return reply.send({ ok: true, removed, retentionDays: parsed.data.days })
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
		// Its VLESS credential leaves the node config on the next sync.
		await requestPolicySync().catch(() => 0)
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
				transport: session.transport,
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

	// ----------------------------------------------------------- billing ----

	app.get("/api/admin/billing/orders", async (request, reply) => {
		const query = z
			.object({
				status: z.enum(["PENDING", "PAID", "FAILED", "CANCELLED", "REFUNDED"]).optional(),
				limit: z.coerce.number().int().min(1).max(200).default(50),
			})
			.safeParse(request.query ?? {})
		const status = query.success ? query.data.status : undefined
		const limit = query.success ? query.data.limit : 50
		const orders = await prisma.order.findMany({
			where: status ? { status } : undefined,
			include: { plan: true, user: { select: { id: true, publicId: true, username: true } } },
			orderBy: { createdAt: "desc" },
			take: limit,
		})
		return reply.send({
			billingEnabled: config.billingEnabled,
			provider: config.billingEnabled ? config.BILLING_PROVIDER : null,
			orders: orders.map((order) => ({ ...orderView(order), user: order.user })),
		})
	})

	app.post("/api/admin/billing/orders/:id/mark-paid", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid order id")
		const { user: admin } = getAuthUser(request)
		const order = await markOrderPaid({ orderId: parsed.data.id, by: "admin", adminId: admin.id })
		return reply.send({ ok: true, order: orderView(order) })
	})

	app.post("/api/admin/billing/orders/:id/cancel", async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid order id")
		const { user: admin } = getAuthUser(request)
		await cancelOrder(parsed.data.id, admin.id)
		return reply.send({ ok: true })
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

	/**
	 * Uncaught errors reported by the clients (desktop, mobile, extension, web).
	 * `?platform=` narrows to one client, `?limit=` up to 500, newest first.
	 *
	 * Everything here was scrubbed of credentials on the way in, so the panel can
	 * show the raw stack trace without leaking a token to whoever is on support.
	 */
	app.get("/api/admin/client-errors", async (request, reply) => {
		const parsed = z
			.object({
				platform: z.enum(["windows", "android", "extension", "web"]).optional(),
				limit: z.coerce.number().int().min(1).max(500).default(100),
			})
			.safeParse(request.query ?? {})

		const limit = parsed.success ? parsed.data.limit : 100
		const platform = parsed.success ? parsed.data.platform : undefined
		return reply.send(await listClientErrors({ platform, limit }))
	})

	/**
	 * Очистить журнал клиентских ошибок. `?platform=` — только одна
	 * платформа, без параметра — все.
	 *
	 * Сбор ошибок при этом не отключается и килл-свитча не касается:
	 * удаляем только то, что уже лежало в таблице на момент запроса,
	 * поэтому новые отчёты продолжают приходить в тот же список.
	 * Само действие пишется в аудит: удаление диагностики не должно
	 * быть анонимным.
	 */
	app.delete("/api/admin/client-errors", async (request, reply) => {
		const { user } = getAuthUser(request)
		const parsed = z
			.object({ platform: z.enum(["windows", "android", "extension", "web"]).optional() })
			.safeParse(request.query ?? {})
		const platform = parsed.success ? parsed.data.platform : undefined
		const before = new Date()
		const removed = await clearClientErrors({ platform, before })
		await writeAudit({
			action: "admin.client_errors.clear",
			userId: user.id,
			ip: clientIp(request),
			metadata: { platform: platform ?? "all", before: before.toISOString(), removed },
		})
		return reply.send({
			ok: true,
			removed,
			platform: platform ?? "all",
			before: before.toISOString(),
		})
	})
}
