import type { FastifyInstance } from "fastify"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { prisma } from "../prisma"
import { expireStaleOrders } from "./billing"
import { purgeLinkRequests } from "./linkAuth"
import { purgeOldLoginAttempts } from "./loginThrottle"
import { requeueStaleCommands } from "./nodeCommands"
import { sweepExpiredRegistrations } from "./registration"
import { closeSession } from "./sessions"
import { purgeOldClientErrors } from "./telemetry"
import { purgeExpiredCodes } from "./verification"
import { purgeOldDomainStats } from "./vlessStats"

export type MonitorTickResult = {
	nodesMarkedOffline: number
	subscriptionsExpired: number
	sessionsClosed: number
	leasesReclaimed: number
	commandsRequeued: number
	commandsFailed: number
}

// A tunnel is torn down only after the node has been silent for a while: a
// single missed heartbeat must not disconnect a working session.
const NODE_HARD_OFFLINE_FACTOR = 4
// Grace period before a closed session's tunnel IP returns to the pool.
const LEASE_RECLAIM_AFTER_SEC = 300

export async function runMonitorTick(): Promise<MonitorTickResult> {
	const now = Date.now()
	const staleCutoff = new Date(now - config.NODE_OFFLINE_AFTER_SEC * 1000)
	const hardCutoff = new Date(
		now - config.NODE_OFFLINE_AFTER_SEC * NODE_HARD_OFFLINE_FACTOR * 1000,
	)

	// 1. Nodes that stopped sending heartbeats become OFFLINE.
	const offlineNodes = await prisma.vpnNode.findMany({
		where: {
			status: "ONLINE",
			OR: [{ lastHeartbeat: null }, { lastHeartbeat: { lt: staleCutoff } }],
		},
		select: { id: true, name: true },
	})
	if (offlineNodes.length > 0) {
		await prisma.vpnNode.updateMany({
			where: { id: { in: offlineNodes.map((node) => node.id) } },
			data: { status: "OFFLINE" },
		})
		for (const node of offlineNodes) {
			await writeAudit({
				action: "node.offline",
				nodeId: node.id,
				metadata: { name: node.name, offlineAfterSec: config.NODE_OFFLINE_AFTER_SEC },
			})
		}
	}

	// 2. Expire subscriptions that ran out.
	const expired = await prisma.subscription.updateMany({
		where: { status: "ACTIVE", expiresAt: { lte: new Date() } },
		data: { status: "EXPIRED" },
	})

	// 3. Close sessions that must not stay open.
	let sessionsClosed = 0
	const liveSessions = await prisma.session.findMany({
		where: { status: { in: ["PENDING", "ACTIVE"] } },
		include: {
			user: {
				include: {
					subscriptions: {
						where: { status: "ACTIVE", expiresAt: { gt: new Date() } },
						take: 1,
					},
				},
			},
			device: true,
			node: true,
		},
	})

	for (const session of liveSessions) {
		let reason: string | null = null
		if (session.user.status !== "ACTIVE") reason = "user_disabled"
		else if (session.device.status !== "ACTIVE") reason = "device_revoked"
		else if (session.user.subscriptions.length === 0) reason = "subscription_expired"
		else if (session.node.status === "DISABLED") reason = "node_disabled"
		else if (
			!session.node.lastHeartbeat ||
			session.node.lastHeartbeat.getTime() < hardCutoff.getTime()
		) {
			reason = "node_offline"
		}

		if (reason) {
			await closeSession({ sessionId: session.id, reason })
			sessionsClosed += 1
		}
	}

	// 4. Retry commands the agent never acknowledged.
	const commandWindow = Math.max(60, config.NODE_HEARTBEAT_INTERVAL_SEC * 6)
	const { requeued, failed } = await requeueStaleCommands(commandWindow, 5)

	// 5. Reclaim tunnel IPs from long-closed sessions (safety net if a node
	// never confirmed REMOVE_PEER).
	const reclaimCutoff = new Date(now - LEASE_RECLAIM_AFTER_SEC * 1000)
	const staleLeases = await prisma.ipLease.findMany({
		where: {
			sessionId: { not: null },
			session: {
				is: {
					status: { in: ["CLOSED", "FAILED"] },
					disconnectedAt: { lt: reclaimCutoff },
				},
			},
		},
		select: { id: true },
	})
	if (staleLeases.length > 0) {
		await prisma.ipLease.updateMany({
			where: { id: { in: staleLeases.map((lease) => lease.id) } },
			data: { sessionId: null, allocatedAt: null },
		})
	}

	return {
		nodesMarkedOffline: offlineNodes.length,
		subscriptionsExpired: expired.count,
		sessionsClosed,
		leasesReclaimed: staleLeases.length,
		commandsRequeued: requeued,
		commandsFailed: failed,
	}
}

export type MonitorHandle = { stop: () => void }

/**
 * Background loop: node liveness, subscription enforcement, command retries
 * and lease housekeeping. Runs at the heartbeat interval.
 */
export function startMonitor(app: FastifyInstance): MonitorHandle {
	let ticks = 0
	let running = false

	const tick = async (): Promise<void> => {
		if (running) return
		running = true
		try {
			const result = await runMonitorTick()
			if (
				result.nodesMarkedOffline > 0 ||
				result.sessionsClosed > 0 ||
				result.subscriptionsExpired > 0 ||
				result.commandsFailed > 0
			) {
				app.log.info({ monitor: result }, "monitor_tick")
			}
			ticks += 1
			// Roughly every 10 minutes at a 10s interval.
			if (ticks % 60 === 0) {
				const purged = await purgeOldLoginAttempts()
				if (purged > 0) app.log.debug({ purged }, "login_attempts_purged")

				// Sign-ups that were never finished, and codes nobody used.
				//
				// Both are already refused on age when they are looked up, so this
				// is housekeeping rather than enforcement: it keeps the tables from
				// growing without bound and keeps a stale e-mail address from
				// blocking a genuine second attempt at registering.
				const registrations = await sweepExpiredRegistrations()
				if (registrations > 0) {
					app.log.debug({ registrations }, "pending_registrations_swept")
				}
				const codes = await purgeExpiredCodes(7)
				if (codes > 0) app.log.debug({ codes }, "verification_codes_purged")

				// Sign-in links are single-use and five minutes long; finished rows
				// only need to outlive a straggling client by one more TTL.
				const links = await purgeLinkRequests()
				if (links > 0) app.log.debug({ links }, "link_requests_purged")

				// Domain statistics have a retention window; a checkout nobody
				// finished within a day is closed so it does not sit as "pending".
				const domains = await purgeOldDomainStats()
				if (domains > 0) app.log.debug({ domains }, "domain_stats_purged")

				// Crash reports age out on the same schedule. Without this the
				// table only ever grows, and a single bad release can add tens of
				// thousands of rows in an afternoon.
				const clientErrors = await purgeOldClientErrors(
					config.CLIENT_ERROR_RETENTION_DAYS,
				)
				if (clientErrors > 0) {
					app.log.debug({ clientErrors }, "client_errors_purged")
				}
				const orders = await expireStaleOrders()
				if (orders > 0) app.log.debug({ orders }, "stale_orders_cancelled")
			}
		} catch (error) {
			app.log.error({ err: error }, "monitor_tick_failed")
		} finally {
			running = false
		}
	}

	void tick()
	const timer = setInterval(() => {
		void tick()
	}, config.NODE_HEARTBEAT_INTERVAL_SEC * 1000)
	// Never keep the process alive just for the monitor.
	timer.unref()

	return {
		stop: () => clearInterval(timer),
	}
}
