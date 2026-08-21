import type { FastifyInstance } from "fastify"
import { config } from "../config"
import { prisma } from "../prisma"

export async function healthRoutes(app: FastifyInstance): Promise<void> {
	// Unauthenticated liveness/readiness probe. Exposes no user data.
	app.get(
		"/api/health",
		{ config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (_request, reply) => {
			let database: "up" | "down" = "down"
			try {
				await prisma.$queryRaw`SELECT 1`
				database = "up"
			} catch {
				database = "down"
			}

			const body = {
				ok: database === "up",
				service: "glukvpn-control",
				channel: config.CHANNEL,
				version: config.APP_VERSION,
				// Which deployed release answered. `version` comes from package.json
				// and therefore survives a promote unchanged; this does not.
				release: config.release,
				database,
				time: new Date().toISOString(),
			}
			return reply.code(database === "up" ? 200 : 503).send(body)
		},
	)

	// Which channel/version is actually running here. Used by:
	//   - the Flutter app, to show "PROD 1.0.0 / BETA 1.2.0" and pick a channel;
	//   - the admin panel, to compare both stacks before a promote;
	//   - the deploy worker, as the post-deploy health gate.
	// Deliberately unauthenticated and free of user data: it is only a build
	// fingerprint, the same information an app store listing would expose.
	app.get(
		"/api/version",
		{ config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (_request, reply) => {
			let migration: string | null = null
			let database: "up" | "down" = "down"
			try {
				const rows = await prisma.$queryRaw<Array<{ migration_name: string }>>`
					SELECT migration_name
					FROM "_prisma_migrations"
					WHERE finished_at IS NOT NULL
					ORDER BY finished_at DESC
					LIMIT 1
				`
				migration = rows[0]?.migration_name ?? null
				database = "up"
			} catch {
				migration = null
			}

			return reply.send({
				service: "glukvpn-control",
				channel: config.CHANNEL,
				version: config.APP_VERSION,
				release: config.release,
				commit: config.GIT_COMMIT || null,
				releasedAt: config.RELEASED_AT || null,
				migration,
				database,
				time: new Date().toISOString(),
			})
		},
	)
}
