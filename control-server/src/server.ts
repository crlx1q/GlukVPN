import { buildApp } from "./app"
import { config } from "./config"
import { disconnectPrisma, prisma } from "./prisma"
import { startMonitor } from "./services/monitor"

async function main(): Promise<void> {
	const app = await buildApp()

	// Fail fast if PostgreSQL is not reachable: better than serving 500s.
	try {
		await prisma.$queryRaw`SELECT 1`
	} catch (error) {
		app.log.error({ err: error }, "database_unreachable")
		throw new Error(
			"Cannot connect to PostgreSQL. Check DATABASE_URL and that the server is running.",
		)
	}

	const monitor = startMonitor(app)

	// Binds to 127.0.0.1 by default: the API is reachable only through Nginx/HTTPS.
	await app.listen({ host: config.HOST, port: config.PORT })
	app.log.info(
		{
			host: config.HOST,
			port: config.PORT,
			publicUrl: config.PUBLIC_API_URL,
			env: config.NODE_ENV,
		},
		"control_api_started",
	)

	let shuttingDown = false
	const shutdown = async (signal: string): Promise<void> => {
		if (shuttingDown) return
		shuttingDown = true
		app.log.info({ signal }, "shutting_down")
		monitor.stop()
		try {
			await app.close()
			await disconnectPrisma()
			process.exit(0)
		} catch (error) {
			app.log.error({ err: error }, "shutdown_failed")
			process.exit(1)
		}
	}

	process.on("SIGTERM", () => {
		void shutdown("SIGTERM")
	})
	process.on("SIGINT", () => {
		void shutdown("SIGINT")
	})
}

main().catch((error) => {
	// Startup errors are printed without any secret values.
	console.error(
		`control_api_start_failed: ${error instanceof Error ? error.message : "unknown error"}`,
	)
	process.exit(1)
})
