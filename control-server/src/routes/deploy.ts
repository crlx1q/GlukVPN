import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { badRequest, conflict, forbidden } from "../lib/errors"
import { clientIp, getAuthUser, requireAdmin } from "../middleware/auth"
import { prisma } from "../prisma"

/**
 * Channel management endpoints.
 *
 * The panel never sends a command, a path or a script name: it POSTs to one of
 * three fixed routes, each of which inserts a row with a fixed enum action.
 * The deploy worker turns that enum into one hard-coded script. See
 * `src/scripts/deployWorker.ts`.
 */

const PROD_ORIGIN = "http://127.0.0.1:8081"
const BETA_ORIGIN = "http://127.0.0.1:8082"

type ChannelState = {
	channel: "prod" | "beta"
	reachable: boolean
	version: string | null
	commit: string | null
	migration: string | null
	database: string | null
	releasedAt: string | null
}

/** Ask a channel what it is running. Loopback only, 3 s budget. */
async function probeChannel(
	origin: string,
	channel: "prod" | "beta",
): Promise<ChannelState> {
	const offline: ChannelState = {
		channel,
		reachable: false,
		version: null,
		commit: null,
		migration: null,
		database: null,
		releasedAt: null,
	}
	try {
		const response = await fetch(`${origin}/api/version`, {
			signal: AbortSignal.timeout(3000),
		})
		if (!response.ok) return offline
		const body = (await response.json()) as Record<string, unknown>
		return {
			channel,
			reachable: true,
			version: typeof body.version === "string" ? body.version : null,
			commit: typeof body.commit === "string" ? body.commit : null,
			migration: typeof body.migration === "string" ? body.migration : null,
			database: typeof body.database === "string" ? body.database : null,
			releasedAt: typeof body.releasedAt === "string" ? body.releasedAt : null,
		}
	} catch {
		// Beta being switched off is a normal, expected state.
		return offline
	}
}

function serializeJob(job: {
	id: string
	action: string
	status: string
	releaseId: string | null
	previousReleaseId: string | null
	backupPath: string | null
	exitCode: number | null
	log: string | null
	createdAt: Date
	startedAt: Date | null
	finishedAt: Date | null
	requestedBy?: { username: string; publicId: string } | null
}) {
	return {
		id: job.id,
		action: job.action,
		status: job.status,
		releaseId: job.releaseId,
		previousReleaseId: job.previousReleaseId,
		backupPath: job.backupPath,
		exitCode: job.exitCode,
		log: job.log,
		requestedBy: job.requestedBy
			? { username: job.requestedBy.username, publicId: job.requestedBy.publicId }
			: null,
		createdAt: job.createdAt.toISOString(),
		startedAt: job.startedAt?.toISOString() ?? null,
		finishedAt: job.finishedAt?.toISOString() ?? null,
	}
}

export async function deployRoutes(app: FastifyInstance): Promise<void> {
	app.addHook("preHandler", requireAdmin)

	/**
	 * Deployment is driven from the prod panel only. Beta is the thing being
	 * deployed; letting it deploy itself (or promote itself into prod) would
	 * mean experimental code decides when it becomes production code.
	 */
	const requireProdChannel = (): void => {
		if (config.CHANNEL !== "prod") {
			throw forbidden(
				"Deployments are controlled from the production panel (admin.gluk.tech), not from beta",
			)
		}
	}

	const enqueue = async (
		request: { ip: string; [key: string]: unknown },
		action: "DEPLOY_BETA" | "PROMOTE_BETA_TO_PROD" | "ROLLBACK_PROD",
	) => {
		requireProdChannel()
		const { user } = getAuthUser(request as never)

		const active = await prisma.deployJob.findFirst({
			where: { status: { in: ["QUEUED", "RUNNING"] } },
		})
		if (active) {
			throw conflict(
				`A deployment is already ${active.status.toLowerCase()} (${active.action}). Wait for it to finish.`,
			)
		}

		const job = await prisma.deployJob.create({
			data: { action, requestedById: user.id },
		})
		await writeAudit({
			action: "deploy.job.queued",
			userId: user.id,
			ip: clientIp(request as never),
			metadata: { jobId: job.id, deployAction: action },
		})
		return job
	}

	/** Build the current source tree and activate it on beta. Prod untouched. */
	app.post("/api/admin/deploy/beta", async (request, reply) => {
		const job = await enqueue(request, "DEPLOY_BETA")
		return reply.code(202).send({
			queued: true,
			job: serializeJob(job),
			note: "Beta is being rebuilt. Watch the job log; beta rolls itself back if it fails its health check.",
		})
	})

	/** Copy the release beta is running into prod. Code only, never data. */
	app.post("/api/admin/deploy/promote", async (request, reply) => {
		const beta = await probeChannel(BETA_ORIGIN, "beta")
		if (!beta.reachable) {
			throw badRequest(
				"Beta is not running. Start it, deploy to it and test it before promoting.",
			)
		}
		const job = await enqueue(request, "PROMOTE_BETA_TO_PROD")
		return reply.code(202).send({
			queued: true,
			job: serializeJob(job),
			promoting: { version: beta.version, migration: beta.migration },
			note: "Prod is backed up with pg_dump first. Only code moves; the prod database keeps its own rows.",
		})
	})

	/** Point prod back at the previous release. Code only. */
	app.post("/api/admin/deploy/rollback", async (request, reply) => {
		const job = await enqueue(request, "ROLLBACK_PROD")
		return reply.code(202).send({
			queued: true,
			job: serializeJob(job),
			note: "Rolling back code only. Rows written after the promote are kept; restore a dump manually if the schema must go back too.",
		})
	})

	/** Everything the channels panel needs in one call. */
	app.get("/api/admin/deploy/status", async (_request, reply) => {
		const [prod, beta, activeJob, recentJobs] = await Promise.all([
			probeChannel(PROD_ORIGIN, "prod"),
			probeChannel(BETA_ORIGIN, "beta"),
			prisma.deployJob.findFirst({
				where: { status: { in: ["QUEUED", "RUNNING"] } },
				include: { requestedBy: { select: { username: true, publicId: true } } },
			}),
			prisma.deployJob.findMany({
				orderBy: { createdAt: "desc" },
				take: 10,
				include: { requestedBy: { select: { username: true, publicId: true } } },
			}),
		])

		const lastPromote = recentJobs.find(
			(job) => job.action === "PROMOTE_BETA_TO_PROD" && job.status === "SUCCEEDED",
		)

		// A readiness checklist, so "can I promote?" is answered before clicking.
		const checks = [
			{
				id: "beta_running",
				label: "Beta is running",
				ok: beta.reachable,
				detail: beta.reachable ? `version ${beta.version}` : "beta is switched off",
			},
			{
				id: "beta_database",
				label: "Beta database reachable",
				ok: beta.database === "up",
				detail: beta.database ?? "unknown",
			},
			{
				id: "prod_healthy",
				label: "Prod is healthy right now",
				ok: prod.reachable && prod.database === "up",
				detail: prod.reachable ? `version ${prod.version}` : "prod unreachable",
			},
			{
				id: "versions_differ",
				label: "Beta differs from prod",
				ok: Boolean(beta.version && prod.version && beta.version !== prod.version),
				detail:
					beta.version && prod.version && beta.version === prod.version
						? "identical versions, nothing to promote"
						: `${prod.version ?? "?"} -> ${beta.version ?? "?"}`,
			},
			{
				id: "no_active_job",
				label: "No deployment in progress",
				ok: activeJob === null,
				detail: activeJob ? `${activeJob.action} is ${activeJob.status}` : "idle",
			},
		]

		return reply.send({
			currentChannel: config.CHANNEL,
			canDeploy: config.CHANNEL === "prod",
			channels: {
				prod: { ...prod, api: "api.gluk.tech", admin: "admin.gluk.tech" },
				beta: { ...beta, api: "beta-api.gluk.tech", admin: "beta-admin.gluk.tech" },
			},
			checks,
			promoteReady: checks.every((check) => check.ok),
			activeJob: activeJob ? serializeJob(activeJob) : null,
			lastPromote: lastPromote ? serializeJob(lastPromote) : null,
			jobs: recentJobs.map(serializeJob),
			serverTime: new Date().toISOString(),
		})
	})

	/** Job history with logs, for the panel's log viewer. */
	app.get("/api/admin/deploy/jobs", async (request, reply) => {
		const query = z
			.object({ limit: z.coerce.number().int().min(1).max(50).default(20) })
			.safeParse(request.query ?? {})
		const limit = query.success ? query.data.limit : 20

		const jobs = await prisma.deployJob.findMany({
			orderBy: { createdAt: "desc" },
			take: limit,
			include: { requestedBy: { select: { username: true, publicId: true } } },
		})
		return reply.send({ jobs: jobs.map(serializeJob) })
	})
}
