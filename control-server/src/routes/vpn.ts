import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { badRequest, forbidden, notFound } from "../lib/errors"
import { clientIp, getAuthUser, requireDeviceScope, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { toPublicNode } from "../services/nodes"
import {
	closeSession,
	connectSession,
	findLiveSessionForDevice,
	findLiveSessionsForUser,
	hasActiveSubscription,
	toSessionView,
} from "../services/sessions"

const ConnectBody = z
	.object({ nodeId: z.string().uuid("Invalid node id").optional() })
	.optional()

const DisconnectBody = z
	.object({
		sessionId: z.string().uuid("Invalid session id").optional(),
		bytesRx: z.coerce.number().min(0).optional(),
		bytesTx: z.coerce.number().min(0).optional(),
		downloadBytes: z.coerce.number().min(0).optional(),
		uploadBytes: z.coerce.number().min(0).optional(),
	})
	.optional()

const StatsBody = z.object({
	sessionId: z.string().uuid("Invalid session id").optional(),
	bytesRx: z.coerce.number().min(0).optional(),
	bytesTx: z.coerce.number().min(0).optional(),
	downloadBytes: z.coerce.number().min(0).optional(),
	uploadBytes: z.coerce.number().min(0).optional(),
	transport: z.string().trim().max(40).optional(),
})

export async function vpnRoutes(app: FastifyInstance): Promise<void> {
	// Device-scoped token required: a plain login token cannot open a tunnel.
	app.post(
		"/api/vpn/connect",
		{
			preHandler: requireDeviceScope,
			config: { rateLimit: { max: 20, timeWindow: "1 minute" } },
		},
		async (request, reply) => {
			const parsed = ConnectBody.safeParse(request.body ?? {})
			if (!parsed.success) throw badRequest("Invalid connect payload")
			const { user, device } = getAuthUser(request)
			if (!device) throw forbidden("Device-scoped token required")

			const result = await connectSession({
				user,
				device,
				nodeId: parsed.data?.nodeId ?? null,
				ip: clientIp(request),
			})

			return reply.code(201).send({
				session: {
					id: result.session.id,
					// PENDING until the node agent confirms the peer was added.
					status: result.session.status,
					assignedVpnIp: result.session.assignedVpnIp,
					connectedAt: result.session.connectedAt.toISOString(),
				},
				node: toPublicNode(result.node),
				// WireGuard parameters for the client tunnel. No private key here:
				// the device keeps its own private key and never uploads it.
				tunnel: result.tunnel,
			})
		},
	)

	app.post(
		"/api/vpn/disconnect",
		{
			preHandler: requireDeviceScope,
			config: { rateLimit: { max: 30, timeWindow: "1 minute" } },
		},
		async (request, reply) => {
			const parsed = DisconnectBody.safeParse(request.body ?? {})
			if (!parsed.success) throw badRequest("Invalid disconnect payload")
			const { device } = getAuthUser(request)
			if (!device) throw forbidden("Device-scoped token required")

			const requestedId = parsed.data?.sessionId
			const session = requestedId
				? await prisma.session.findUnique({ where: { id: requestedId } })
				: await findLiveSessionForDevice(device.id)

			if (!session) {
				return reply.send({ ok: true, alreadyDisconnected: true, session: null })
			}
			// A device may only close its own sessions.
			if (session.deviceId !== device.id) throw notFound("Session not found")

			// Update final byte counters if provided before closing session
			const upload = parsed.data?.uploadBytes ?? parsed.data?.bytesRx
			const download = parsed.data?.downloadBytes ?? parsed.data?.bytesTx
			if (upload !== undefined || download !== undefined) {
				await prisma.session.update({
					where: { id: session.id },
					data: {
						...(upload !== undefined
							? { bytesRx: BigInt(Math.max(Number(session.bytesRx), Math.floor(upload))) }
							: {}),
						...(download !== undefined
							? { bytesTx: BigInt(Math.max(Number(session.bytesTx), Math.floor(download))) }
							: {}),
						lastHandshakeAt: new Date(),
						...(session.transport === "wireguard" ? { transport: "browser" } : {}),
					},
				}).catch(() => undefined)
			}

			await closeSession({
				sessionId: session.id,
				reason: "user_request",
				ip: clientIp(request),
			})

			const closed = await prisma.session.findUnique({
				where: { id: session.id },
				include: { node: true },
			})
			return reply.send({
				ok: true,
				session: closed ? toSessionView(closed) : null,
			})
		},
	)

	app.post(
		"/api/vpn/stats",
		{
			preHandler: requireUser,
			config: { rateLimit: { max: 120, timeWindow: "1 minute" } },
		},
		async (request, reply) => {
			const parsed = StatsBody.safeParse(request.body ?? {})
			if (!parsed.success) throw badRequest("Invalid stats payload")
			const { user, device } = getAuthUser(request)

			const requestedId = parsed.data.sessionId
			const session = requestedId
				? await prisma.session.findUnique({ where: { id: requestedId } })
				: device
					? await findLiveSessionForDevice(device.id)
					: (await findLiveSessionsForUser(user.id))[0]

			if (!session) {
				return reply.send({ ok: false, reason: "no_active_session" })
			}

			// A device/user may only report stats for their own sessions
			if (session.userId !== user.id) throw notFound("Session not found")

			const upload = parsed.data.uploadBytes ?? parsed.data.bytesRx
			const download = parsed.data.downloadBytes ?? parsed.data.bytesTx
			const now = new Date()

			const updated = await prisma.session.update({
				where: { id: session.id },
				data: {
					...(upload !== undefined
						? { bytesRx: BigInt(Math.max(Number(session.bytesRx), Math.floor(upload))) }
						: {}),
					...(download !== undefined
						? { bytesTx: BigInt(Math.max(Number(session.bytesTx), Math.floor(download))) }
						: {}),
					lastHandshakeAt: now,
					transport:
						parsed.data.transport ||
						(session.transport === "wireguard" ? "browser" : session.transport),
				},
				include: { node: true },
			})

			if (device) {
				await prisma.device
					.update({
						where: { id: device.id },
						data: { lastSeen: now },
					})
					.catch(() => undefined)
			}

			return reply.send({ ok: true, session: toSessionView(updated) })
		},
	)

	app.get("/api/vpn/status", { preHandler: requireUser }, async (request, reply) => {
		const { user, device } = getAuthUser(request)

		const sessions = device
			? await (async () => {
					const live = await findLiveSessionForDevice(device.id)
					return live ? [live] : []
				})()
			: await findLiveSessionsForUser(user.id)

		const current = sessions[0] ?? null
		const subscriptionActive = await hasActiveSubscription(user.id)

		return reply.send({
			// "connected" means the control plane has an open session; the tunnel
			// itself is up when status === ACTIVE (peer confirmed by the agent).
			connected: current !== null,
			peerReady: current?.status === "ACTIVE",
			session: current ? toSessionView(current) : null,
			sessions: sessions.map(toSessionView),
			subscriptionActive,
			serverTime: new Date().toISOString(),
		})
	})

	// Recent session history (traffic accounting: bytes and timestamps only).
	app.get("/api/vpn/sessions", { preHandler: requireUser }, async (request, reply) => {
		const { user } = getAuthUser(request)
		const sessions = await prisma.session.findMany({
			where: { userId: user.id },
			include: { node: true },
			orderBy: { connectedAt: "desc" },
			take: 20,
		})
		return reply.send({ sessions: sessions.map(toSessionView) })
	})
}
