import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { badRequest, notFound } from "../lib/errors"
import { requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import { listSelectableNodes, loadPublicNodes } from "../services/nodes"

const IdParams = z.object({ id: z.string().uuid("Invalid node id") })

/** Read-only node catalogue for authenticated clients (server list screen). */
export async function nodeCatalogRoutes(app: FastifyInstance): Promise<void> {
	app.get("/api/nodes", { preHandler: requireUser }, async (_request, reply) => {
		const nodes = await listSelectableNodes()
		return reply.send({ nodes: await loadPublicNodes(nodes) })
	})

	app.get("/api/nodes/:id", { preHandler: requireUser }, async (request, reply) => {
		const parsed = IdParams.safeParse(request.params)
		if (!parsed.success) throw badRequest("Invalid node id")

		const node = await prisma.vpnNode.findUnique({ where: { id: parsed.data.id } })
		if (!node || node.status === "DISABLED") throw notFound("Node not found")
		return reply.send({ node: (await loadPublicNodes([node]))[0] })
	})
}
