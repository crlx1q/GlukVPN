/**
 * The agent's view of the sing-box gateway config.
 *
 * Ownership is split on purpose. The operator (install-singbox.sh, or by hand)
 * owns the parts that need root or a certificate: `log`, the VLESS inbound's
 * `listen`, `listen_port` and `tls`. The agent owns exactly three things and
 * rewrites them from the control plane's policy on every sync:
 *
 *   1. `inbounds[vless].users`        - one entry per active device (+ legacy);
 *   2. `outbounds`                    - `direct` plus one `direct` per user,
 *                                       tagged `u_<user>`. sing-box's Clash API
 *                                       does not expose the authenticated user
 *                                       on a connection, but it does expose the
 *                                       outbound chain, so a private outbound
 *                                       per user is how connections are
 *                                       attributed to devices;
 *   3. `route`                        - sniff, the reject rules (built-in +
 *                                       admin), then `auth_user -> u_<user>`;
 *
 * plus `experimental.clash_api` bound to loopback so this process can read
 * connection counters. Everything else in the file is preserved byte-for-byte
 * in meaning (re-serialised, not re-typed).
 *
 * Nothing in the policy can produce a shell command, a file path or a
 * redirect: rules only ever become `"action": "reject"`, and outbounds only
 * ever become `"type": "direct"`.
 *
 * The write is atomic (temp file + rename in the same directory). sing-box is
 * reloaded by systemd: a `.path` unit watches the file and runs
 * `systemctl reload glukvpn-singbox`, which sends SIGHUP; sing-box validates
 * the new file first and keeps the old instance if it is broken.
 */
import { execFile } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { promisify } from "node:util"
import type { NodePolicy, PolicyRule } from "./api"

const execFileAsync = promisify(execFile)

export type JsonObject = Record<string, unknown>

export type SingboxVersion = { major: number; minor: number; raw: string }

/** sing-box 1.11 moved sniff/block from inbound flags and outbounds to rule actions. */
export function supportsRuleActions(version: SingboxVersion | null): boolean {
	if (!version) return true
	return version.major > 1 || (version.major === 1 && version.minor >= 11)
}

export function parseSingboxVersion(output: string): SingboxVersion | null {
	const match = /version\s+v?(\d+)\.(\d+)/i.exec(output) ?? /^v?(\d+)\.(\d+)/m.exec(output.trim())
	if (!match) return null
	return { major: Number(match[1]), minor: Number(match[2]), raw: output.trim().split("\n")[0] ?? "" }
}

export async function detectSingboxVersion(bin: string): Promise<SingboxVersion | null> {
	try {
		const { stdout } = await execFileAsync(bin, ["version"], { timeout: 5000, shell: false })
		return parseSingboxVersion(stdout.toString())
	} catch {
		return null
	}
}

export function readConfig(file: string): JsonObject {
	const raw = fs.readFileSync(file, "utf8")
	const parsed = JSON.parse(raw) as unknown
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error(`${file} is not a JSON object`)
	}
	return parsed as JsonObject
}

/** Same directory, then rename: readers never see a half-written file. */
export function writeConfigAtomic(file: string, config: JsonObject): void {
	const dir = path.dirname(file)
	const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.tmp`)
	const text = `${JSON.stringify(config, null, 2)}\n`
	fs.writeFileSync(tmp, text, { mode: 0o640 })
	try {
		// Keep the existing mode/owner semantics: the operator decided them.
		const stat = fs.statSync(file, { throwIfNoEntry: false })
		if (stat) fs.chmodSync(tmp, stat.mode & 0o777)
	} catch {
		/* best effort */
	}
	fs.renameSync(tmp, file)
}

function asArray(value: unknown): JsonObject[] {
	return Array.isArray(value) ? (value.filter((item) => item && typeof item === "object") as JsonObject[]) : []
}

export function findVlessInbound(config: JsonObject): JsonObject | null {
	const inbounds = asArray(config.inbounds)
	return inbounds.find((inbound) => inbound.type === "vless") ?? null
}

/** What the control plane should advertise to clients for this node. */
export function gatewayFromConfig(
	config: JsonObject,
	overrides: { publicHost: string | null; publicPort: number },
): { host: string; port: number; sni?: string; flow?: string } | null {
	const inbound = findVlessInbound(config)
	if (!inbound) return null
	const tls = (inbound.tls ?? {}) as JsonObject
	const serverName = typeof tls.server_name === "string" ? tls.server_name : ""
	const host = overrides.publicHost ?? serverName
	if (!host) return null
	const users = asArray(inbound.users)
	const flow = typeof users[0]?.flow === "string" ? (users[0]?.flow as string) : "xtls-rprx-vision"
	return {
		host,
		port: overrides.publicPort,
		...(serverName && serverName !== host ? { sni: serverName } : {}),
		flow,
	}
}

/** Outbound tag for a user; the tracker reverses this. */
export function outboundTagFor(userName: string): string {
	return `u_${userName}`
}

export function userFromOutboundTag(tag: string): string | null {
	return tag.startsWith("u_") ? tag.slice(2) : null
}

/** One policy rule -> the sing-box rule fields it matches on. */
export function ruleMatcher(rule: PolicyRule): JsonObject | null {
	const network = rule.network === "tcp" || rule.network === "udp" ? { network: [rule.network] } : {}
	switch (rule.kind) {
		case "PROTOCOL":
			return { protocol: [rule.value], ...network }
		case "DOMAIN":
			return { domain: [rule.value], ...network }
		case "DOMAIN_SUFFIX":
			return { domain_suffix: [rule.value], ...network }
		case "DOMAIN_KEYWORD":
			return { domain_keyword: [rule.value], ...network }
		case "DOMAIN_REGEX":
			return { domain_regex: [rule.value], ...network }
		case "IP_CIDR":
			return { ip_cidr: [rule.value], ...network }
		case "PORT": {
			const port = Number(rule.value)
			return Number.isInteger(port) ? { port: [port], ...network } : null
		}
		case "PORT_RANGE":
			return { port_range: [rule.value], ...network }
		default:
			return null
	}
}

export type RenderOptions = {
	clashApi: string
	clashSecret: string
	version: SingboxVersion | null
}

/**
 * Merges the policy into the existing config. Pure: takes the object read from
 * disk, returns a new object; the caller decides whether to write it.
 */
export function renderConfig(base: JsonObject, policy: NodePolicy, options: RenderOptions): JsonObject {
	const config: JsonObject = { ...base }
	const inbounds = asArray(base.inbounds).map((inbound) => ({ ...inbound }))
	const inbound = inbounds.find((entry) => entry.type === "vless")
	if (!inbound) throw new Error("no vless inbound in the sing-box config")
	const inboundTag = typeof inbound.tag === "string" ? inbound.tag : "vless-in"
	inbound.tag = inboundTag
	const actions = supportsRuleActions(options.version)

	// 1. users
	const users = [...policy.users, ...(policy.legacyUser ? [policy.legacyUser] : [])]
	inbound.users = users.map((user) => ({ name: user.name, uuid: user.uuid, flow: user.flow || policy.flow }))
	if (actions) {
		// Legacy inbound flags are removed in 1.13; sniffing is a rule action now.
		delete inbound.sniff
		delete inbound.sniff_override_destination
		delete inbound.sniff_timeout
		delete inbound.domain_strategy
	} else {
		inbound.sniff = true
	}
	config.inbounds = inbounds

	// 2. outbounds: keep whatever the operator had that is not ours, then ours.
	const preserved = asArray(base.outbounds).filter((outbound) => {
		const tag = typeof outbound.tag === "string" ? outbound.tag : ""
		if (tag.startsWith("u_")) return false
		if (tag === "direct" || tag === "block") return false
		return true
	})
	const outbounds: JsonObject[] = [{ type: "direct", tag: "direct" }]
	for (const user of users) outbounds.push({ type: "direct", tag: outboundTagFor(user.name) })
	if (!actions) outbounds.push({ type: "block", tag: "block" })
	config.outbounds = [...outbounds, ...preserved]

	// 3. route
	const rules: JsonObject[] = []
	if (actions) rules.push({ inbound: [inboundTag], action: "sniff" })
	const reject = (matcher: JsonObject): JsonObject =>
		actions ? { ...matcher, action: "reject" } : { ...matcher, outbound: "block" }
	for (const rule of [...policy.builtinRules, ...policy.rules]) {
		const matcher = ruleMatcher(rule)
		if (matcher) rules.push(reject(matcher))
	}
	for (const user of users) {
		rules.push({ auth_user: [user.name], outbound: outboundTagFor(user.name) })
	}
	const baseRoute = (base.route ?? {}) as JsonObject
	config.route = {
		...baseRoute,
		rules,
		final: "direct",
	}

	// 4. Clash API on loopback, for this agent only.
	const experimental = { ...((base.experimental ?? {}) as JsonObject) }
	const existingClash = (experimental.clash_api ?? {}) as JsonObject
	experimental.clash_api = {
		...existingClash,
		external_controller: options.clashApi,
		secret: options.clashSecret,
	}
	config.experimental = experimental

	return config
}

/**
 * `sing-box check` as the agent user. A failure caused by files the agent may
 * not read (the TLS key) is not a config error, so those are ignored; anything
 * else is fatal for the write.
 */
export async function checkConfig(bin: string, file: string): Promise<{ ok: boolean; reason?: string }> {
	try {
		await execFileAsync(bin, ["check", "-c", file], { timeout: 10000, shell: false })
		return { ok: true }
	} catch (error) {
		const stderr =
			typeof error === "object" && error && "stderr" in error
				? String((error as { stderr?: unknown }).stderr ?? "")
				: ""
		const text = stderr || (error instanceof Error ? error.message : "")
		if (/permission denied|no such file|certificate|key_path|open \//i.test(text)) {
			return { ok: true, reason: `check skipped: ${text.trim().slice(0, 200)}` }
		}
		return { ok: false, reason: text.trim().slice(0, 400) || "sing-box check failed" }
	}
}
