/**
 * Thin, safe wrapper around the `wg` CLI.
 *
 * Rules enforced here:
 *  - every argument is validated before it reaches the process (no shell is used
 *    at all: execFile passes argv directly, so no command injection is possible);
 *  - only two mutating operations exist: add peer and remove peer;
 *  - the interface private key returned by `wg show ... dump` is dropped
 *    immediately and is never logged, stored or transmitted.
 */
import { execFile } from "node:child_process"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

const WG_BIN = "/usr/bin/wg"
const IP_BIN = "/usr/sbin/ip"
const WG_KEY_RE = /^[A-Za-z0-9+/]{42}=$/
const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/
const IFACE_RE = /^[a-zA-Z0-9_.-]{2,15}$/

export type WgPeer = {
	publicKey: string
	endpoint: string | null
	allowedIps: string[]
	lastHandshakeAt: string | null
	bytesRx: number
	bytesTx: number
	persistentKeepalive: number | null
}

export type WgInterfaceState = {
	interfacePublicKey: string | null
	listenPort: number | null
	peers: WgPeer[]
}

export class WgError extends Error {}

function assertInterface(iface: string): void {
	if (!IFACE_RE.test(iface)) throw new WgError(`Invalid interface name: ${iface}`)
}

export function isValidWgKey(key: string): boolean {
	return WG_KEY_RE.test(key)
}

function assertKey(key: string): void {
	if (!isValidWgKey(key)) throw new WgError("Invalid WireGuard public key")
}

function assertIpv4(ip: string): void {
	const match = IPV4_RE.exec(ip)
	if (!match) throw new WgError(`Invalid IPv4 address: ${ip}`)
	for (let i = 1; i <= 4; i += 1) {
		const octet = Number(match[i])
		if (!Number.isInteger(octet) || octet < 0 || octet > 255) {
			throw new WgError(`Invalid IPv4 address: ${ip}`)
		}
	}
}

async function run(bin: string, args: string[]): Promise<string> {
	try {
		const { stdout } = await execFileAsync(bin, args, {
			timeout: 10_000,
			maxBuffer: 4 * 1024 * 1024,
			// No shell: argv is passed to execve() as-is.
			shell: false,
		})
		return stdout.toString()
	} catch (error) {
		const stderr =
			typeof error === "object" && error && "stderr" in error
				? String((error as { stderr?: unknown }).stderr ?? "").trim()
				: ""
		const message =
			stderr || (error instanceof Error ? error.message : "command failed")
		throw new WgError(`${bin} ${args[0] ?? ""} failed: ${message}`)
	}
}

/** True when the kernel interface exists (wg0 is up). */
export async function interfaceExists(iface: string): Promise<boolean> {
	assertInterface(iface)
	try {
		await run(IP_BIN, ["link", "show", iface])
		return true
	} catch {
		return false
	}
}

/** The node's own WireGuard public key (safe to publish to clients). */
export async function interfacePublicKey(iface: string): Promise<string> {
	assertInterface(iface)
	const output = await run(WG_BIN, ["show", iface, "public-key"])
	const key = output.trim()
	if (!isValidWgKey(key)) {
		throw new WgError(`Interface ${iface} did not return a valid public key`)
	}
	return key
}

/**
 * Reads interface + peer state. The first dump line also contains the interface
 * PRIVATE key; it is intentionally ignored and never leaves this function.
 */
export async function dumpInterface(iface: string): Promise<WgInterfaceState> {
	assertInterface(iface)
	const output = await run(WG_BIN, ["show", iface, "dump"])
	const lines = output.split("\n").filter((line) => line.trim() !== "")

	const state: WgInterfaceState = {
		interfacePublicKey: null,
		listenPort: null,
		peers: [],
	}
	if (lines.length === 0) return state

	// Interface line: <private-key> <public-key> <listen-port> <fwmark>
	const firstLine = lines[0]
	if (!firstLine) return state
	const header = firstLine.split("\t")
	state.interfacePublicKey = header[1] && isValidWgKey(header[1]) ? header[1] : null
	state.listenPort = header[2] ? Number(header[2]) : null

	// Peer lines:
	// <public-key> <preshared-key> <endpoint> <allowed-ips> <latest-handshake>
	// <transfer-rx> <transfer-tx> <persistent-keepalive>
	for (const line of lines.slice(1)) {
		const parts = line.split("\t")
		const publicKey = parts[0]?.trim() ?? ""
		if (!isValidWgKey(publicKey)) continue

		const handshakeUnix = Number(parts[4] ?? 0)
		const keepalive = parts[7] === "off" ? null : Number(parts[7] ?? 0) || null

		state.peers.push({
			publicKey,
			endpoint: parts[2] && parts[2] !== "(none)" ? parts[2] : null,
			allowedIps:
				parts[3] && parts[3] !== "(none)"
					? parts[3].split(",").map((entry) => entry.trim())
					: [],
			lastHandshakeAt:
				handshakeUnix > 0 ? new Date(handshakeUnix * 1000).toISOString() : null,
			bytesRx: Number(parts[5] ?? 0) || 0,
			bytesTx: Number(parts[6] ?? 0) || 0,
			persistentKeepalive: keepalive,
		})
	}

	return state
}

/**
 * Adds (or updates) a single peer. allowed-ips is pinned to exactly one /32,
 * so a device can only ever use the address the control plane leased to it.
 */
export async function addPeer(options: {
	iface: string
	publicKey: string
	assignedIp: string
}): Promise<void> {
	assertInterface(options.iface)
	assertKey(options.publicKey)
	assertIpv4(options.assignedIp)

	await run(WG_BIN, [
		"set",
		options.iface,
		"peer",
		options.publicKey,
		"allowed-ips",
		`${options.assignedIp}/32`,
	])
}

/** Removes a peer. Its tunnel stops forwarding immediately. */
export async function removePeer(options: {
	iface: string
	publicKey: string
}): Promise<void> {
	assertInterface(options.iface)
	assertKey(options.publicKey)
	await run(WG_BIN, ["set", options.iface, "peer", options.publicKey, "remove"])
}

/** Convenience: current peer count without exposing keys. */
export async function peerCount(iface: string): Promise<number> {
	const state = await dumpInterface(iface)
	return state.peers.length
}
