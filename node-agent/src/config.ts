/**
 * Node agent configuration.
 *
 * Values come from the environment file only (default /etc/vpn-node-agent/agent.env,
 * override with ENV_FILE). Nothing here is ever sent to the control plane except
 * the node identity fields used during enrollment.
 */
import fs from "node:fs"
import path from "node:path"
import dotenv from "dotenv"
import { z } from "zod"

export const ENV_FILE =
	process.env.ENV_FILE && process.env.ENV_FILE.trim() !== ""
		? path.resolve(process.env.ENV_FILE)
		: "/etc/vpn-node-agent/agent.env"

function loadEnvFile(): void {
	if (fs.existsSync(ENV_FILE)) {
		dotenv.config({ path: ENV_FILE, override: false })
		return
	}
	// Development fallback: a local .env next to the package.
	const localEnv = path.resolve(__dirname, "..", ".env")
	if (fs.existsSync(localEnv)) dotenv.config({ path: localEnv, override: false })
}

loadEnvFile()

const optionalString = z
	.string()
	.trim()
	.transform((value) => (value === "" ? null : value))
	.nullable()
	.default(null)

const positiveInt = (fallback: number) =>
	z.coerce.number().int().positive().default(fallback)

const Schema = z.object({
	// Control plane
	CONTROL_API_URL: z
		.string()
		.trim()
		.url("CONTROL_API_URL must be a URL")
		.transform((value) => value.replace(/\/+$/, "")),

	// Identity used at enrollment time
	NODE_NAME: z
		.string()
		.trim()
		.min(2)
		.max(48)
		.regex(/^[a-z0-9][a-z0-9-]*$/, "NODE_NAME must be lowercase letters, digits and dashes"),
	NODE_COUNTRY: z.string().trim().min(2).max(64).default("Germany"),
	NODE_COUNTRY_CODE: z
		.string()
		.trim()
		.length(2)
		.transform((value) => value.toUpperCase())
		.default("DE"),
	NODE_PUBLIC_IP: optionalString,
	NODE_HOSTNAME: optionalString,

	// Credentials
	NODE_ENROLLMENT_TOKEN: optionalString,
	NODE_ID: optionalString,
	NODE_TOKEN: optionalString,

	// WireGuard
	WG_INTERFACE: z
		.string()
		.trim()
		.regex(/^[a-z0-9_.-]{2,15}$/i, "WG_INTERFACE must be a valid interface name")
		.default("wg0"),
	WG_LISTEN_PORT: positiveInt(51820),
	WG_ADDRESS: z.string().trim().default("10.8.0.1/24"),
	WG_SUBNET: z.string().trim().default("10.8.0.0/24"),
	WG_MTU: positiveInt(1420),
	WG_EGRESS_INTERFACE: optionalString,

	// Timings
	HEARTBEAT_INTERVAL_SEC: positiveInt(10),
	COMMAND_POLL_INTERVAL_SEC: positiveInt(3),
	STATS_REPORT_INTERVAL_SEC: positiveInt(30),
	HTTP_TIMEOUT_MS: positiveInt(15000),

	LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
	AGENT_VERSION: z.string().trim().default("0.1.0"),
})

export type AgentConfig = z.infer<typeof Schema>

function parseConfig(): AgentConfig {
	const parsed = Schema.safeParse(process.env)
	if (!parsed.success) {
		const issues = parsed.error.issues
			.map((issue) => `${issue.path.join(".")}: ${issue.message}`)
			.join("; ")
		// Only names of invalid variables are printed, never their values.
		throw new Error(`Invalid node agent configuration (${ENV_FILE}): ${issues}`)
	}
	return parsed.data
}

export const config: AgentConfig = parseConfig()

/** True when the agent already has credentials and can run the main loop. */
export function hasNodeCredentials(current: AgentConfig = config): boolean {
	return Boolean(current.NODE_ID && current.NODE_TOKEN)
}

/**
 * Persists enrollment results back into the env file, preserving comments and
 * unrelated lines. The file is written with 0600 permissions.
 */
export function persistCredentials(values: Record<string, string>): void {
	const dir = path.dirname(ENV_FILE)
	if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true, mode: 0o700 })

	const existing = fs.existsSync(ENV_FILE)
		? fs.readFileSync(ENV_FILE, "utf8").split("\n")
		: []
	const remaining = new Map(Object.entries(values))

	const updated = existing.map((line) => {
		const match = /^([A-Z0-9_]+)=/.exec(line.trim())
		if (!match) return line
		const [key] = line.split("=")
		if (!key || !remaining.has(key)) return line
		const value = remaining.get(key) as string
		remaining.delete(key)
		return `${key}=${value}`
	})

	for (const [key, value] of remaining) updated.push(`${key}=${value}`)

	const content = `${updated.join("\n").replace(/\n+$/, "")}\n`
	fs.writeFileSync(ENV_FILE, content, { mode: 0o600 })
	fs.chmodSync(ENV_FILE, 0o600)
}
