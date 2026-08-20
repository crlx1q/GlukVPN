/**
 * GlukVPN deploy worker.
 *
 * Runs as its own systemd service, polls the deploy_jobs queue and executes
 * ONE of three hard-coded scripts per job. Nothing from the database is ever
 * interpolated into a command line:
 *
 *   - the action is a Postgres enum with exactly three values;
 *   - each value maps to a fixed filename in this file;
 *   - the scripts are invoked with execFile and an EMPTY argument list, so no
 *     shell is spawned and no argument can be injected.
 *
 * That is what makes the admin "Promote" button a deployment button and not a
 * remote code execution endpoint. Adding a parameter to these scripts would
 * break that property - don't.
 *
 * Run:  ENV_FILE=/etc/vpn-control/control.env node dist/scripts/deployWorker.js
 */

import { execFile } from "node:child_process"
import path from "node:path"
import type { DeployAction } from "@prisma/client"
import { prisma } from "../prisma"

/** Fixed action -> script mapping. The only bridge between DB and disk. */
const SCRIPTS: Record<DeployAction, string> = {
	DEPLOY_BETA: "deploy-beta.sh",
	PROMOTE_BETA_TO_PROD: "promote.sh",
	ROLLBACK_PROD: "rollback.sh",
	// Beta lifecycle. Each action maps to exactly one script that takes no
	// arguments, so nothing a caller sends can influence what runs.
	START_BETA: "beta-start.sh",
	STOP_BETA: "beta-stop.sh",
	RESTART_BETA: "beta-restart.sh",
}

const SCRIPT_DIR = process.env.DEPLOY_SCRIPT_DIR ?? "/opt/glukvpn-deploy/bin"
const POLL_INTERVAL_MS = 3000
// npm ci on ARM can be slow; a promote must still never hang forever.
const SCRIPT_TIMEOUT_MS = 20 * 60 * 1000
const MAX_LOG_CHARS = 60_000

let stopping = false

function now(): string {
	return new Date().toISOString()
}

function info(message: string): void {
	console.log(`[${now()}] ${message}`)
}

/** Keep the tail: the failure reason is always at the end. */
function trimLog(text: string): string {
	if (text.length <= MAX_LOG_CHARS) return text
	return `... (truncated ${text.length - MAX_LOG_CHARS} chars)\n${text.slice(-MAX_LOG_CHARS)}`
}

function runScript(action: DeployAction): Promise<{
	exitCode: number
	output: string
}> {
	const script = path.join(SCRIPT_DIR, SCRIPTS[action])
	return new Promise((resolve) => {
		// No shell, no arguments, fixed path. See the header comment.
		execFile(
			script,
			[],
			{
				timeout: SCRIPT_TIMEOUT_MS,
				maxBuffer: 8 * 1024 * 1024,
				shell: false,
				env: {
					// Minimal environment. The scripts read their own constants and
					// the channel env files; they must not inherit our DATABASE_URL.
					PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
					HOME: "/root",
					LANG: "C.UTF-8",
				},
			},
			(error, stdout, stderr) => {
				const output = `${stdout}${stderr ? `\n--- stderr ---\n${stderr}` : ""}`
				if (!error) {
					resolve({ exitCode: 0, output })
					return
				}
				const code =
					typeof (error as { code?: unknown }).code === "number"
						? ((error as { code: number }).code)
						: 1
				const killed = (error as { killed?: boolean }).killed === true
				resolve({
					exitCode: code,
					output: killed
						? `${output}\n--- worker ---\ntimed out after ${SCRIPT_TIMEOUT_MS / 1000}s and was killed`
						: `${output}\n--- worker ---\n${error.message}`,
				})
			},
		)
	})
}

/** Pull the identifiers the scripts print, for the job record. */
function parseOutput(output: string): {
	releaseId: string | null
	previousReleaseId: string | null
	backupPath: string | null
} {
	const release = output.match(/activated ([0-9]{8}-[0-9]{6})/)
	const previous = output.match(/rollback target: ([0-9]{8}-[0-9]{6})/)
	const reverted = output.match(/reverting to: ([0-9]{8}-[0-9]{6})/)
	const backup = output.match(/backup written: (\S+\.dump)/)
	return {
		releaseId: release?.[1] ?? reverted?.[1] ?? null,
		previousReleaseId: previous?.[1] ?? null,
		backupPath: backup?.[1] ?? null,
	}
}

async function claimNextJob() {
	// One job at a time: a partial index in the database already guarantees a
	// single QUEUED/RUNNING row, so a plain findFirst is enough here.
	const job = await prisma.deployJob.findFirst({
		where: { status: "QUEUED" },
		orderBy: { createdAt: "asc" },
	})
	if (!job) return null

	return prisma.deployJob.update({
		where: { id: job.id },
		data: { status: "RUNNING", startedAt: new Date() },
	})
}

async function processJob(): Promise<boolean> {
	const job = await claimNextJob()
	if (!job) return false

	info(`job ${job.id}: ${job.action} started`)
	const { exitCode, output } = await runScript(job.action)
	const parsed = parseOutput(output)

	await prisma.deployJob.update({
		where: { id: job.id },
		data: {
			status: exitCode === 0 ? "SUCCEEDED" : "FAILED",
			exitCode,
			log: trimLog(output),
			releaseId: parsed.releaseId,
			previousReleaseId: parsed.previousReleaseId,
			backupPath: parsed.backupPath,
			finishedAt: new Date(),
		},
	})

	await prisma.auditLog.create({
		data: {
			userId: job.requestedById,
			action: exitCode === 0 ? "deploy.job.succeeded" : "deploy.job.failed",
			metadata: {
				jobId: job.id,
				deployAction: job.action,
				exitCode,
				releaseId: parsed.releaseId,
			},
		},
	})

	info(`job ${job.id}: ${job.action} finished with exit ${exitCode}`)
	return true
}

/**
 * A RUNNING row left behind means the worker (or the machine) died mid-job.
 * Mark it failed so the queue is not blocked forever; the scripts themselves
 * are safe to re-run.
 */
async function recoverOrphans(): Promise<void> {
	const orphans = await prisma.deployJob.updateMany({
		where: { status: "RUNNING" },
		data: {
			status: "FAILED",
			finishedAt: new Date(),
			exitCode: -1,
			log: "Worker restarted while this job was running. Check journalctl -u glukvpn-deploy-worker and the channel health before retrying.",
		},
	})
	if (orphans.count > 0) {
		info(`marked ${orphans.count} interrupted job(s) as failed`)
	}
}

async function main(): Promise<void> {
	info(`deploy worker starting, scripts in ${SCRIPT_DIR}`)
	await recoverOrphans()

	while (!stopping) {
		try {
			const didWork = await processJob()
			if (!didWork) {
				await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS))
			}
		} catch (error) {
			// Never let a transient database error kill the worker.
			info(`poll error: ${error instanceof Error ? error.message : String(error)}`)
			await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS))
		}
	}

	await prisma.$disconnect()
	info("deploy worker stopped")
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
	process.on(signal, () => {
		info(`${signal} received, finishing current job then exiting`)
		stopping = true
	})
}

main().catch((error) => {
	console.error(`[${now()}] fatal:`, error)
	process.exit(1)
})
