/**
 * Shaped VLESS front door (ROUND 27).
 *
 * The phone is capped by tc/HTB on the WireGuard interface and the browser
 * extension by a token bucket inside the proxy. The desktop client was neither:
 * it speaks VLESS straight to sing-box, and nothing on that path had ever
 * looked at the plan speed. A 30 Mbit/s account measured ~300 Mbit/s.
 *
 * tc cannot fix this the way it fixes WireGuard. A VLESS session is a single
 * TLS stream on the node's public interface, so a filter would have to match
 * the subscriber's public address on the interface that carries the whole
 * machine - control API, site, every other tunnel - and one wrong class there
 * degrades the node for everybody.
 *
 * So the cap moves one layer up: a plain TCP relay in front of sing-box, one
 * listener per plan speed. The control plane hands a capped account the port
 * that matches its plan instead of the plain gateway port; an uncapped account
 * keeps going straight to sing-box and never touches this code, so unlimited
 * users pay nothing for the feature. Shaping the outer stream shapes
 * everything multiplexed inside it - TCP, xudp, QUIC over VLESS - because
 * there is nowhere else for those bytes to travel.
 *
 * The gate is the one already running in production in the browser proxy: a
 * token bucket per subscriber address, paid per chunk, with the source left
 * unread while the budget is empty. The TCP window - not this process's
 * memory - absorbs the excess.
 */
import net from "node:net"
import { Transform } from "node:stream"

import { config } from "../config"
import { errorMessage, log } from "./logger"

/** One listener: everything arriving on `port` is capped at `mbps`. */
export type GatewayTier = { mbps: number; port: number }

/**
 * A cap slower than this would not throttle a download, it would hang it.
 * Same floor the browser proxy uses.
 */
export const MIN_BYTES_PER_SECOND = 32 * 1024

/** Mbit/s as the byte budget a bucket refills per second. */
export function bytesPerSecond(mbps: number): number {
	return Math.max(MIN_BYTES_PER_SECOND, Math.floor((mbps * 1_000_000) / 8))
}

/**
 * Parses SHAPING_GATEWAY_TIERS, the ROUND 27 format: "<mbit>=<port>" pairs
 * such as "30=2053,100=2083".
 *
 * Kept for nodes that were configured before the SNI front door existed, and
 * for pinning a port by hand. New deployments use SHAPING_GATEWAY_SPEEDS and
 * `parseSpeedTiers` below, because one external port per tier is exactly what
 * broke in Oracle Cloud.
 *
 * A malformed entry is dropped, never guessed at: inventing a cap for a typo
 * would throttle a plan nobody sold. The result is sorted by speed so the log
 * line at startup reads in plan order.
 */
export function parseTiers(spec: string): GatewayTier[] {
	const usedPorts = new Set<number>()
	const usedSpeeds = new Set<number>()
	const tiers: GatewayTier[] = []

	for (const raw of spec.split(",")) {
		const entry = raw.trim()
		if (entry === "") continue
		const match = /^(\d{1,6})\s*=\s*(\d{1,5})$/.exec(entry)
		if (!match) continue
		const mbps = Number(match[1])
		const port = Number(match[2])
		if (mbps <= 0 || port < 1 || port > 65535) continue
		// Two listeners on one port cannot both bind, and two ports for one
		// speed make the control plane's choice ambiguous. First wins.
		if (usedPorts.has(port) || usedSpeeds.has(mbps)) continue
		usedPorts.add(port)
		usedSpeeds.add(mbps)
		tiers.push({ mbps, port })
	}

	return tiers.sort((a, b) => a.mbps - b.mbps)
}

/** First loopback port handed to a shaped relay when none is pinned. */
export const DEFAULT_SPEED_BASE_PORT = 8460

/**
 * Parses SHAPING_GATEWAY_SPEEDS, e.g. "30,50,100,250,500": the speeds sold in
 * the admin panel, with no port in sight.
 *
 * That absence is the point. The pairs format needed one *externally
 * reachable* port per tier, and this node lives in Oracle Cloud, where the VCN
 * closes everything except 443 - a capped desktop client got connect_timeout
 * instead of a slow tunnel. Non-standard ports are also the first thing an ISP
 * or a hotel Wi-Fi drops. Now nginx `stream` splits the single open port by
 * SNI (`speed30.<node>` here, `<node>` straight to sing-box) and these relays
 * bind loopback, where no firewall and no client can reach them.
 *
 * Ports are therefore an internal detail, assigned as `basePort + index` over
 * the sorted, de-duplicated speeds. The rule is deterministic so the generated
 * nginx map and these listeners agree without either side storing it; a tier
 * may still pin its own port as "<mbps>=<port>" on a node where the default
 * range is taken.
 */
export function parseSpeedTiers(spec: string, basePort = DEFAULT_SPEED_BASE_PORT): GatewayTier[] {
	const pinned = new Map<number, number>()
	const speeds: number[] = []

	for (const raw of spec.split(",")) {
		const entry = raw.trim()
		if (entry === "") continue
		const match = /^(\d{1,6})(?:\s*=\s*(\d{1,5}))?$/.exec(entry)
		if (!match) continue
		const mbps = Number(match[1])
		if (mbps <= 0) continue
		// Two ports for one speed leave the control plane no way to choose, so
		// the first spelling of a speed wins - as in parseTiers above.
		if (speeds.includes(mbps)) continue
		if (match[2] !== undefined) {
			const port = Number(match[2])
			if (port < 1 || port > 65535) continue
			pinned.set(mbps, port)
		}
		speeds.push(mbps)
	}

	speeds.sort((a, b) => a - b)
	const used = new Set<number>(pinned.values())
	const tiers: GatewayTier[] = []
	let next = basePort
	for (const mbps of speeds) {
		const port = pinned.get(mbps)
		if (port !== undefined) {
			tiers.push({ mbps, port })
			continue
		}
		while (used.has(next)) next += 1
		if (next > 65535) break
		used.add(next)
		tiers.push({ mbps, port: next })
		next += 1
	}
	return tiers
}

const defaultSleep = (ms: number): Promise<void> =>
	new Promise((resolve) => setTimeout(resolve, ms))

export type TokenBucketOptions = {
	bytesPerSecond: number
	burstSeconds?: number
	/** Injected in tests so the budget is arithmetic, not wall-clock luck. */
	now?: () => number
	sleep?: (ms: number) => Promise<void>
}

/**
 * Classic token bucket. `take` resolves only once the bytes are paid for, so
 * the caller - a stream gate - stops reading its source while it waits.
 */
export class TokenBucket {
	private rate: number
	private capacity: number
	private tokens: number
	private updatedAt: number
	private readonly burstSeconds: number
	private readonly now: () => number
	private readonly sleep: (ms: number) => Promise<void>

	constructor(options: TokenBucketOptions) {
		this.burstSeconds = Math.min(2, Math.max(0.05, options.burstSeconds ?? 0.25))
		this.now = options.now ?? Date.now
		this.sleep = options.sleep ?? defaultSleep
		this.rate = Math.max(1, Math.floor(options.bytesPerSecond))
		this.capacity = this.burstCapacity()
		this.tokens = this.capacity
		this.updatedAt = this.now()
	}

	private burstCapacity(): number {
		return Math.max(MIN_BYTES_PER_SECOND, Math.floor(this.rate * this.burstSeconds))
	}

	/** Current budget, exposed for tests and the debug log. */
	get ratePerSecond(): number {
		return this.rate
	}

	setRate(next: number): void {
		const rate = Math.max(1, Math.floor(next))
		if (rate === this.rate) return
		this.rate = rate
		this.capacity = this.burstCapacity()
		if (this.tokens > this.capacity) this.tokens = this.capacity
	}

	private refill(): void {
		const now = this.now()
		const elapsed = (now - this.updatedAt) / 1000
		if (elapsed <= 0) return
		this.updatedAt = now
		this.tokens = Math.min(this.capacity, this.tokens + elapsed * this.rate)
	}

	/** Holds the caller until `bytes` have been paid for. */
	async take(bytes: number): Promise<void> {
		let left = bytes
		while (left > 0) {
			this.refill()
			if (this.tokens > 0) {
				const spend = Math.min(this.tokens, left)
				this.tokens -= spend
				left -= spend
				if (left <= 0) return
			}
			// Exactly as long as the remainder needs, but never more than a
			// second: a rate change has to take effect while the socket lives.
			await this.sleep(Math.min(1_000, Math.max(5, Math.ceil((left / this.rate) * 1_000))))
		}
	}
}

/**
 * `source.pipe(destination)` with every chunk paid for first. While the budget
 * is empty the gate stops accepting chunks, the source is not read, and the
 * TCP window closes on the far end - which is what makes this a rate limit
 * rather than a memory leak.
 */
function pipeThrottled(
	source: NodeJS.ReadableStream,
	destination: NodeJS.WritableStream,
	bucket: TokenBucket,
): void {
	const gate = new Transform({
		highWaterMark: 64 * 1024,
		transform(chunk: Buffer, _encoding, callback) {
			bucket.take(chunk.length).then(
				() => callback(null, chunk),
				(error: unknown) => callback(error as Error),
			)
		},
	})
	// A chunk can outlive the socket it was waiting for. A closed pipe is an
	// ordinary end of tunnel, not a reason to take the agent down.
	gate.on("error", () => gate.destroy())
	source.pipe(gate).pipe(destination)
}

type Shaper = { rx: TokenBucket; tx: TokenBucket; lastUsedAt: number }

export type GatewayShaperOptions = {
	tiers: GatewayTier[]
	targetHost: string
	targetPort: number
	burstSeconds?: number
	/** How long an idle subscriber keeps its buckets. */
	idleMs?: number
	/** Bind address; tests use loopback, production listens on every address. */
	host?: string
}

const DEFAULT_IDLE_MS = 5 * 60 * 1000

/**
 * The listeners themselves. One `net.Server` per tier; a connection is relayed
 * byte for byte to sing-box through two buckets shared by every connection
 * from the same subscriber address - otherwise ten parallel streams would each
 * get the full plan speed.
 */
export class GatewayShaper {
	private readonly servers: net.Server[] = []
	private readonly shapers = new Map<string, Shaper>()
	private sweeper: NodeJS.Timeout | null = null
	private readonly idleMs: number

	constructor(private readonly options: GatewayShaperOptions) {
		this.idleMs = options.idleMs ?? DEFAULT_IDLE_MS
	}

	/** `null` when the operator has not configured any shaped speed. */
	static fromConfig(): GatewayShaper | null {
		if (!config.SHAPING_GATEWAY_ENABLED) return null
		const targetPort = config.SHAPING_GATEWAY_TARGET_PORT
		// Legacy pairs win when a node still has them, so an operator who has not
		// installed the nginx SNI map yet keeps the behaviour they deployed.
		const legacy = parseTiers(config.SHAPING_GATEWAY_TIERS ?? "")
		const configured =
			legacy.length > 0
				? legacy
				: parseSpeedTiers(
						config.SHAPING_GATEWAY_SPEEDS ?? "",
						config.SHAPING_GATEWAY_BASE_PORT ?? DEFAULT_SPEED_BASE_PORT,
					)
		// A relay pointed at its own listener - or at the nginx port that routes
		// back to it - would forward the stream into itself until the node ran
		// out of sockets.
		const tiers = configured.filter((tier) => tier.port !== targetPort)
		if (tiers.length === 0) return null
		return new GatewayShaper({
			tiers,
			targetHost: config.SHAPING_GATEWAY_TARGET_HOST,
			targetPort,
			burstSeconds: config.SHAPING_GATEWAY_BURST_SECONDS,
			// Loopback only: nginx stream is the sole path to a shaped relay, so
			// no cloud port has to be opened and no client can dial the faster
			// tier's listener directly.
			host: config.SHAPING_GATEWAY_BIND_HOST ?? "127.0.0.1",
		})
	}

	/** Ports actually bound, in tier order. Empty until `start` resolves. */
	get ports(): number[] {
		return this.servers.map((server) => {
			const address = server.address()
			return address && typeof address === "object" ? address.port : 0
		})
	}

	/**
	 * "30=8460,50=8461" - the speed-to-port map the nginx SNI router has to
	 * point at. Logged at startup so a mismatch between the generated map and
	 * what is really listening is one `journalctl` away instead of a silent
	 * connection refused for one tier.
	 */
	get tierMap(): string {
		const bound = this.ports
		return this.options.tiers
			.map((tier, index) => `${tier.mbps}=${bound[index] || tier.port}`)
			.join(",")
	}

	private shaperFor(key: string, capBytesPerSecond: number): Shaper {
		const existing = this.shapers.get(key)
		if (existing) {
			existing.lastUsedAt = Date.now()
			existing.rx.setRate(capBytesPerSecond)
			existing.tx.setRate(capBytesPerSecond)
			return existing
		}
		const burstSeconds = this.options.burstSeconds
		const created: Shaper = {
			rx: new TokenBucket({ bytesPerSecond: capBytesPerSecond, burstSeconds }),
			tx: new TokenBucket({ bytesPerSecond: capBytesPerSecond, burstSeconds }),
			lastUsedAt: Date.now(),
		}
		this.shapers.set(key, created)
		return created
	}

	private handle(socket: net.Socket, tier: GatewayTier): void {
		socket.setNoDelay(true)
		// Buckets are shared per subscriber address and per tier. An unknown
		// address (a socket that died during the handshake) still gets its own
		// entry; the sweeper collects it.
		const key = `${tier.mbps}|${socket.remoteAddress ?? "unknown"}`
		const shaper = this.shaperFor(key, bytesPerSecond(tier.mbps))

		const upstream = net.connect({
			host: this.options.targetHost,
			port: this.options.targetPort,
		})
		upstream.setNoDelay(true)

		let closed = false
		const close = (): void => {
			if (closed) return
			closed = true
			shaper.lastUsedAt = Date.now()
			socket.destroy()
			upstream.destroy()
		}

		socket.on("error", close)
		socket.on("close", close)
		upstream.on("error", close)
		upstream.on("close", close)

		upstream.on("connect", () => {
			pipeThrottled(socket, upstream, shaper.tx)
			pipeThrottled(upstream, socket, shaper.rx)
		})
	}

	private sweep(): void {
		const cutoff = Date.now() - this.idleMs
		for (const [key, shaper] of this.shapers) {
			if (shaper.lastUsedAt < cutoff) this.shapers.delete(key)
		}
	}

	async start(): Promise<void> {
		for (const tier of this.options.tiers) {
			const server = net.createServer((socket) => this.handle(socket, tier))
			server.on("error", (error) => {
				// A port that will not bind must not take the agent down: the rest
				// of the fleet's work is unrelated to this relay.
				log.error("shaped gateway listener failed", {
					port: tier.port,
					mbps: tier.mbps,
					reason: errorMessage(error),
				})
			})
			await new Promise<void>((resolve) => {
				server.listen({ port: tier.port, host: this.options.host }, () => resolve())
				server.once("error", () => resolve())
			})
			this.servers.push(server)
		}

		this.sweeper = setInterval(() => this.sweep(), 60_000)
		this.sweeper.unref()

		log.info("shaped vless gateway listening", {
			tiers: this.options.tiers.map((tier) => `${tier.mbps}mbit=${tier.port}`).join(","),
			target: `${this.options.targetHost}:${this.options.targetPort}`,
		})
	}

	async stop(): Promise<void> {
		if (this.sweeper) {
			clearInterval(this.sweeper)
			this.sweeper = null
		}
		await Promise.all(
			this.servers.map(
				(server) =>
					new Promise<void>((resolve) => {
						server.close(() => resolve())
					}),
			),
		)
		this.servers.length = 0
		this.shapers.clear()
	}
}
