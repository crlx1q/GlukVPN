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
	// Shown in the app as the second line of a server row ("Frankfurt").
	// Set these on the node so no geography is ever hardcoded in the client.
	NODE_REGION: optionalString,
	NODE_CITY: optionalString,
	// Optional ICMP-friendly host for latency checks; defaults to the node host.
	NODE_PING_TARGET: optionalString,
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

	// sing-box VLESS gateway (ROUND 26).
	//
	// When SINGBOX_MANAGE is true the agent owns the *users* and *route rules*
	// of the sing-box config: it merges the policy from the control plane into
	// SINGBOX_CONFIG (everything else in the file - TLS, listen port, log - is
	// left untouched), and reads sing-box's Clash API to attribute traffic to
	// devices. Only one agent per machine may manage a given config file: the
	// beta agent runs with SINGBOX_MANAGE=false.
	SINGBOX_MANAGE: z
		.enum(["true", "false", "1", "0"])
		.default("true")
		.transform((value) => value === "true" || value === "1"),
	SINGBOX_CONFIG: z.string().trim().default("/etc/glukvpn/singbox.json"),
	SINGBOX_BIN: z.string().trim().default("/usr/local/bin/sing-box"),
	// host:port of experimental.clash_api.external_controller. Loopback only.
	SINGBOX_CLASH_API: z
		.string()
		.trim()
		.regex(/^(127\.\d+\.\d+\.\d+|localhost|\[::1\]):\d{2,5}$/, "SINGBOX_CLASH_API must be a loopback host:port")
		.default("127.0.0.1:9090"),
	// Bearer secret for the Clash API. Generated and written back to this file
	// on first run when empty.
	SINGBOX_CLASH_SECRET: optionalString,
	// What clients connect to. Defaults: the TLS server_name from the config
	// and 443 - the public port when nginx stream fronts sing-box on 443 and
	// hands the VPN SNI to sing-box's own (internal) listen_port.
	SINGBOX_PUBLIC_HOST: optionalString,
	SINGBOX_PUBLIC_PORT: positiveInt(443),
	// How often /connections is sampled. Short-lived connections that live
	// entirely between two samples are still counted (their final bytes show
	// up in the sample where they last appeared), so 3s is plenty.
	SINGBOX_STATS_INTERVAL_SEC: positiveInt(3),
	// Send sniffed host names per device along with the byte counters.
	SINGBOX_REPORT_DOMAINS: z
		.enum(["true", "false", "1", "0"])
		.default("true")
		.transform((value) => value === "true" || value === "1"),

	// Traffic shaping (ROUND 27).
	//
	// The control plane sends the plan's line speed with every ADD_PEER and the
	// agent turns it into a tc/HTB class on the WireGuard interface. Set this to
	// false on a node whose kernel has no HTB: it then forwards unshaped instead
	// of logging a failed command on every connect.
	SHAPING_ENABLED: z
		.enum(["true", "false", "1", "0"])
		.default("true")
		.transform((value) => value === "true" || value === "1"),
	// What this machine's uplink can actually do. HTB needs a ceiling for the
	// root class. The per-peer ceilings are deliberately allowed to add up to
	// more than this, which is what makes a quiet link fast.
	SHAPING_UPLINK_MBIT: positiveInt(1000),
	// How much of its plan speed a device keeps even on a congested link. The
	// rest is borrowed, in plan-priority order.
	SHAPING_GUARANTEE_PERCENT: z.coerce.number().int().min(1).max(100).default(25),

	// Shaped VLESS front door (ROUND 27, re-architected in ROUND 28).
	//
	// tc above only ever sees the WireGuard interface, so it caps the phone and
	// nothing else. The desktop client talks VLESS to sing-box, and until this
	// existed a 30 Mbit/s account downloaded at line rate. These listeners sit
	// in front of sing-box and cap the outer stream.
	//
	// ROUND 27 gave every tier its own *external* port (2053, 2083, ...), which
	// cannot work here: this node lives in Oracle Cloud, where the VCN closes
	// every port except 443, so a capped client got connect_timeout instead of a
	// slow tunnel - and a non-standard port is the first thing an ISP or a hotel
	// Wi-Fi drops. ROUND 28 keeps exactly one port open to the world:
	//
	//   client -> 443 (nginx stream, ssl_preread)
	//              |- SNI de-01.gluk.tech         -> sing-box        (unlimited)
	//              `- SNI speed30.de-01.gluk.tech -> 127.0.0.1:8460 -> sing-box
	//
	// So the relays bind loopback and their ports are an internal detail; the
	// control plane hands a capped account the SNI of its tier
	// (VLESS_SPEED_TIERS there), never a port.
	SHAPING_GATEWAY_ENABLED: z
		.enum(["true", "false", "1", "0"])
		.default("true")
		.transform((value) => value === "true" || value === "1"),
	// The speeds sold in the admin panel, port-less: "30,50,100,250,500".
	// Ports are assigned from SHAPING_GATEWAY_BASE_PORT in ascending speed
	// order, and the generated nginx map uses the same rule. A tier may pin its
	// own port as "<mbit>=<port>" on a node where that range is taken.
	SHAPING_GATEWAY_SPEEDS: z.string().trim().default("30,50,100,250,500"),
	// First loopback port for the shaped relays. The range must be free: 443 is
	// nginx, 8445 is sing-box, 8443 and 8444 are the prod and beta browser
	// proxies, 51820 is WireGuard.
	SHAPING_GATEWAY_BASE_PORT: positiveInt(8460),
	// Where the relays listen. Loopback, and not negotiable in practice: a
	// shaped port reachable from outside is a way to pick your own speed.
	SHAPING_GATEWAY_BIND_HOST: z.string().trim().default("127.0.0.1"),
	// Legacy ROUND 27 pairs, e.g. "30=2053,100=2083". Empty (the default) means
	// the speed list above is used instead. When set it wins, so a node that
	// still has external shaped ports keeps working unchanged.
	SHAPING_GATEWAY_TIERS: z.string().trim().default(""),
	// Where sing-box actually accepts VLESS. This must be sing-box's own
	// listen_port and NOT the public 443: nginx stream owns 443 and routes by
	// SNI, so forwarding a shaped stream back to 443 would send it through the
	// same map and straight back into this relay.
	SHAPING_GATEWAY_TARGET_HOST: z.string().trim().default("127.0.0.1"),
	SHAPING_GATEWAY_TARGET_PORT: positiveInt(8445),
	// Short burst, or the first chunk of every connection would wait for budget
	// and the cap would read as latency instead of as a speed limit.
	SHAPING_GATEWAY_BURST_SECONDS: z.coerce.number().min(0.05).max(2).default(0.25),

	// Timings
	HEARTBEAT_INTERVAL_SEC: positiveInt(10),
	COMMAND_POLL_INTERVAL_SEC: positiveInt(3),
	STATS_REPORT_INTERVAL_SEC: positiveInt(30),
	HTTP_TIMEOUT_MS: positiveInt(15000),

	LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
	AGENT_VERSION: z.string().trim().default("0.2.0"),
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
