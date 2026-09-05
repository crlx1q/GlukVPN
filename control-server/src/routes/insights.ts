import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { writeAudit } from "../lib/audit"
import { badRequest } from "../lib/errors"
import { clientIp, getAuthUser, requireAdmin, requireUser } from "../middleware/auth"
import { accountActiveMap, accountAnalytics } from "../services/accountInsights"
import { requestPolicySync } from "../services/policy"
import { serviceSettings, serviceStatus, updateNodeMaintenance, updateServiceSettings } from "../services/serviceControl"

const SettingsBody = z.object({ registrationEnabled: z.boolean().optional(), maintenance: z.boolean().optional(), expectedVersion: z.number().int().min(0) }).strict().refine((v) => v.registrationEnabled !== undefined || v.maintenance !== undefined)
const IdParams = z.object({ id: z.string().uuid() })
const AnalyticsQuery = z.object({ period: z.enum(["day", "week", "month"]).default("month") }).strict()

export async function insightsRoutes(app: FastifyInstance): Promise<void> {
	app.get("/api/service/status", { config: { rateLimit: { max: 120, timeWindow: "1 minute" } } }, async (_request, reply) => {
		return reply.header("Cache-Control", "no-store").send(await serviceStatus())
	})
	app.get("/api/user/active-map", { preHandler: requireUser, config: { rateLimit: { max: 120, timeWindow: "1 minute" } } }, async (request, reply) => {
		const { user, device } = getAuthUser(request)
		return reply.header("Cache-Control", "private, no-store").send(await accountActiveMap(user, device?.id))
	})
	app.get("/api/user/analytics", { preHandler: requireUser, config: { rateLimit: { max: 30, timeWindow: "1 minute" } } }, async (request, reply) => {
		const query = AnalyticsQuery.safeParse(request.query)
		if (!query.success) throw badRequest("period must be day, week or month")
		return reply.header("Cache-Control", "private, no-store").send(await accountAnalytics(getAuthUser(request).user.id, query.data.period, new Date(), getAuthUser(request).user.isAdmin === true))
	})
	app.get("/api/admin/service-settings", { preHandler: requireAdmin }, async (_request, reply) => reply.header("Cache-Control", "no-store").send(await serviceSettings()))
	app.post("/api/admin/service-settings", { preHandler: requireAdmin, config: { rateLimit: { max: 20, timeWindow: "1 minute" } } }, async (request, reply) => {
		const body = SettingsBody.safeParse(request.body)
		if (!body.success) throw badRequest("Provide booleans and the current settings version")
		const result = await updateServiceSettings(body.data)
		const policySyncQueued = await requestPolicySync()
		await writeAudit({ action: "admin.service.settings", userId: getAuthUser(request).user.id, ip: clientIp(request), metadata: { ...body.data, closedSessions: result.closedSessions } })
		return reply.send({ ok: true, ...result, policySyncQueued })
	})
	app.post("/api/admin/nodes/:id/maintenance", { preHandler: requireAdmin, config: { rateLimit: { max: 20, timeWindow: "1 minute" } } }, async (request, reply) => {
		const params = IdParams.safeParse(request.params)
		const body = z.object({ enabled: z.boolean() }).strict().safeParse(request.body)
		if (!params.success || !body.success) throw badRequest("A valid node and enabled boolean are required")
		const result = await updateNodeMaintenance(params.data.id, body.data.enabled)
		const policySyncQueued = await requestPolicySync(params.data.id)
		await writeAudit({ action: "admin.node.maintenance", userId: getAuthUser(request).user.id, nodeId: params.data.id, ip: clientIp(request), metadata: { enabled: body.data.enabled, closedSessions: result.closedSessions } })
		return reply.send({ ok: true, ...result, policySyncQueued })
	})
}
