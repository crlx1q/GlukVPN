/**
 * GlukVPN node agent.
 *
 * Pull model only: the node opens outbound HTTPS to the control plane and never
 * listens on an extra port. The heartbeat doubles as the command channel.
 *
 * What this agent can do, and nothing more:
 *   - report host metrics (CPU / RAM / uptime / peer count)
 *   - add a WireGuard peer with exactly one /32 allowed-ip
 *   - remove a WireGuard peer
 *   - report per-peer byte counters and handshake times
 *   - ROUND 26: keep the sing-box gateway's *users* and *reject rules* equal
 *     to the control plane's policy, and read sing-box's Clash API to report
 *     per-device traffic and sniffed host names
 *   - rotate its own node token
 *
 * There is deliberately no way to make this agent execute an arbitrary command:
 * the command handler is a closed switch over four known types, and the policy
 * can only ever become `direct` outbounds and `reject` rules.
 */
import {
	config,
	hasNodeCredentials,
	persistCredentials,
} from "./config"
import {
	ApiError,
	ControlApi,
	type HeartbeatBody,
	type NodeCommand,
	type PeerReport,
	type VlessUserReport,
} from "./lib/api"
import { errorMessage, log, shortKey } from "./lib/logger"
import { collectHostMetrics } from "./lib/metrics"
import {
	addPeer,
	dumpInterface,
	interfaceExists,
	interfacePublicKey,
	isValidWgKey,
	removePeer,
} from "./lib/wg"
import { SingboxManager } from "./singboxManager"

const TOKEN_ROTATION_MARGIN_MS = 3 * 24 * 60 * 60 * 1000 // rotate 3 days before expiry
const MAX_AUTH_FAILURES = 5
const MAX_BACKOFF_MS = 60_000

type AgentState = {
	running: boolean
	lastMetricsHeartbeatMs: number
	lastReportMs: number
	lastRotationAttemptMs: number
	consecutiveAuthFailures: number
	backoffMs: number
	nodePublicKey: string | null
	singbox: SingboxManager | null
	/** Desired policy version from the last heartbeat; null until known. */
	desiredPolicyVersion: string | null
}

const state: AgentState = {
	running: true,
	lastMetricsHeartbeatMs: 0,
	lastReportMs: 0,
	lastRotationAttemptMs: 0,
	consecutiveAuthFailures: 0,
	backoffMs: 0,
	nodePublicKey: null,
	singbox: null,
	desiredPolicyVersion: null,
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Extracts the single IPv4 address out of an ADD_PEER payload. */
function parseAssignedIp(payload: Record<string, unknown>): string | null {
	const allowedIps = payload.allowedIps
	const first = Array.isArray(allowedIps) ? allowedIps[0] : null
	const candidate =
		typeof first === "string"
			? first
			: typeof payload.assignedVpnIp === "string"
				? payload.assignedVpnIp
				: null
	if (!candidate) return null
	const ip = candidate.split("/")[0]?.trim() ?? ""
	return /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) ? ip : null
}

function parsePublicKey(payload: Record<string, unknown>): string | null {
	const key = payload.publicKey
	return typeof key === "string" && isValidWgKey(key) ? key : null
}

/**
 * Executes one command. Returns an error message on failure so the control
 * plane can mark the command (and its session) as failed.
 */
async function runCommand(api: ControlApi, command: NodeCommand): Promise<string | null> {
	switch (command.type) {
		case "SYNC_POLICY": {
			if (!state.singbox) return "this agent does not manage a sing-box gateway"
			await state.singbox.syncPolicy(api, "command")
			return null
		}
		case "ADD_PEER": {
			const publicKey = parsePublicKey(command.payload)
			const assignedIp = parseAssignedIp(command.payload)
			if (!publicKey) return "invalid or missing peer public key"
			if (!assignedIp) return "invalid or missing allowed-ip"
			await addPeer({
				iface: config.WG_INTERFACE,
				publicKey,
				assignedIp,
			})
			log.info("peer added", { peer: shortKey(publicKey), ip: assignedIp })
			return null
		}
		case "REMOVE_PEER": {
			const publicKey = parsePublicKey(command.payload)
			if (!publicKey) return "invalid or missing peer public key"
			// `wg set ... remove` is idempotent: a missing peer is not an error.
			await removePeer({ iface: config.WG_INTERFACE, publicKey })
			log.info("peer removed", { peer: shortKey(publicKey) })
			return null
		}
		case "SYNC_PEERS": {
			// Force a fresh report on the next tick; the control plane answers with
			// the authoritative removePeers / missingPeers lists.
			state.lastReportMs = 0
			return null
		}
		default: {
			// Unknown command types are refused, never interpreted.
			return `unsupported command type: ${String((command as { type?: unknown }).type)}`
		}
	}
}

async function handleCommands(api: ControlApi, commands: NodeCommand[]): Promise<void> {
	for (const command of commands) {
		let failure: string | null = null
		try {
			failure = await runCommand(api, command)
		} catch (error) {
			failure = errorMessage(error)
		}

		if (failure) {
			log.warn("command failed", { commandId: command.id, type: command.type, reason: failure })
		}
		try {
			await api.ackCommand(command.id, {
				ok: failure === null,
				...(failure ? { error: failure.slice(0, 300) } : {}),
			})
		} catch (error) {
			// The control plane requeues unacked commands, so this is recoverable.
			log.warn("ack failed", { commandId: command.id, reason: errorMessage(error) })
		}
	}
}

/** Sends WireGuard counters (and sing-box deltas) and reconciles peer drift. */
async function sendReport(api: ControlApi): Promise<void> {
	const wgState = await dumpInterface(config.WG_INTERFACE)
	const peers: PeerReport[] = wgState.peers.map((peer) => ({
		publicKey: peer.publicKey,
		bytesRx: peer.bytesRx,
		bytesTx: peer.bytesTx,
		lastHandshakeAt: peer.lastHandshakeAt,
	}))

	// Take the sing-box deltas out of the tracker; if the request fails they
	// go back in, so a control-plane hiccup never loses traffic.
	const vless: VlessUserReport[] | undefined = state.singbox ? state.singbox.drainReport() : undefined
	let result
	try {
		result = await api.report(peers, vless)
	} catch (error) {
		if (vless && state.singbox) state.singbox.restoreReport(vless)
		throw error
	}
	state.lastReportMs = Date.now()
	if (result.vless?.unknownUsers?.length) {
		log.debug("vless traffic for users without a live session", {
			users: result.vless.unknownUsers.length,
		})
	}

	// Peers the control plane has no live session for: remove them.
	for (const publicKey of result.removePeers ?? []) {
		if (!isValidWgKey(publicKey)) continue
		try {
			await removePeer({ iface: config.WG_INTERFACE, publicKey })
			log.info("stale peer removed", { peer: shortKey(publicKey) })
		} catch (error) {
			log.warn("stale peer removal failed", {
				peer: shortKey(publicKey),
				reason: errorMessage(error),
			})
		}
	}

	// Sessions the control plane thinks are live but have no peer here. The agent
	// does not invent peers: the control plane decides whether to close them.
	if (result.missingPeers?.length) {
		log.warn("live sessions without a local peer", {
			count: result.missingPeers.length,
			sessions: result.missingPeers.map((entry) => entry.sessionId),
		})
	}
}

async function maybeRotateToken(api: ControlApi, expiresAt: string | null): Promise<void> {
	if (!expiresAt) return
	const expiresMs = Date.parse(expiresAt)
	if (Number.isNaN(expiresMs)) return
	if (expiresMs - Date.now() > TOKEN_ROTATION_MARGIN_MS) return
	// The rotate endpoint is rate limited (5/hour): try at most once per hour.
	if (Date.now() - state.lastRotationAttemptMs < 60 * 60 * 1000) return

	state.lastRotationAttemptMs = Date.now()
	try {
		const rotated = await api.rotateToken()
		persistCredentials({ NODE_TOKEN: rotated.nodeToken })
		api.setToken(rotated.nodeToken)
		log.info("node token rotated", { expiresAt: rotated.nodeTokenExpiresAt })
	} catch (error) {
		log.warn("token rotation failed", { reason: errorMessage(error) })
	}
}

async function tick(api: ControlApi): Promise<void> {
	const now = Date.now()
	const withMetrics = now - state.lastMetricsHeartbeatMs >= config.HEARTBEAT_INTERVAL_SEC * 1000

	// sing-box counters are sampled on every tick (the interval is enforced
	// inside), independent of whether this tick carries metrics.
	if (state.singbox) await state.singbox.sample(now)

	let body: HeartbeatBody = {}
	if (withMetrics) {
		const [metrics, wgState] = await Promise.all([
			collectHostMetrics(config.WG_INTERFACE),
			dumpInterface(config.WG_INTERFACE).catch(() => null),
		])
		if (wgState?.interfacePublicKey) state.nodePublicKey = wgState.interfacePublicKey
		body = {
			cpuPercent: metrics.cpuPercent,
			ramPercent: metrics.ramPercent,
			uptimeSeconds: metrics.uptimeSeconds,
			peerCount: wgState?.peers.length ?? 0,
			agentVersion: config.AGENT_VERSION,
			...(state.nodePublicKey ? { wireguardPublicKey: state.nodePublicKey } : {}),
			// Only an agent that manages a gateway speaks about it: an explicit
			// null means "this node runs none", absence means "not my business".
			...(state.singbox
				? { gateway: state.singbox.gateway(), policyVersion: state.singbox.appliedVersion ?? "" }
				: {}),
		}
		state.lastMetricsHeartbeatMs = now
	}

	const heartbeat = await api.heartbeat(body)
	state.consecutiveAuthFailures = 0
	state.backoffMs = 0

	if (withMetrics) {
		log.debug("heartbeat", {
			nodeStatus: heartbeat.nodeStatus,
			peers: body.peerCount,
			cpu: body.cpuPercent,
			ram: body.ramPercent,
			commands: heartbeat.commands?.length ?? 0,
			policy: heartbeat.policyVersion ?? null,
		})
	}

	if (heartbeat.commands?.length) {
		await handleCommands(api, heartbeat.commands)
	}

	// Policy drift: the control plane names the version it wants, the file on
	// disk says which one it holds. A difference costs one GET and one reload.
	if (state.singbox && heartbeat.policyVersion) {
		state.desiredPolicyVersion = heartbeat.policyVersion
		if (heartbeat.policyVersion !== state.singbox.appliedVersion) {
			try {
				await state.singbox.syncPolicy(api, "heartbeat")
			} catch (error) {
				log.warn("policy sync failed", { reason: errorMessage(error) })
			}
		}
	}

	if (Date.now() - state.lastReportMs >= config.STATS_REPORT_INTERVAL_SEC * 1000) {
		await sendReport(api)
	}

	await maybeRotateToken(api, heartbeat.nodeTokenExpiresAt)
}

async function main(): Promise<void> {
	if (!hasNodeCredentials()) {
		log.error("missing node credentials", {
			hint: "run the enroll script first: node dist/scripts/enroll.js",
		})
		process.exit(78) // EX_CONFIG
	}

	if (!(await interfaceExists(config.WG_INTERFACE))) {
		log.error("wireguard interface is down", {
			iface: config.WG_INTERFACE,
			hint: `sudo systemctl enable --now wg-quick@${config.WG_INTERFACE}`,
		})
		process.exit(78)
	}

	try {
		state.nodePublicKey = await interfacePublicKey(config.WG_INTERFACE)
	} catch (error) {
		log.error("cannot read the wireguard public key", { reason: errorMessage(error) })
		process.exit(78)
	}

	const api = new ControlApi({
		nodeId: config.NODE_ID as string,
		nodeToken: config.NODE_TOKEN as string,
	})

	state.singbox = await SingboxManager.create()

	log.info("agent started", {
		controlApi: config.CONTROL_API_URL,
		iface: config.WG_INTERFACE,
		nodeKey: shortKey(state.nodePublicKey),
		heartbeatSec: config.HEARTBEAT_INTERVAL_SEC,
		pollSec: config.COMMAND_POLL_INTERVAL_SEC,
		reportSec: config.STATS_REPORT_INTERVAL_SEC,
		singbox: state.singbox ? "managed" : "off",
	})

	const shutdown = (signal: string) => {
		if (!state.running) return
		state.running = false
		// Peers are intentionally left in place: restarting the agent must not
		// drop live tunnels.
		log.info("shutting down", { signal })
	}
	process.on("SIGTERM", () => shutdown("SIGTERM"))
	process.on("SIGINT", () => shutdown("SIGINT"))

	while (state.running) {
		try {
			await tick(api)
		} catch (error) {
			if (error instanceof ApiError && error.isAuthFailure) {
				state.consecutiveAuthFailures += 1
				log.error("control plane rejected the node token", {
					status: error.status,
					code: error.code,
					attempt: state.consecutiveAuthFailures,
				})
				if (state.consecutiveAuthFailures >= MAX_AUTH_FAILURES) {
					log.error("node credential is no longer valid, re-enrollment required", {
						hint: "issue a new enrollment token on the control server, then run the enroll script with --force",
					})
					process.exit(78)
				}
			} else if (error instanceof ApiError) {
				log.warn("control plane request failed", {
					status: error.status,
					code: error.code,
					reason: error.message,
				})
			} else {
				log.warn("tick failed", { reason: errorMessage(error) })
			}
			// Exponential backoff, capped, so an outage does not hammer the API.
			state.backoffMs = Math.min(
				MAX_BACKOFF_MS,
				state.backoffMs === 0 ? config.COMMAND_POLL_INTERVAL_SEC * 1000 : state.backoffMs * 2,
			)
		}

		const waitMs = state.backoffMs || config.COMMAND_POLL_INTERVAL_SEC * 1000
		await sleep(waitMs)
	}

	log.info("agent stopped")
	process.exit(0)
}

void main()
