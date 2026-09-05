'use strict'

/*
 * GlukVPN browser gateway.
 *
 * Browsers cannot speak WireGuard from an extension (no raw UDP, no TUN), so the
 * extension routes traffic through this TLS CONNECT proxy that runs on the same
 * node as wg0. The browser authenticates with Basic credentials:
 *
 *   username = device id issued by /api/devices/register
 *   password = the device-scoped access token
 *
 * The gateway never sees a password and never stores a token: it forwards the
 * token to the control plane and caches only the yes/no answer.
 *
 * No control-server changes are required.
 */

const fs = require('node:fs')
const net = require('node:net')
const http = require('node:http')
const https = require('node:https')
const crypto = require('node:crypto')
const dns = require('node:dns').promises

const VERSION = '1.0.0'

const PORT = Number(process.env.PORT || 8443)
const BIND_HOST = process.env.BIND_HOST || '0.0.0.0'
const CONTROL_API = (process.env.CONTROL_API || 'https://api.gluk.tech').replace(/\/+$/, '')
// true  = the device must hold an active VPN session (POST /api/vpn/connect succeeded)
// false = any valid token with an active subscription is enough. Use false when
//         maxConcurrentSessions is 1 and the phone should keep the tunnel.
const REQUIRE_SESSION = String(process.env.REQUIRE_SESSION ?? 'true') !== 'false'
const AUTH_TTL_MS = Number(process.env.AUTH_CACHE_TTL_MS || 60_000)
const REVALIDATE_INTERVAL_MS = Math.min(300_000, Math.max(5_000, Number(process.env.REVALIDATE_INTERVAL_MS || 15_000)))
const TOKEN_RETENTION_MS = Math.max(REVALIDATE_INTERVAL_MS * 2, Number(process.env.TOKEN_RETENTION_MS || 300_000))
const ALLOWED_PORTS = String(process.env.ALLOWED_PORTS || '80,443,8080,8443')
	.split(',')
	.map((value) => Number(value.trim()))
	.filter(Boolean)
const MAX_PER_DEVICE = Number(process.env.MAX_CONNECTIONS_PER_DEVICE || 128)
const IDLE_TIMEOUT_MS = Number(process.env.IDLE_TIMEOUT_MS || 120_000)
const TLS_CERT = process.env.TLS_CERT || ''
const TLS_KEY = process.env.TLS_KEY || ''
const ALLOW_INSECURE_HTTP = String(process.env.ALLOW_INSECURE_HTTP || 'false') === 'true'
const ALLOW_TEST_LOOPBACK_TARGET = ALLOW_INSECURE_HTTP && process.env.NODE_ENV === 'test' && ['127.0.0.1', '::1', 'localhost'].includes(BIND_HOST) && String(process.env.ALLOW_TEST_LOOPBACK_TARGET || 'false') === 'true'
const LOG_LEVEL = process.env.LOG_LEVEL || 'info'

const startedAt = Date.now()
const log = (level, ...args) => {
	if (level === 'debug' && LOG_LEVEL !== 'debug') return
	console.log(`[${new Date().toISOString()}] [${level}]`, ...args)
}

/* ------------------------------------------------------------------- stats */

const stats = new Map() // deviceId -> counters
const userStats = new Map() // userId -> counters
const totals = { bytesRx: 0, bytesTx: 0, connections: 0, active: 0 }

function counters(deviceId) {
	let entry = stats.get(deviceId)
	if (!entry) {
		entry = { bytesRx: 0, bytesTx: 0, connections: 0, active: 0, since: Date.now(), token: null, tokenTouchedAt: 0, reportedRx: 0, reportedTx: 0 }
		stats.set(deviceId, entry)
	}
	return entry
}

function userCounters(userId) {
	if (!userId) return null
	let entry = userStats.get(userId)
	if (!entry) {
		entry = { bytesRx: 0, bytesTx: 0, connections: 0, active: 0, since: Date.now(), token: null, tokenTouchedAt: 0, reportedRx: 0, reportedTx: 0 }
		userStats.set(userId, entry)
	}
	return entry
}

function extractUserId(token) {
	if (!token || typeof token !== 'string') return null
	try {
		const part = token.split('.')[1]
		if (!part) return null
		const json = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))
		return json.sub || null
	} catch {
		return null
	}
}

/* -------------------------------------------------------------------- auth */

const authCache = new Map() // sha256(token) -> { ok, until, reason, deviceId }
const maintenanceByApi = new Map() // channel URL -> confirmed service-wide cutoff expiry

function parseBasic(req) {
	const header = req.headers['proxy-authorization'] || req.headers.authorization
	if (!header || !/^basic /i.test(header)) return null
	let decoded
	try {
		decoded = Buffer.from(header.slice(6).trim(), 'base64').toString('utf8')
	} catch {
		return null
	}
	const index = decoded.indexOf(':')
	if (index < 1) return null
	return { username: decoded.slice(0, index), token: decoded.slice(index + 1) }
}

async function verifyWith(apiBase, credentials, requireSession = REQUIRE_SESSION) {
	const answer = (value) => ({ ...value, apiBase })
	try {
		const response = await fetch(`${apiBase}/api/vpn/status`, {
			headers: { authorization: `Bearer ${credentials.token}` },
			signal: AbortSignal.timeout(8_000),
		})
		let body = null
		try { body = await response.json() } catch {}
		if (response.ok) {
			if (!body || typeof body !== 'object') return null
			if (body.service?.maintenance === true || body.nodeMaintenance === true) {
				const retryMs = Math.min(300_000, Math.max(5_000, (Number(body.service?.retryAfterSec) || 30) * 1000))
				return answer({ ok: false, reason: 'maintenance', maintenanceScope: body.service?.maintenance === true ? 'service' : 'node', explicit: true, until: Date.now() + retryMs })
			}
			if (body.subscriptionActive === false) return answer({ ok: false, reason: 'subscription-inactive', explicit: true, until: Date.now() + AUTH_TTL_MS })
			if (requireSession && body.connected !== true) return answer({ ok: false, reason: 'no-active-session', explicit: true, until: Date.now() + 10_000 })
			return answer({ ok: true, userId: extractUserId(credentials.token), deviceId: credentials.username || body.session?.deviceId || 'browser', until: Date.now() + AUTH_TTL_MS })
		}
		if (response.status === 401 || response.status === 403) return answer({ ok: false, reason: 'token-rejected', explicit: true, until: Date.now() })
		if (response.status === 503 && body?.error?.code === 'maintenance') return answer({ ok: false, reason: 'maintenance', maintenanceScope: body.error.details?.nodeId ? 'node' : 'service', explicit: true, until: Date.now() + 5_000 })
	} catch (error) {
		log('debug', `control plane (${apiBase}) check failed:`, error.message)
	}
	return null // A transient failure must not close an established tunnel.
}

function fallbackApi() {
	return (process.env.CONTROL_FALLBACK_API || (CONTROL_API.includes('8082') ? 'http://127.0.0.1:8081' : 'http://127.0.0.1:8082')).replace(/\/+$/, '')
}

async function verifyFresh(credentials, requireSession = REQUIRE_SESSION, preferredApi = null) {
	// Once authenticated, a tunnel is bound to its owning control plane. A
	// revocation there must never be overridden by the other channel's database.
	let result = await verifyWith(preferredApi || CONTROL_API, credentials, requireSession)
	if (!preferredApi && (result === null || result.reason === 'token-rejected')) {
		const alternate = await verifyWith(fallbackApi(), credentials, requireSession)
		if (alternate && alternate.reason !== 'token-rejected') result = alternate
		else if (result === null) result = alternate
	}
	if (result?.reason === 'maintenance' && result.maintenanceScope === 'service') maintenanceByApi.set(result.apiBase, result.until)
	else if (result?.ok) maintenanceByApi.delete(result.apiBase)
	return result
}

async function verify(credentials) {
	if (!credentials?.token) return { ok: false, reason: 'missing-credentials' }
	const key = crypto.createHash('sha256').update(credentials.token).digest('hex')
	const cached = authCache.get(key)
	if (cached && cached.until > Date.now()) {
		const cutoff = maintenanceByApi.get(cached.apiBase) || 0
		if (cutoff > Date.now()) return { ok: false, reason: 'maintenance', maintenanceScope: 'service', apiBase: cached.apiBase, until: cutoff }
		if (credentials.username && cached.deviceId !== credentials.username) {
			cached.deviceId = credentials.username
		}
		if (!cached.userId) {
			cached.userId = extractUserId(credentials.token)
		}
		return cached
	}

	let result = await verifyFresh(credentials, REQUIRE_SESSION, cached?.apiBase || null)
	if (!result) result = { ok: false, reason: 'control-plane-unreachable', until: Date.now() + 5_000 }
	if (result.reason === 'token-rejected') {
		authCache.delete(key)
		return result
	}
	authCache.set(key, result)
	return result
}

const authCleanupTimer = setInterval(() => {
	const now = Date.now()
	for (const [key, value] of authCache) if (value.until <= now) authCache.delete(key)
	for (const [api, until] of maintenanceByApi) if (until <= now) maintenanceByApi.delete(api)
	for (const stat of stats.values()) {
		if (stat.active === 0 && stat.token && now - stat.tokenTouchedAt >= TOKEN_RETENTION_MS) stat.token = null
	}
	for (const stat of userStats.values()) {
		if (stat.active === 0 && stat.token && now - stat.tokenTouchedAt >= TOKEN_RETENTION_MS) stat.token = null
	}
}, 60_000)
authCleanupTimer.unref()

async function reportToControlPlane(apiBase, token, deviceId, bytesRx, bytesTx) {
	if (!token || (!bytesRx && !bytesTx)) return
	try {
		const payload = JSON.stringify({
			downloadBytes: bytesRx,
			uploadBytes: bytesTx,
			transport: 'browser',
		})
		let res = await fetch(`${apiBase}/api/vpn/stats`, {
			method: 'POST',
			headers: {
				'authorization': `Bearer ${token}`,
				'content-type': 'application/json',
			},
			body: payload,
		})
		if (!res.ok && apiBase === CONTROL_API) {
			const fallbackApi = CONTROL_API.includes('8082') ? 'http://127.0.0.1:8081' : 'http://127.0.0.1:8082'
			await fetch(`${fallbackApi}/api/vpn/stats`, {
				method: 'POST',
				headers: {
					'authorization': `Bearer ${token}`,
					'content-type': 'application/json',
				},
				body: payload,
			}).catch(() => {})
		}
	} catch (err) {
		log('debug', `Failed to report stats to ${apiBase} for device ${deviceId}:`, err.message)
	}
}

async function flushStatsToControlPlane() {
	for (const [deviceId, stat] of stats) {
		if (!stat.token) continue
		const rx = stat.bytesRx || 0
		const tx = stat.bytesTx || 0
		if (rx === stat.reportedRx && tx === stat.reportedTx) continue
		stat.reportedRx = rx
		stat.reportedTx = tx
		await reportToControlPlane(CONTROL_API, stat.token, deviceId, rx, tx)
	}
}

const statsFlushTimer = setInterval(flushStatsToControlPlane, 10_000)
statsFlushTimer.unref()

/* ------------------------------------------------------------ target rules */

const PRIVATE_V4 =
	/^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|192\.0\.2\.|198\.1[89]\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/

function isBlockedAddress(address) {
	if (!address) return true
	// Test-only escape hatch requires the separately explicit cleartext mode.
	if (ALLOW_TEST_LOOPBACK_TARGET && /^127\./.test(address)) return false
	if (address.includes(':')) {
		const lower = address.toLowerCase()
		return lower === '::1' || lower.startsWith('fc') || lower.startsWith('fd') || lower.startsWith('fe80')
	}
	return PRIVATE_V4.test(address)
}

/** Resolve first so a public hostname cannot be pointed at the node's own LAN. */
async function resolveTarget(hostname) {
	if (net.isIP(hostname)) {
		if (isBlockedAddress(hostname)) throw new Error('blocked-address')
		return hostname
	}
	const { address } = await dns.lookup(hostname)
	if (isBlockedAddress(address)) throw new Error('blocked-address')
	return address
}

/* ---------------------------------------------------------------- control */

function sendJson(res, code, body) {
	const payload = JSON.stringify(body)
	res.writeHead(code, {
		'content-type': 'application/json; charset=utf-8',
		'content-length': Buffer.byteLength(payload),
		'cache-control': 'no-store',
		'access-control-allow-origin': '*',
		'access-control-allow-methods': 'GET, POST, OPTIONS',
		'access-control-allow-headers': 'authorization, proxy-authorization, content-type',
	})
	res.end(payload)
}

async function handleControl(req, res, path) {
	if (req.method === 'OPTIONS') {
		res.writeHead(204, {
			'access-control-allow-origin': '*',
			'access-control-allow-methods': 'GET, POST, OPTIONS',
			'access-control-allow-headers': 'authorization, proxy-authorization, content-type',
			'access-control-max-age': '86400',
			'cache-control': 'no-store',
		})
		res.end()
		return
	}
	if (path === '/__gluk/ping') {
		res.writeHead(204, {
			'access-control-allow-origin': '*',
			'access-control-allow-methods': 'GET, POST, OPTIONS',
			'access-control-allow-headers': 'authorization, proxy-authorization, content-type',
			'cache-control': 'no-store',
		})
		res.end()
		return
	}
	if (path !== '/__gluk/stats') {
		sendJson(res, 404, { error: { code: 'not_found' } })
		return
	}
	const credentials = parseBasic(req)
	const auth = await verify(credentials)
	if (!auth.ok) {
		log('info', `Control stats denied (${auth.reason}) from ${req.socket.remoteAddress}`)
		sendJson(res, auth.reason === 'maintenance' ? 503 : 401, { error: { code: auth.reason ?? 'unauthorized' } })
		return
	}
	const mine = counters(auth.deviceId)
	const uStat = userCounters(auth.userId)
	if (credentials?.token) {
		mine.token = credentials.token
		mine.tokenTouchedAt = Date.now()
		if (uStat) {
			uStat.token = credentials.token
			uStat.tokenTouchedAt = Date.now()
		}
	}
	const bytesRx = Math.max(mine.bytesRx, uStat?.bytesRx ?? 0)
	const bytesTx = Math.max(mine.bytesTx, uStat?.bytesTx ?? 0)
	const active = Math.max(mine.active, uStat?.active ?? 0)
	const totalConnections = Math.max(mine.connections, uStat?.connections ?? 0)

	// Keep device counters in sync with the user's total proxy usage
	mine.bytesRx = bytesRx
	mine.bytesTx = bytesTx

	// Synchronize with control plane so admin panel and database session reflect active traffic
	void reportToControlPlane(CONTROL_API, credentials?.token, auth.deviceId, bytesRx, bytesTx)

	log('info', `Control stats allowed for device ${auth.deviceId} (user ${auth.userId}) from ${req.socket.remoteAddress}: rx=${bytesRx}, tx=${bytesTx}, active=${active}`)
	sendJson(res, 200, {
		ok: true,
		version: VERSION,
		requireSession: REQUIRE_SESSION,
		uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
		// The extension shows these as Downloaded / Uploaded, from the browser's view.
		bytesRx,
		bytesTx,
		connections: active,
		totalConnections,
		gateway: { activeConnections: totals.active, totalConnections: totals.connections },
	})
}

/* ------------------------------------------------------- plain http proxy */

async function handleRequest(req, res) {
	const target = req.url || '/'
	if (target.startsWith('/__gluk/')) {
		await handleControl(req, res, target.split('?')[0])
		return
	}
	if (!/^http:\/\//i.test(target)) {
		sendJson(res, 400, { error: { code: 'not_a_proxy_request' } })
		return
	}

	const credentials = parseBasic(req)
	const auth = await verify(credentials)
	if (!auth.ok) {
		const status = auth.reason === 'maintenance' ? 503 : 407
		res.writeHead(status, {
			...(status === 407 ? { 'proxy-authenticate': 'Basic realm="GlukVPN-Browser"' } : {}),
			'content-type': 'application/json',
		})
		res.end(JSON.stringify({ error: { code: auth.reason ?? 'unauthorized' } }))
		return
	}

	let url
	try {
		url = new URL(target)
	} catch {
		sendJson(res, 400, { error: { code: 'bad_url' } })
		return
	}
	const port = Number(url.port || 80)
	if (!ALLOWED_PORTS.includes(port)) {
		sendJson(res, 403, { error: { code: 'port_not_allowed' } })
		return
	}

	let address
	try {
		address = await resolveTarget(url.hostname)
	} catch {
		sendJson(res, 403, { error: { code: 'target_not_allowed' } })
		return
	}

	const stat = counters(auth.deviceId)
	const uStat = userCounters(auth.userId)
	if (credentials?.token) {
		stat.token = credentials.token
		stat.tokenTouchedAt = Date.now()
		if (uStat) {
			uStat.token = credentials.token
			uStat.tokenTouchedAt = Date.now()
		}
	}
	const headers = { ...req.headers }
	delete headers['proxy-authorization']
	delete headers['proxy-connection']
	headers.host = url.host

	const upstream = http.request(
		{ host: address, port, method: req.method, path: `${url.pathname}${url.search}`, headers, setHost: false },
		(upstreamRes) => {
			res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers)
			upstreamRes.on('data', (chunk) => {
				stat.bytesRx += chunk.length
				if (uStat) uStat.bytesRx += chunk.length
				totals.bytesRx += chunk.length
			})
			upstreamRes.pipe(res)
		},
	)
	upstream.setTimeout(IDLE_TIMEOUT_MS, () => upstream.destroy())
	upstream.on('error', () => {
		if (!res.headersSent) res.writeHead(502)
		res.end()
	})
	req.on('data', (chunk) => {
		stat.bytesTx += chunk.length
		if (uStat) uStat.bytesTx += chunk.length
		totals.bytesTx += chunk.length
	})
	req.pipe(upstream)
}

/* ----------------------------------------------------------- CONNECT proxy */

const liveTunnels = new Map() // tunnel id -> exact device/token and close callback
let nextTunnelId = 0
let revalidationRunning = false

function denyConnect(socket, code, reason) {
	const statusText =
		code === 407 ? 'Proxy Authentication Required' :
		code === 403 ? 'Forbidden' :
		code === 429 ? 'Too Many Requests' :
		code === 503 ? 'Service Unavailable' :
		code === 502 ? 'Bad Gateway' : (reason || 'Error')
	const extra =
		code === 407 ? 'Proxy-Authenticate: Basic realm="GlukVPN-Browser"\r\n' : ''
	const payload = `HTTP/1.1 ${code} ${statusText}\r\n${extra}Proxy-Agent: GlukVPN-Gateway/${VERSION}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`
	try {
		socket.end(payload)
	} catch {
		socket.destroy()
	}
}

async function handleConnect(req, clientSocket, head) {
	clientSocket.on('error', () => clientSocket.destroy())

	const credentials = parseBasic(req)
	const auth = await verify(credentials)
	if (!auth.ok) {
		log('info', `CONNECT denied (${auth.reason}) from ${clientSocket.remoteAddress} for ${req.url}`)
		denyConnect(clientSocket, auth.reason === 'maintenance' ? 503 : auth.reason === 'token-rejected' || !credentials ? 407 : 403, auth.reason ?? 'Forbidden')
		return
	}
	log('info', `CONNECT allowed for device ${auth.deviceId} (user ${auth.userId}) from ${clientSocket.remoteAddress} to ${req.url}`)

	const [rawHost, rawPort] = String(req.url || '').split(':')
	const port = Number(rawPort || 443)
	if (!rawHost || !ALLOWED_PORTS.includes(port)) {
		denyConnect(clientSocket, 403, 'Port Not Allowed')
		return
	}

	const stat = counters(auth.deviceId)
	const uStat = userCounters(auth.userId)
	if (credentials?.token) {
		stat.token = credentials.token
		stat.tokenTouchedAt = Date.now()
		if (uStat) {
			uStat.token = credentials.token
			uStat.tokenTouchedAt = Date.now()
		}
	}
	if (stat.active >= MAX_PER_DEVICE) {
		denyConnect(clientSocket, 429, 'Too Many Connections')
		return
	}

	let address
	try {
		address = await resolveTarget(rawHost.replace(/^\[|\]$/g, ''))
	} catch {
		denyConnect(clientSocket, 403, 'Target Not Allowed')
		return
	}

	let tunnelId = null
	let established = false
	const upstream = net.connect({ host: address, port }, () => {
		if (closed || clientSocket.destroyed) { upstream.destroy(); return }
		if ((maintenanceByApi.get(auth.apiBase) || 0) > Date.now()) {
			denyConnect(clientSocket, 503, 'maintenance'); close('maintenance'); return
		}
		established = true
		stat.connections += 1
		stat.active += 1
		if (uStat) {
			uStat.connections += 1
			uStat.active += 1
		}
		totals.connections += 1
		totals.active += 1
		tunnelId = ++nextTunnelId
		liveTunnels.set(tunnelId, {
			id: tunnelId,
			apiBase: auth.apiBase,
			deviceId: auth.deviceId,
			tokenHash: crypto.createHash('sha256').update(credentials.token).digest('hex'),
			credentials: { username: auth.deviceId, token: credentials.token },
			close: (reason) => close(reason),
		})
		clientSocket.write(
			`HTTP/1.1 200 Connection Established\r\nProxy-Agent: GlukVPN-Gateway/${VERSION}\r\n\r\n`,
		)
		if (head?.length) {
			upstream.write(head)
			stat.bytesTx += head.length
			if (uStat) uStat.bytesTx += head.length
			totals.bytesTx += head.length
		}

		clientSocket.on('data', (chunk) => {
			stat.bytesTx += chunk.length
			if (uStat) uStat.bytesTx += chunk.length
			totals.bytesTx += chunk.length
		})
		upstream.on('data', (chunk) => {
			stat.bytesRx += chunk.length
			if (uStat) uStat.bytesRx += chunk.length
			totals.bytesRx += chunk.length
		})
		clientSocket.pipe(upstream)
		upstream.pipe(clientSocket)
	})

	let closed = false
	const close = (reason = 'closed') => {
		if (closed) return
		closed = true
		if (tunnelId !== null) liveTunnels.delete(tunnelId)
		if (established) {
			if (stat.active > 0) stat.active -= 1
			if (uStat && uStat.active > 0) uStat.active -= 1
			if (totals.active > 0) totals.active -= 1
		}
		stat.tokenTouchedAt = Date.now()
		if (uStat) uStat.tokenTouchedAt = Date.now()
		upstream.destroy()
		clientSocket.destroy()
		if (reason !== 'closed') log('info', `CONNECT closed for device ${auth.deviceId} (${reason})`)
	}

	upstream.setTimeout(IDLE_TIMEOUT_MS, close)
	clientSocket.setTimeout(IDLE_TIMEOUT_MS, close)
	upstream.on('error', () => {
		if (!closed && !clientSocket.destroyed) denyConnect(clientSocket, 502, 'Bad Gateway')
		close()
	})
	upstream.on('close', () => close())
	clientSocket.on('close', () => close())
}

async function revalidateLiveTunnels() {
	if (revalidationRunning || liveTunnels.size === 0) return
	revalidationRunning = true
	try {
		const groups = new Map()
		for (const tunnel of liveTunnels.values()) {
			const key = `${tunnel.apiBase}:${tunnel.deviceId}:${tunnel.tokenHash}`
			if (!groups.has(key)) groups.set(key, { apiBase: tunnel.apiBase, credentials: tunnel.credentials, tokenHash: tunnel.tokenHash, tunnels: [] })
			groups.get(key).tunnels.push(tunnel)
		}
		for (const group of groups.values()) {
			if (!group.tunnels.some((tunnel) => liveTunnels.has(tunnel.id))) continue
			const result = await verifyFresh(group.credentials, REQUIRE_SESSION, group.apiBase)
			if (result === null) continue // transient outage: preserve established tunnels
			if (!result.ok) authCache.delete(group.tokenHash)
			if (result.reason === 'maintenance' && result.maintenanceScope === 'service') {
				for (const tunnel of [...liveTunnels.values()]) {
					if (tunnel.apiBase === result.apiBase) tunnel.close('maintenance')
				}
				continue
			}
			if (!result.ok) {
				for (const tunnel of group.tunnels) tunnel.close(result.reason || 'revoked')
			}
		}
	} finally {
		revalidationRunning = false
	}
}

const revalidationTimer = setInterval(() => {
	revalidateLiveTunnels().catch((error) => log('debug', 'live tunnel revalidation failed:', error.message))
}, REVALIDATE_INTERVAL_MS)
revalidationTimer.unref()

/* ------------------------------------------------------------------ boot */

function createServer() {
	if (TLS_CERT && TLS_KEY) {
		const options = { cert: fs.readFileSync(TLS_CERT), key: fs.readFileSync(TLS_KEY) }
		if (process.env.TLS_CA) options.ca = fs.readFileSync(process.env.TLS_CA)
		return { server: https.createServer(options), scheme: 'https' }
	}
	if (!ALLOW_INSECURE_HTTP) {
		console.error(
			'Refusing to start: set TLS_CERT and TLS_KEY, or ALLOW_INSECURE_HTTP=true for local testing only.',
		)
		process.exit(1)
	}
	log('warn', 'starting WITHOUT TLS - credentials travel in clear text, testing only')
	return { server: http.createServer(), scheme: 'http' }
}

const { server, scheme } = createServer()
server.on('request', (req, res) => {
	handleRequest(req, res).catch((error) => {
		log('warn', 'request failed:', error.message)
		if (!res.headersSent) res.writeHead(500)
		res.end()
	})
})
server.on('connect', (req, socket, head) => {
	handleConnect(req, socket, head).catch((error) => {
		log('warn', 'connect failed:', error.message)
		socket.destroy()
	})
})
server.on('clientError', (_error, socket) => socket.destroy())
server.headersTimeout = 30_000

server.listen(PORT, BIND_HOST, () => {
	log('info', `GlukVPN browser gateway ${VERSION} listening on ${scheme}://${BIND_HOST}:${PORT}`)
	log('info', `control plane: ${CONTROL_API} | requireSession: ${REQUIRE_SESSION}`)
	log('info', `allowed CONNECT ports: ${ALLOWED_PORTS.join(', ')}`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
	process.on(signal, () => {
		log('info', 'shutting down')
		clearInterval(authCleanupTimer)
		clearInterval(statsFlushTimer)
		clearInterval(revalidationTimer)
		for (const tunnel of [...liveTunnels.values()]) tunnel.close('shutdown')
		server.close(() => process.exit(0))
		setTimeout(() => process.exit(0), 3_000).unref()
	})
}
