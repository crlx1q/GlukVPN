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
const ALLOWED_PORTS = String(process.env.ALLOWED_PORTS || '80,443,8080,8443')
	.split(',')
	.map((value) => Number(value.trim()))
	.filter(Boolean)
const MAX_PER_DEVICE = Number(process.env.MAX_CONNECTIONS_PER_DEVICE || 128)
const IDLE_TIMEOUT_MS = Number(process.env.IDLE_TIMEOUT_MS || 120_000)
const TLS_CERT = process.env.TLS_CERT || ''
const TLS_KEY = process.env.TLS_KEY || ''
const ALLOW_INSECURE_HTTP = String(process.env.ALLOW_INSECURE_HTTP || 'false') === 'true'
const LOG_LEVEL = process.env.LOG_LEVEL || 'info'

const startedAt = Date.now()
const log = (level, ...args) => {
	if (level === 'debug' && LOG_LEVEL !== 'debug') return
	console.log(`[${new Date().toISOString()}] [${level}]`, ...args)
}

/* ------------------------------------------------------------------- stats */

const stats = new Map() // deviceId -> counters
const totals = { bytesRx: 0, bytesTx: 0, connections: 0, active: 0 }

function counters(deviceId) {
	let entry = stats.get(deviceId)
	if (!entry) {
		entry = { bytesRx: 0, bytesTx: 0, connections: 0, active: 0, since: Date.now() }
		stats.set(deviceId, entry)
	}
	return entry
}

/* -------------------------------------------------------------------- auth */

const authCache = new Map() // sha256(token) -> { ok, until, reason, deviceId }

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

async function verify(credentials) {
	if (!credentials?.token) return { ok: false, reason: 'missing-credentials' }
	const key = crypto.createHash('sha256').update(credentials.token).digest('hex')
	const cached = authCache.get(key)
	if (cached && cached.until > Date.now()) return cached

	let result = { ok: false, reason: 'control-plane-unreachable', until: Date.now() + 5_000 }
	try {
		const response = await fetch(`${CONTROL_API}/api/vpn/status`, {
			headers: { authorization: `Bearer ${credentials.token}` },
			signal: AbortSignal.timeout(8_000),
		})
		if (response.status === 401 || response.status === 403) {
			result = { ok: false, reason: 'token-rejected', until: Date.now() + AUTH_TTL_MS }
		} else if (response.ok) {
			const body = await response.json()
			if (body.subscriptionActive === false) {
				result = { ok: false, reason: 'subscription-inactive', until: Date.now() + AUTH_TTL_MS }
			} else if (REQUIRE_SESSION && body.connected !== true) {
				result = { ok: false, reason: 'no-active-session', until: Date.now() + 10_000 }
			} else {
				result = {
					ok: true,
					deviceId: credentials.username || body.session?.deviceId || 'browser',
					until: Date.now() + AUTH_TTL_MS,
				}
			}
		}
	} catch (error) {
		log('debug', 'control plane check failed:', error.message)
	}
	authCache.set(key, result)
	return result
}

setInterval(() => {
	const now = Date.now()
	for (const [key, value] of authCache) if (value.until <= now) authCache.delete(key)
}, 60_000).unref()

/* ------------------------------------------------------------ target rules */

const PRIVATE_V4 =
	/^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|192\.0\.2\.|198\.1[89]\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/

function isBlockedAddress(address) {
	if (!address) return true
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
	})
	res.end(payload)
}

async function handleControl(req, res, path) {
	if (path === '/__gluk/ping') {
		res.writeHead(204, { 'access-control-allow-origin': '*', 'cache-control': 'no-store' })
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
		sendJson(res, 401, { error: { code: auth.reason ?? 'unauthorized' } })
		return
	}
	const mine = counters(auth.deviceId)
	sendJson(res, 200, {
		ok: true,
		version: VERSION,
		requireSession: REQUIRE_SESSION,
		uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
		// The extension shows these as Downloaded / Uploaded, from the browser's view.
		bytesRx: mine.bytesRx,
		bytesTx: mine.bytesTx,
		connections: mine.active,
		totalConnections: mine.connections,
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
		res.writeHead(407, {
			'proxy-authenticate': 'Basic realm="GlukVPN"',
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
		totals.bytesTx += chunk.length
	})
	req.pipe(upstream)
}

/* ----------------------------------------------------------- CONNECT proxy */

function denyConnect(socket, code, reason) {
	const extra =
		code === 407 ? 'Proxy-Authenticate: Basic realm="GlukVPN"\r\n' : ''
	socket.write(
		`HTTP/1.1 ${code} ${reason}\r\n${extra}Proxy-Agent: GlukVPN-Gateway/${VERSION}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`,
	)
	socket.destroy()
}

async function handleConnect(req, clientSocket, head) {
	clientSocket.on('error', () => clientSocket.destroy())

	const credentials = parseBasic(req)
	const auth = await verify(credentials)
	if (!auth.ok) {
		log('debug', 'CONNECT denied:', auth.reason)
		denyConnect(clientSocket, auth.reason === 'token-rejected' || !credentials ? 407 : 403, auth.reason ?? 'Forbidden')
		return
	}

	const [rawHost, rawPort] = String(req.url || '').split(':')
	const port = Number(rawPort || 443)
	if (!rawHost || !ALLOWED_PORTS.includes(port)) {
		denyConnect(clientSocket, 403, 'Port Not Allowed')
		return
	}

	const stat = counters(auth.deviceId)
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

	const upstream = net.connect({ host: address, port }, () => {
		stat.connections += 1
		stat.active += 1
		totals.connections += 1
		totals.active += 1
		clientSocket.write(
			`HTTP/1.1 200 Connection Established\r\nProxy-Agent: GlukVPN-Gateway/${VERSION}\r\n\r\n`,
		)
		if (head?.length) upstream.write(head)

		clientSocket.on('data', (chunk) => {
			stat.bytesTx += chunk.length
			totals.bytesTx += chunk.length
		})
		upstream.on('data', (chunk) => {
			stat.bytesRx += chunk.length
			totals.bytesRx += chunk.length
		})
		clientSocket.pipe(upstream)
		upstream.pipe(clientSocket)
	})

	let closed = false
	const close = () => {
		if (closed) return
		closed = true
		if (stat.active > 0) stat.active -= 1
		if (totals.active > 0) totals.active -= 1
		upstream.destroy()
		clientSocket.destroy()
	}

	upstream.setTimeout(IDLE_TIMEOUT_MS, close)
	clientSocket.setTimeout(IDLE_TIMEOUT_MS, close)
	upstream.on('error', () => {
		if (!closed && !clientSocket.destroyed) denyConnect(clientSocket, 502, 'Bad Gateway')
		close()
	})
	upstream.on('close', close)
	clientSocket.on('close', close)
}

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
		server.close(() => process.exit(0))
		setTimeout(() => process.exit(0), 3_000).unref()
	})
}
