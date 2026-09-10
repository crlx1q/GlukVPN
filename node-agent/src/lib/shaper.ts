/**
 * Per-peer speed limits with tc/HTB.
 *
 * The control plane attaches a `shaping` block to every ADD_PEER: the plan's
 * line speed in Mbit/s and a priority. This module turns that into kernel
 * state on the WireGuard interface, and nothing else:
 *
 *   download (node -> device)  one HTB class per peer, matched on `ip dst`
 *   upload   (device -> node)  one ingress policer per peer, on `ip src`
 *
 * Why a rate *and* a ceil. `ceil` is the hard per-device cap - the number the
 * customer bought. `rate` is the slice the kernel guarantees that device even
 * when the uplink is full. The per-peer ceilings are deliberately allowed to
 * add up to more than the uplink: one device alone may use the whole link, and
 * when several compete `prio` decides who borrows the spare capacity first -
 * beta_pro, then pro, then basic, then free.
 *
 * Class ids come from the peer's leased address, never from a counter, so the
 * same device always lands in the same class: running ADD_PEER twice replaces
 * that class instead of leaking a second one.
 *
 * Everything here is best effort. A node without `tc`, or with a kernel built
 * without HTB, keeps forwarding traffic - unshaped, and it says so once.
 */
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { config } from "../config"
import { errorMessage, log } from "./logger"

const execFileAsync = promisify(execFile)

const TC_BIN = "/usr/sbin/tc"
const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/
const IFACE_RE = /^[a-zA-Z0-9_.-]{2,15}$/

/** Root class minor. A peer may never claim it. */
const ROOT_MINOR = 1
/** Catch-all leaf: anything the per-peer filters do not match. */
const DEFAULT_MINOR = 0xfffe
/**
 * u32 filter node ids are 12 bits wide, and the filter handle is what makes
 * `tc filter replace` idempotent. That bound is what limits how large the
 * address pool may be: the last two octets of the /32 must fit in 0xfff, so
 * anything up to a /20 works and a wider pool is reported, not silently
 * mis-shaped.
 */
const MAX_CLASS_KEY = 0xfff
/** Free's priority, used when a payload carries no usable number. */
const DEFAULT_PRIORITY = 4

export type PeerShaping = {
	/** Plan line speed in Mbit/s. `null` means "do not shape this peer". */
	speedMbps: number | null
	/** Lower is served first. Clamped to the 0-7 range tc accepts. */
	priority: number
}

export class ShaperError extends Error {}

/**
 * Reads the `shaping` block out of a command payload.
 *
 * A payload from an older control plane has no such block; that reads as "no
 * opinion", which leaves the peer unshaped rather than guessing a cap.
 */
export function parseShaping(payload: Record<string, unknown>): PeerShaping | null {
	const raw = payload.shaping
	if (!raw || typeof raw !== "object") return null
	const { speedMbps, priority } = raw as { speedMbps?: unknown; priority?: unknown }
	const speed =
		typeof speedMbps === "number" && Number.isFinite(speedMbps) && speedMbps > 0
			? Math.floor(speedMbps)
			: null
	const prio =
		typeof priority === "number" && Number.isFinite(priority)
			? Math.min(7, Math.max(0, Math.floor(priority)))
			: DEFAULT_PRIORITY
	return { speedMbps: speed, priority: prio }
}

/**
 * The class minor for a leased address: the last two octets.
 *
 * `null` when the address cannot own a class - malformed, the network or
 * gateway address (0 and 1 are reserved for the root class), or outside the
 * 12-bit filter-handle range.
 */
export function classKey(ip: string): number | null {
	const match = IPV4_RE.exec(ip)
	if (!match) return null
	for (let i = 1; i <= 4; i += 1) {
		const octet = Number(match[i])
		if (!Number.isInteger(octet) || octet < 0 || octet > 255) return null
	}
	const key = (Number(match[3]) << 8) | Number(match[4])
	if (key <= ROOT_MINOR || key > MAX_CLASS_KEY) return null
	return key
}

/**
 * The slice of its own plan speed a device keeps on a congested link. Always
 * at least 1 Mbit/s and never more than the cap itself, so a 30 Mbit/s Free
 * device cannot be handed a floor it is not allowed to reach.
 */
export function guaranteedMbps(capMbps: number, percent: number): number {
	const share = Math.floor((capMbps * percent) / 100)
	return Math.min(capMbps, Math.max(1, share))
}

/** Policer burst in kilobytes: about an eighth of a second at full rate. */
export function burstKb(capMbps: number): number {
	return Math.max(32, capMbps * 16)
}

export function downloadClassArgs(options: {
	iface: string
	hex: string
	capMbps: number
	guaranteeMbps: number
	priority: number
}): string[] {
	return [
		"class",
		"replace",
		"dev",
		options.iface,
		"parent",
		`1:${ROOT_MINOR.toString(16)}`,
		"classid",
		`1:${options.hex}`,
		"htb",
		"rate",
		`${options.guaranteeMbps}mbit`,
		"ceil",
		`${options.capMbps}mbit`,
		"prio",
		String(options.priority),
	]
}

export function downloadFilterArgs(options: {
	iface: string
	hex: string
	ip: string
}): string[] {
	return [
		"filter",
		"replace",
		"dev",
		options.iface,
		"parent",
		"1:",
		"protocol",
		"ip",
		"prio",
		"1",
		"handle",
		`800::${options.hex}`,
		"u32",
		"match",
		"ip",
		"dst",
		`${options.ip}/32`,
		"flowid",
		`1:${options.hex}`,
	]
}

export function uploadPolicerArgs(options: {
	iface: string
	hex: string
	ip: string
	capMbps: number
}): string[] {
	return [
		"filter",
		"replace",
		"dev",
		options.iface,
		"parent",
		"ffff:",
		"protocol",
		"ip",
		"prio",
		"1",
		"handle",
		`800::${options.hex}`,
		"u32",
		"match",
		"ip",
		"src",
		`${options.ip}/32`,
		"police",
		"rate",
		`${options.capMbps}mbit`,
		"burst",
		`${burstKb(options.capMbps)}k`,
		"drop",
		"flowid",
		":1",
	]
}

/** Set once `tc` turns out to be missing, so the warning is logged one time. */
let shapingAvailable = true
let rootReady = false

async function tc(args: string[], tolerate = false): Promise<boolean> {
	if (!shapingAvailable) return false
	try {
		await execFileAsync(TC_BIN, args, {
			timeout: 10_000,
			maxBuffer: 1024 * 1024,
			// No shell: argv reaches execve() as-is.
			shell: false,
		})
		return true
	} catch (error) {
		if ((error as { code?: unknown }).code === "ENOENT") {
			shapingAvailable = false
			log.warn("traffic shaping disabled: tc is not installed", { bin: TC_BIN })
			return false
		}
		if (!tolerate) {
			log.warn("tc command failed", {
				command: args.slice(0, 2).join(" "),
				reason: errorMessage(error),
			})
		}
		return false
	}
}

/**
 * Creates the root qdisc, the root class and the catch-all leaf once.
 *
 * `add` rather than `replace` for the qdiscs, and the failure is tolerated:
 * replacing a root qdisc drops every class under it, which would unshape all
 * live peers each time the agent restarts. The classes are `replace`d, which
 * is idempotent and leaves the peer classes alone.
 */
async function ensureRoot(iface: string): Promise<boolean> {
	if (rootReady) return true
	const uplink = config.SHAPING_UPLINK_MBIT
	const rootMinor = ROOT_MINOR.toString(16)
	const defaultMinor = DEFAULT_MINOR.toString(16)

	await tc(
		["qdisc", "add", "dev", iface, "root", "handle", "1:", "htb", "default", defaultMinor],
		true,
	)
	const ok =
		(await tc([
			"class",
			"replace",
			"dev",
			iface,
			"parent",
			"1:",
			"classid",
			`1:${rootMinor}`,
			"htb",
			"rate",
			`${uplink}mbit`,
			"ceil",
			`${uplink}mbit`,
		])) &&
		(await tc([
			"class",
			"replace",
			"dev",
			iface,
			"parent",
			`1:${rootMinor}`,
			"classid",
			`1:${defaultMinor}`,
			"htb",
			"rate",
			"1mbit",
			"ceil",
			`${uplink}mbit`,
			"prio",
			"7",
		]))

	// Ingress side for the upload policers. Harmless when it already exists.
	if (ok) await tc(["qdisc", "add", "dev", iface, "handle", "ffff:", "ingress"], true)

	rootReady = ok
	return ok
}

/**
 * Shapes one peer to its plan speed, in both directions.
 *
 * A `null` cap is not an error and not a no-op: it means the plan does not cap
 * this device, so any class left over from a previous plan is removed.
 */
export async function applyPeerShaping(options: {
	iface: string
	assignedIp: string
	shaping: PeerShaping | null
}): Promise<void> {
	if (!config.SHAPING_ENABLED) return
	const { iface, assignedIp } = options
	if (!IFACE_RE.test(iface)) throw new ShaperError(`Invalid interface name: ${iface}`)

	const cap = options.shaping?.speedMbps ?? null
	if (cap === null) {
		await clearPeerShaping({ iface, assignedIp })
		return
	}

	const key = classKey(assignedIp)
	if (key === null) {
		log.warn("peer address cannot be shaped, left at full speed", { ip: assignedIp })
		return
	}
	if (!(await ensureRoot(iface))) return

	const hex = key.toString(16)
	const guaranteeMbps = guaranteedMbps(cap, config.SHAPING_GUARANTEE_PERCENT)
	const priority = options.shaping?.priority ?? DEFAULT_PRIORITY

	const shaped =
		(await tc(downloadClassArgs({ iface, hex, capMbps: cap, guaranteeMbps, priority }))) &&
		(await tc(downloadFilterArgs({ iface, hex, ip: assignedIp })))
	// Upload is policed, not queued: there is no local queue to reorder on this
	// side of the link, only packets to drop once the device sends too fast.
	const policed = await tc(uploadPolicerArgs({ iface, hex, ip: assignedIp, capMbps: cap }))

	if (shaped) {
		log.info("peer shaped", {
			ip: assignedIp,
			capMbit: cap,
			floorMbit: guaranteeMbps,
			priority,
			upload: policed ? "policed" : "unpoliced",
		})
	}
}

/**
 * Drops the class and filters belonging to one leased address.
 *
 * Every step is tolerated: a peer that was never shaped has nothing to delete.
 * A class that somehow outlives its filter is not a leak either - the next
 * lease of the same address replaces it, because the id is derived from the
 * address rather than allocated.
 */
export async function clearPeerShaping(options: {
	iface: string
	assignedIp: string
}): Promise<void> {
	if (!config.SHAPING_ENABLED) return
	const { iface, assignedIp } = options
	if (!IFACE_RE.test(iface)) return
	const key = classKey(assignedIp)
	if (key === null) return
	const hex = key.toString(16)

	await tc(
		[
			"filter",
			"delete",
			"dev",
			iface,
			"parent",
			"1:",
			"protocol",
			"ip",
			"prio",
			"1",
			"handle",
			`800::${hex}`,
			"u32",
		],
		true,
	)
	await tc(
		[
			"filter",
			"delete",
			"dev",
			iface,
			"parent",
			"ffff:",
			"protocol",
			"ip",
			"prio",
			"1",
			"handle",
			`800::${hex}`,
			"u32",
		],
		true,
	)
	await tc(["class", "delete", "dev", iface, "classid", `1:${hex}`], true)
}
