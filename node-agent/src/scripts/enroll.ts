/**
 * One-time node enrollment.
 *
 * Usage (on the node):
 *   sudo -u vpnagent ENV_FILE=/etc/vpn-node-agent/agent.env node dist/scripts/enroll.js
 *   npm run enroll:dev            # local development
 *
 * Flags:
 *   --force   re-enroll even if NODE_TOKEN is already present
 *
 * The one-time enrollment token is read from the env file, exchanged for a
 * node-specific token, and then cleared from the file. The token itself is never
 * printed to stdout.
 */
import { config, ENV_FILE, persistCredentials } from "../config"
import { ApiError, registerNode } from "../lib/api"
import { errorMessage, shortKey } from "../lib/logger"
import { interfaceExists, interfacePublicKey } from "../lib/wg"

const force = process.argv.slice(2).includes("--force")

function fail(message: string, hint?: string): never {
	console.error(`\nenrollment failed: ${message}`)
	if (hint) console.error(`hint: ${hint}`)
	process.exit(1)
}

/** Best-effort public IPv4 detection when NODE_PUBLIC_IP is not set. */
async function detectPublicIp(): Promise<string | null> {
	try {
		const response = await fetch("https://api.ipify.org?format=json", {
			signal: AbortSignal.timeout(8000),
		})
		if (!response.ok) return null
		const body = (await response.json()) as { ip?: string }
		const ip = body.ip?.trim() ?? ""
		return /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) ? ip : null
	} catch {
		return null
	}
}

async function main(): Promise<void> {
	console.log("GlukVPN node enrollment")
	console.log(`env file:    ${ENV_FILE}`)
	console.log(`control api: ${config.CONTROL_API_URL}`)
	console.log(`node name:   ${config.NODE_NAME} (${config.NODE_COUNTRY_CODE})`)
	console.log(
		`location:    ${config.NODE_COUNTRY}` +
			`${config.NODE_CITY ? ` / ${config.NODE_CITY}` : ""}` +
			`${config.NODE_REGION ? ` (${config.NODE_REGION})` : ""}`,
	)

	if (config.NODE_TOKEN && !force) {
		fail(
			"this node already has a NODE_TOKEN",
			"pass --force to replace it, or run `npm run cli -- nodes:revoke-tokens <name>` on the control server first",
		)
	}

	if (!config.NODE_ENROLLMENT_TOKEN) {
		fail(
			"NODE_ENROLLMENT_TOKEN is empty",
			"create one on the control server with `npm run cli -- nodes:token` and paste it into the env file",
		)
	}

	// The WireGuard interface must already exist: the node key pair is created by
	// the operator (wg genkey), never by this agent, and never leaves the node.
	const ifaceUp = await interfaceExists(config.WG_INTERFACE)
	if (!ifaceUp) {
		fail(
			`WireGuard interface ${config.WG_INTERFACE} does not exist`,
			`bring it up first: sudo systemctl enable --now wg-quick@${config.WG_INTERFACE}`,
		)
	}

	let wireguardPublicKey: string
	try {
		wireguardPublicKey = await interfacePublicKey(config.WG_INTERFACE)
	} catch (error) {
		return fail(errorMessage(error), "is the agent user allowed to run `wg` (CAP_NET_ADMIN)?")
	}
	console.log(`node wg key: ${shortKey(wireguardPublicKey)} (public key only)`)

	const publicIp = config.NODE_PUBLIC_IP ?? (await detectPublicIp())
	if (!publicIp) {
		fail(
			"could not determine the public IPv4 of this node",
			"set NODE_PUBLIC_IP in the env file",
		)
	}
	const hostname = config.NODE_HOSTNAME ?? publicIp
	console.log(`endpoint:    ${hostname}:${config.WG_LISTEN_PORT} (udp)`)

	try {
		const result = await registerNode({
			enrollmentToken: config.NODE_ENROLLMENT_TOKEN,
			name: config.NODE_NAME,
			country: config.NODE_COUNTRY,
			countryCode: config.NODE_COUNTRY_CODE,
			// Reported so the app can show "Germany / Frankfurt" instead of "de-01".
			region: config.NODE_REGION ?? undefined,
			city: config.NODE_CITY ?? undefined,
			pingTarget: config.NODE_PING_TARGET ?? undefined,
			hostname,
			publicIp,
			wireguardPublicKey,
			wireguardPort: config.WG_LISTEN_PORT,
			subnetCidr: config.WG_SUBNET,
			mtu: config.WG_MTU,
			agentVersion: config.AGENT_VERSION,
		})

		// Store credentials with 0600 and wipe the one-time enrollment token.
		persistCredentials({
			NODE_ID: result.nodeId,
			NODE_TOKEN: result.nodeToken,
			NODE_ENROLLMENT_TOKEN: "",
			NODE_PUBLIC_IP: publicIp,
			NODE_HOSTNAME: hostname,
		})

		console.log("\nenrolled successfully")
		console.log(`node id:            ${result.nodeId}`)
		console.log(`token expires:      ${result.nodeTokenExpiresAt}`)
		console.log(`heartbeat interval: ${result.heartbeatIntervalSec}s`)
		console.log(`offline after:      ${result.offlineAfterSec}s`)
		console.log(
			`control-plane wg:   ${result.wireguard.interfaceAddress} / ${result.wireguard.subnetCidr}` +
				` port ${result.wireguard.listenPort} mtu ${result.wireguard.mtu} dns ${result.wireguard.dns}`,
		)
		console.log("the node token was written to the env file and is NOT printed here")
		console.log("\nnext: sudo systemctl enable --now vpn-node-agent")
	} catch (error) {
		if (error instanceof ApiError) {
			if (error.status === 401 || error.status === 403) {
				fail(
					`control plane rejected the enrollment token (${error.code})`,
					"the token is single-use and expires: issue a new one with `npm run cli -- nodes:token`",
				)
			}
			fail(`${error.message} (HTTP ${error.status})`)
		}
		fail(errorMessage(error))
	}
}

void main()
