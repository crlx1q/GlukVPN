/**
 * HTTPS client for the control plane.
 *
 * The agent never touches PostgreSQL: every state change goes through this API.
 * Authentication uses the node-specific token issued at enrollment
 * (Authorization: Bearer <nodeToken> + X-Node-Id).
 */
import { config } from "../config"

export class ApiError extends Error {
	readonly status: number
	readonly code: string

	constructor(status: number, code: string, message: string) {
		super(message)
		this.name = "ApiError"
		this.status = status
		this.code = code
	}

	/** 401/403 mean the credential is gone: re-enrollment is required. */
	get isAuthFailure(): boolean {
		return this.status === 401 || this.status === 403
	}

	/** Transient conditions worth retrying with backoff. */
	get isRetryable(): boolean {
		return this.status === 0 || this.status === 429 || this.status >= 500
	}
}

export type WireguardParams = {
	interfaceAddress: string
	subnetCidr: string
	listenPort: number
	mtu: number
	dns: string
}

export type RegisterResponse = {
	nodeId: string
	nodeToken: string
	nodeTokenExpiresAt: string
	heartbeatIntervalSec: number
	offlineAfterSec: number
	wireguard: WireguardParams
}

export type CommandType = "ADD_PEER" | "REMOVE_PEER" | "SYNC_PEERS" | "SYNC_POLICY"

export type NodeCommand = {
	id: string
	type: CommandType
	payload: Record<string, unknown>
}

export type HeartbeatResponse = {
	ok: boolean
	serverTime: string
	nodeStatus: string
	heartbeatIntervalSec: number
	nodeTokenExpiresAt: string | null
	/** Version of the sing-box policy the control plane wants applied. */
	policyVersion?: string
	commands: NodeCommand[]
}

/** The sing-box gateway this node advertises to clients. */
export type GatewayInfo = {
	host: string
	port: number
	sni?: string
	flow?: string
}

export type HeartbeatBody = {
	cpuPercent?: number
	ramPercent?: number
	uptimeSeconds?: number
	peerCount?: number
	agentVersion?: string
	wireguardPublicKey?: string
	/** Omit = unchanged; null = this node runs no gateway. */
	gateway?: GatewayInfo | null
	policyVersion?: string
}

export type PeerReport = {
	publicKey: string
	bytesRx: number
	bytesTx: number
	lastHandshakeAt?: string | null
}

export type VlessDomainReport = {
	host: string
	bytesRx: number
	bytesTx: number
	connections: number
	lastSeenAt: string | null
}

/** Per-device deltas since the previous acknowledged report. */
export type VlessUserReport = {
	name: string
	deltaRx: number
	deltaTx: number
	activeConnections: number
	lastSeenAt: string | null
	domains?: VlessDomainReport[]
}

export type ReportResponse = {
	ok: boolean
	/** Peers present on the node that the control plane does not know about. */
	removePeers: string[]
	/** Live sessions whose peer is missing on the node. */
	missingPeers: Array<{ sessionId: string; publicKey: string }>
	vless?: { sessionsUpdated: number; domainsUpdated: number; unknownUsers: string[] }
}

export type PolicyUser = { name: string; uuid: string; flow: string }

export type PolicyRule = {
	kind:
		| "PROTOCOL"
		| "DOMAIN"
		| "DOMAIN_SUFFIX"
		| "DOMAIN_KEYWORD"
		| "DOMAIN_REGEX"
		| "IP_CIDR"
		| "PORT"
		| "PORT_RANGE"
	value: string
	network: string | null
}

export type NodePolicy = {
	version: string
	generatedAt: string
	users: PolicyUser[]
	legacyUser: PolicyUser | null
	rules: PolicyRule[]
	builtinRules: PolicyRule[]
	domainStats: boolean
	flow: string
}

export type PolicyResponse = { ok: boolean; nodeId: string; policy: NodePolicy }

export type RotateResponse = {
	nodeToken: string
	nodeTokenExpiresAt: string
	note?: string
}

type RequestOptions = {
	method: "GET" | "POST"
	path: string
	body?: unknown
	headers?: Record<string, string>
}

async function httpRequest<T>(options: RequestOptions): Promise<T> {
	const url = `${config.CONTROL_API_URL}${options.path}`
	let response: Response
	try {
		response = await fetch(url, {
			method: options.method,
			headers: {
				Accept: "application/json",
				...(options.body ? { "Content-Type": "application/json" } : {}),
				...options.headers,
			},
			body: options.body ? JSON.stringify(options.body) : undefined,
			signal: AbortSignal.timeout(config.HTTP_TIMEOUT_MS),
		})
	} catch (error) {
		const reason = error instanceof Error ? error.message : "network error"
		// status 0 = the request never reached the control plane.
		throw new ApiError(0, "network_error", `${options.method} ${options.path}: ${reason}`)
	}

	const text = await response.text()
	let payload: unknown = null
	if (text) {
		try {
			payload = JSON.parse(text)
		} catch {
			payload = null
		}
	}

	if (!response.ok) {
		const errorBody = (payload as { error?: { code?: string; message?: string } } | null)?.error
		throw new ApiError(
			response.status,
			errorBody?.code ?? "http_error",
			errorBody?.message ?? `HTTP ${response.status} on ${options.path}`,
		)
	}

	return (payload ?? {}) as T
}

/**
 * One-time enrollment. The enrollment token is sent in the body and is consumed
 * server-side; the response carries the long-lived node token.
 */
export async function registerNode(input: {
	enrollmentToken: string
	name: string
	country: string
	countryCode: string
	/** User-facing geography; the app shows these instead of `name`. */
	region?: string
	city?: string
	/** Optional latency target; the control plane falls back to the host. */
	pingTarget?: string
	hostname: string
	publicIp: string
	wireguardPublicKey: string
	wireguardPort: number
	subnetCidr: string
	mtu: number
	agentVersion: string
}): Promise<RegisterResponse> {
	return httpRequest<RegisterResponse>({
		method: "POST",
		path: "/api/node/register",
		body: input,
	})
}

/** Authenticated client used by the running agent. */
export class ControlApi {
	private nodeId: string
	private nodeToken: string

	constructor(options: { nodeId: string; nodeToken: string }) {
		this.nodeId = options.nodeId
		this.nodeToken = options.nodeToken
	}

	get currentToken(): string {
		return this.nodeToken
	}

	setToken(token: string): void {
		this.nodeToken = token
	}

	private authHeaders(): Record<string, string> {
		return {
			Authorization: `Bearer ${this.nodeToken}`,
			"X-Node-Id": this.nodeId,
		}
	}

	async heartbeat(body: HeartbeatBody): Promise<HeartbeatResponse> {
		return httpRequest<HeartbeatResponse>({
			method: "POST",
			path: "/api/node/heartbeat",
			body,
			headers: this.authHeaders(),
		})
	}

	/** Byte counters, handshake/activity times and sniffed host names only — never payloads. */
	async report(peers: PeerReport[], vless?: VlessUserReport[]): Promise<ReportResponse> {
		return httpRequest<ReportResponse>({
			method: "POST",
			path: "/api/node/report",
			body: { peers, ...(vless ? { vless: { users: vless } } : {}) },
			headers: this.authHeaders(),
		})
	}

	/** The sing-box users + reject rules this node should be running. */
	async policy(): Promise<PolicyResponse> {
		return httpRequest<PolicyResponse>({
			method: "GET",
			path: "/api/node/policy",
			headers: this.authHeaders(),
		})
	}

	async ackCommand(
		commandId: string,
		result: { ok: boolean; error?: string },
	): Promise<{ ok: boolean }> {
		return httpRequest<{ ok: boolean }>({
			method: "POST",
			path: `/api/node/commands/${encodeURIComponent(commandId)}/ack`,
			body: result,
			headers: this.authHeaders(),
		})
	}

	/** Issues a fresh token. The old one keeps working until the next heartbeat. */
	async rotateToken(): Promise<RotateResponse> {
		return httpRequest<RotateResponse>({
			method: "POST",
			path: "/api/node/token/rotate",
			headers: this.authHeaders(),
		})
	}
}
