/**
 * Glue between the control plane's policy, the sing-box config on disk and the
 * Clash API. One instance per agent; `null` when this agent does not manage a
 * gateway (SINGBOX_MANAGE=false, or no config file on this machine).
 */
import { randomBytes } from "node:crypto"
import fs from "node:fs"
import path from "node:path"
import { config, persistCredentials } from "./config"
import type { ControlApi, GatewayInfo, NodePolicy, VlessUserReport } from "./lib/api"
import {
	attributeConnection,
	closeConnection,
	ConnectionTracker,
	fetchConnections,
	type ClashSnapshot,
} from "./lib/clash"
import { errorMessage, log } from "./lib/logger"
import {
	checkConfig,
	detectSingboxVersion,
	gatewayFromConfig,
	readConfig,
	renderConfig,
	type SingboxVersion,
	writeConfigAtomic,
} from "./lib/singbox"

/** Sidecar next to the config: which policy version the file currently holds. */
function versionFileFor(configFile: string): string {
	return path.join(path.dirname(configFile), `.${path.basename(configFile)}.policy-version`)
}

function cutoffFileFor(configFile: string): string {
	return path.join(path.dirname(configFile), `.${path.basename(configFile)}.policy-cutoff.json`)
}

type PersistedCutoff = { version: string; maintenance: boolean; users: string[] }

export class SingboxManager {
	readonly configFile: string
	readonly version: SingboxVersion | null
	appliedVersion: string | null
	private readonly clashSecret: string
	private readonly tracker: ConnectionTracker
	private lastSampleMs = 0
	private clashFailures = 0
	private syncing = false
	private maintenance = false
	private allowedUsers: Set<string> | null = null

	private constructor(configFile: string, version: SingboxVersion | null, clashSecret: string) {
		this.configFile = configFile
		this.version = version
		this.clashSecret = clashSecret
		this.tracker = new ConnectionTracker({ reportDomains: config.SINGBOX_REPORT_DOMAINS })
		this.appliedVersion = this.readAppliedVersion()
		this.readCutoff()
	}

	static async create(): Promise<SingboxManager | null> {
		if (!config.SINGBOX_MANAGE) {
			log.info("sing-box management disabled (SINGBOX_MANAGE=false)")
			return null
		}
		if (!fs.existsSync(config.SINGBOX_CONFIG)) {
			log.info("no sing-box config on this node, gateway features off", { file: config.SINGBOX_CONFIG })
			return null
		}
		try {
			fs.accessSync(config.SINGBOX_CONFIG, fs.constants.R_OK | fs.constants.W_OK)
			fs.accessSync(path.dirname(config.SINGBOX_CONFIG), fs.constants.W_OK)
		} catch {
			log.error("sing-box config is not writable by the agent", {
				file: config.SINGBOX_CONFIG,
				hint: "run node-agent/deploy/setup-singbox-agent.sh as root",
			})
			return null
		}

		let secret = config.SINGBOX_CLASH_SECRET ?? ""
		if (!secret) {
			secret = randomBytes(24).toString("base64url")
			try {
				persistCredentials({ SINGBOX_CLASH_SECRET: secret })
				log.info("generated a Clash API secret and saved it to the env file")
			} catch (error) {
				log.warn("could not persist the Clash API secret; using it for this run only", {
					reason: errorMessage(error),
				})
			}
		}

		const version = await detectSingboxVersion(config.SINGBOX_BIN)
		const manager = new SingboxManager(config.SINGBOX_CONFIG, version, secret)
		log.info("sing-box management enabled", {
			file: config.SINGBOX_CONFIG,
			singbox: version?.raw ?? "unknown version",
			clashApi: config.SINGBOX_CLASH_API,
			appliedPolicy: manager.appliedVersion ?? "none",
		})
		return manager
	}

	private readAppliedVersion(): string | null {
		try {
			const value = fs.readFileSync(versionFileFor(this.configFile), "utf8").trim()
			return value || null
		} catch {
			return null
		}
	}

	private writeAppliedVersion(version: string): void {
		try {
			fs.writeFileSync(versionFileFor(this.configFile), `${version}\n`, { mode: 0o640 })
		} catch (error) {
			log.warn("could not record the applied policy version", { reason: errorMessage(error) })
		}
	}

	private readCutoff(): void {
		try {
			const value = JSON.parse(fs.readFileSync(cutoffFileFor(this.configFile), "utf8")) as PersistedCutoff
			if (!value || !Array.isArray(value.users)) return
			this.maintenance = value.maintenance === true
			this.allowedUsers = new Set(value.users.filter((user) => typeof user === "string"))
		} catch {
			// No persisted cutoff on first install. The first heartbeat always fetches policy.
		}
	}

	private setCutoff(policy: NodePolicy): void {
		this.maintenance = policy.maintenance === true
		this.allowedUsers = new Set([
			...policy.users.map((user) => user.name),
			...(policy.legacyUser ? [policy.legacyUser.name] : []),
		])
		const persisted: PersistedCutoff = {
			version: policy.version,
			maintenance: this.maintenance,
			users: [...this.allowedUsers].sort(),
		}
		try {
			fs.writeFileSync(cutoffFileFor(this.configFile), `${JSON.stringify(persisted)}\n`, { mode: 0o640 })
		} catch (error) {
			log.warn("could not persist the connection cutoff", { reason: errorMessage(error) })
		}
	}

	private async enforceCutoff(snapshot?: ClashSnapshot): Promise<void> {
		if (!this.allowedUsers) return
		const current = snapshot ?? (await fetchConnections(config.SINGBOX_CLASH_API, this.clashSecret))
		const targets = (current.connections ?? []).filter((connection) => {
			const user = attributeConnection(connection)
			// Clash metadata does not expose the inbound authenticated user. We only
			// touch connections carrying one of our private u_<user> outbound tags,
			// so another channel sharing the sing-box instance is never mass-closed.
			return Boolean(user && (this.maintenance || !this.allowedUsers?.has(user)))
		})
		if (targets.length === 0) return

		const results = await Promise.allSettled(
			targets.map((connection) => closeConnection(config.SINGBOX_CLASH_API, this.clashSecret, connection.id)),
		)
		const closed = results.filter((result) => result.status === "fulfilled").length
		const failed = results.length - closed
		log.info("sing-box connection cutoff enforced", {
			reason: this.maintenance ? "maintenance" : "user-revoked",
			matched: targets.length,
			closed,
			failed,
		})
	}

	/** What the heartbeat should advertise; null when the config has no VLESS inbound. */
	gateway(): GatewayInfo | null {
		try {
			return gatewayFromConfig(readConfig(this.configFile), {
				publicHost: config.SINGBOX_PUBLIC_HOST,
				publicPort: config.SINGBOX_PUBLIC_PORT,
			})
		} catch (error) {
			log.warn("cannot read the sing-box config", { reason: errorMessage(error) })
			return null
		}
	}

	/**
	 * Fetches the policy and rewrites the managed parts of the config when the
	 * version differs from what is on disk. Safe to call often.
	 */
	async syncPolicy(api: ControlApi, reason: string): Promise<boolean> {
		if (this.syncing) return false
		this.syncing = true
		try {
			const { policy } = await api.policy()
			return this.applyPolicy(policy, reason)
		} finally {
			this.syncing = false
		}
	}

	async applyPolicy(policy: NodePolicy, reason: string): Promise<boolean> {
		const configChanged = policy.version !== this.appliedVersion || reason === "forced"
		if (!configChanged) {
			this.setCutoff(policy)
			await this.enforceCutoff().catch((error) => {
				log.warn("sing-box connection cutoff retry failed", { reason: errorMessage(error) })
			})
			return false
		}
		const base = readConfig(this.configFile)
		const rendered = renderConfig(base, policy, {
			clashApi: config.SINGBOX_CLASH_API,
			clashSecret: this.clashSecret,
			version: this.version,
		})

		// Validate through the real binary before touching the live file.
		const dir = path.dirname(this.configFile)
		const probe = path.join(dir, `.${path.basename(this.configFile)}.check.${process.pid}.json`)
		fs.writeFileSync(probe, JSON.stringify(rendered), { mode: 0o600 })
		try {
			const check = await checkConfig(config.SINGBOX_BIN, probe)
			if (!check.ok) {
				log.error("generated sing-box config was rejected; keeping the current file", {
					reason: check.reason,
					policyVersion: policy.version,
				})
				return false
			}
			if (check.reason) log.debug(check.reason)
		} finally {
			fs.rmSync(probe, { force: true })
		}

		writeConfigAtomic(this.configFile, rendered)
		this.appliedVersion = policy.version
		this.writeAppliedVersion(policy.version)
		this.setCutoff(policy)
		await this.enforceCutoff().catch((error) => {
			log.warn("sing-box connection cutoff failed after policy apply", { reason: errorMessage(error) })
		})
		log.info("sing-box policy applied", {
			policyVersion: policy.version,
			users: policy.users.length + (policy.legacyUser ? 1 : 0),
			rules: policy.rules.length + policy.builtinRules.length,
			reason,
		})
		return true
	}

	/** Samples the Clash API when the interval elapsed. Never throws. */
	async sample(now: number = Date.now()): Promise<void> {
		if (now - this.lastSampleMs < config.SINGBOX_STATS_INTERVAL_SEC * 1000) return
		this.lastSampleMs = now
		try {
			const snapshot = await fetchConnections(config.SINGBOX_CLASH_API, this.clashSecret)
			this.tracker.ingest(snapshot, now)
			await this.enforceCutoff(snapshot)
			if (this.clashFailures > 0) {
				log.info("clash api reachable again")
				this.clashFailures = 0
			}
		} catch (error) {
			this.clashFailures += 1
			// Loud once, then quiet: sing-box may simply be restarting.
			if (this.clashFailures === 1 || this.clashFailures % 100 === 0) {
				log.warn("clash api unreachable", {
					api: config.SINGBOX_CLASH_API,
					failures: this.clashFailures,
					reason: errorMessage(error),
					hint: "is experimental.clash_api enabled and the secret in sync? (a policy sync writes both)",
				})
			}
		}
	}

	drainReport(): VlessUserReport[] {
		return this.tracker.drain()
	}

	restoreReport(report: VlessUserReport[]): void {
		this.tracker.restore(report)
	}

	activeConnections(): number {
		return this.tracker.activeConnectionCount()
	}
}
