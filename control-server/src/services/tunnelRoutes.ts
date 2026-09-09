/**
 * Which routes the client pushes into the tunnel.
 *
 * A phone used to get a flat `0.0.0.0/0`, so every packet - including the
 * app's own calls to the control API - went through WireGuard. That is fine
 * while the tunnel works, but the second a node drops the peer (admin
 * disconnect, device revoke, subscription end) the app lost the only channel
 * that could tell it *why* it went dark. It could only wait for timeouts, so
 * the UI kept saying "connected" long after the traffic had stopped. The
 * desktop client never had that problem because it talks to the API through
 * its TLS gateway, outside the tunnel.
 *
 * The fix is a surgical hole: everything still goes through the VPN except
 * the handful of control-plane addresses listed in `TUNNEL_BYPASS_IPS`. We
 * express that as `0.0.0.0/0` minus those addresses, because WireGuard has no
 * "exclude" syntax - only AllowedIPs.
 */

const LAST_IPV4 = 0xffffffff
const FULL_SPACE = LAST_IPV4 + 1

/** Half-open safety net: a typo must never explode into hundreds of routes. */
const MAX_ROUTES = 96

type Range = { start: number; end: number }

function formatIp(value: number): string {
	const a = Math.floor(value / 16777216) % 256
	const b = Math.floor(value / 65536) % 256
	const c = Math.floor(value / 256) % 256
	const d = value % 256
	return `${a}.${b}.${c}.${d}`
}

/**
 * Parses `1.2.3.4` or `1.2.3.0/24` into an inclusive address range. The
 * address is snapped down to its network address, so `1.2.3.7/24` and
 * `1.2.3.0/24` mean the same thing. Returns null for anything unparseable -
 * a bad env value must not take the whole connect flow down.
 */
export function parseCidr(raw: string): Range | null {
	const text = raw.trim()
	if (!text) return null
	const slash = text.indexOf("/")
	const address = slash === -1 ? text : text.slice(0, slash)
	const bitsText = slash === -1 ? "32" : text.slice(slash + 1)
	if (!/^\d{1,2}$/.test(bitsText)) return null
	const bits = Number(bitsText)
	if (bits > 32) return null
	const octets = address.split(".")
	if (octets.length !== 4) return null
	let value = 0
	for (const octet of octets) {
		if (!/^\d{1,3}$/.test(octet)) return null
		const part = Number(octet)
		if (part > 255) return null
		value = value * 256 + part
	}
	const size = bits === 0 ? FULL_SPACE : 2 ** (32 - bits)
	const start = Math.floor(value / size) * size
	return { start, end: start + size - 1 }
}

/** Largest power-of-two block that may start at `value`. */
function alignmentAt(value: number): number {
	if (value === 0) return FULL_SPACE
	let size = 1
	while (value % (size * 2) === 0) size *= 2
	return size
}

/** Minimal set of CIDR blocks covering an inclusive range. */
function rangeToCidrs(start: number, end: number): string[] {
	const out: string[] = []
	let cursor = start
	while (cursor <= end) {
		let size = alignmentAt(cursor)
		while (cursor + size - 1 > end) size /= 2
		out.push(`${formatIp(cursor)}/${32 - Math.log2(size)}`)
		cursor += size
	}
	return out
}

/** Splits `"a, b"` into trimmed, non-empty entries. */
export function parseBypassList(raw: string): string[] {
	return raw
		.split(",")
		.map((entry) => entry.trim())
		.filter(Boolean)
}

/**
 * `0.0.0.0/0` minus every excluded address. With no exclusions the result is
 * literally `["0.0.0.0/0"]`, so an unconfigured server behaves exactly as
 * before.
 */
export function splitTunnelRoutes(exclusions: ReadonlyArray<string>): string[] {
	const ranges: Range[] = []
	for (const entry of exclusions) {
		const range = parseCidr(entry)
		// A /0 exclusion would leave the client with no routes at all.
		if (range && !(range.start === 0 && range.end === LAST_IPV4)) ranges.push(range)
	}
	if (ranges.length === 0) return ["0.0.0.0/0"]
	ranges.sort((a, b) => a.start - b.start)

	const merged: Range[] = []
	for (const range of ranges) {
		const last = merged[merged.length - 1]
		if (last && range.start <= last.end + 1) {
			last.end = Math.max(last.end, range.end)
			continue
		}
		merged.push({ ...range })
	}

	const routes: string[] = []
	let cursor = 0
	for (const hole of merged) {
		if (hole.start > cursor) routes.push(...rangeToCidrs(cursor, hole.start - 1))
		cursor = hole.end + 1
	}
	if (cursor <= LAST_IPV4) routes.push(...rangeToCidrs(cursor, LAST_IPV4))

	// Too many routes means the list was misconfigured; a working tunnel with a
	// slow disconnect beats a tunnel the client refuses to raise.
	if (routes.length === 0 || routes.length > MAX_ROUTES) return ["0.0.0.0/0"]
	return routes
}

/**
 * Routes handed to clients in the connect response. The raw value comes from
 * `config.TUNNEL_BYPASS_IPS`; it is passed in so this module stays pure and
 * testable without a full server environment.
 */
export function tunnelAllowedIps(raw: string): string[] {
	return splitTunnelRoutes(parseBypassList(raw))
}
