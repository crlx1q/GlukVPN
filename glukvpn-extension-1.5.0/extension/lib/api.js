/*
 * Typed client for the GlukVPN control plane, mirroring
 * flutter-client/lib/services/api_client.dart:
 *
 *  - one place that knows the URL layout and the { error: { code, message } } envelope
 *  - single-flight access-token refresh, so parallel 401s cause one refresh call
 *  - the offline / revoked distinction: only an explicit 401 or 403 ends the
 *    session. A timeout or a 5xx means "ask again later", never "log the user out".
 */

import { Store } from './store.js'

export const REFRESH = { ok: 'ok', offline: 'offline', revoked: 'revoked' }

const TIMEOUT_MS = 15000
// Refresh a little before the 15 minute access token actually dies.
const EXPIRY_SKEW_MS = 60000

export class ApiError extends Error {
	constructor({ statusCode, code, message, retryAfterSec, details }) {
		super(message)
		this.name = 'ApiError'
		this.statusCode = Number(statusCode) || 0
		this.code = String(code || 'error')
		this.retryAfterSec = Number(retryAfterSec ?? details?.retryAfterSec) || null
		// Structured, non-secret context is needed by the device manager and
		// maintenance recovery UI. Keep the server object intact; the worker
		// performs the final allow-listed serialization before crossing MV3.
		this.details = details && typeof details === 'object' ? details : null
	}
	get isNetwork() {
		return this.statusCode === 0
	}
	get isUnauthorized() {
		return this.statusCode === 401
	}
	get isForbidden() {
		return this.statusCode === 403
	}
	get isConflict() {
		return this.statusCode === 409
	}
	get isRateLimited() {
		return this.statusCode === 429
	}
	get isDeviceRevoked() {
		return this.isForbidden && /device/i.test(`${this.code} ${this.message}`)
	}
}

let refreshing = null
let lastRefresh = REFRESH.ok

async function baseUrl() {
	const settings = await Store.settings()
	const raw = settings.apiBase[settings.channel] ?? settings.apiBase.prod
	return raw.replace(/\/+$/, '')
}

async function tokens() {
	const session = await Store.session()
	return session?.tokens ?? null
}

function expiring(bundle) {
	if (!bundle?.accessTokenExpiresAt) return true
	return Date.parse(bundle.accessTokenExpiresAt) - Date.now() <= EXPIRY_SKEW_MS
}

function bundleFrom(json, previousDeviceId) {
	const expiresIn = Number(json.expiresIn ?? 900)
	return {
		accessToken: String(json.accessToken ?? ''),
		accessTokenExpiresAt: new Date(Date.now() + expiresIn * 1000).toISOString(),
		refreshToken: String(json.refreshToken ?? ''),
		refreshTokenExpiresAt: json.refreshTokenExpiresAt ?? null,
		deviceId: json.deviceId ?? previousDeviceId ?? null,
	}
}

async function request(method, path, { body, authenticated = true, allowRefresh = true, absoluteUrl } = {}) {
	if (authenticated && allowRefresh) {
		const current = await tokens()
		if (current && expiring(current)) await tryRefresh()
	}

	const url = absoluteUrl ?? `${await baseUrl()}${path}`
	const headers = { accept: 'application/json' }
	if (body !== undefined) headers['content-type'] = 'application/json'
	if (authenticated) {
		const bundle = await tokens()
		if (bundle?.accessToken) headers.authorization = `Bearer ${bundle.accessToken}`
	}

	const controller = new AbortController()
	const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
	let response
	try {
		response = await fetch(url, {
			method,
			headers,
			body: body === undefined ? undefined : JSON.stringify(body),
			signal: controller.signal,
			cache: 'no-store',
			credentials: 'omit',
		})
	} catch (error) {
		// Never echo the platform error: it can carry the URL and means nothing
		// to the user.
		throw new ApiError({
			statusCode: 0,
			code: error?.name === 'AbortError' ? 'timeout' : 'network_error',
			message:
				error?.name === 'AbortError'
					? 'The server did not respond in time.'
					: 'Cannot reach the server. Check your internet connection.',
		})
	} finally {
		clearTimeout(timer)
	}

	if (response.status === 401 && authenticated && allowRefresh) {
		const refreshed = await tryRefresh()
		if (refreshed) {
			return request(method, path, { body, authenticated, allowRefresh: false, absoluteUrl })
		}
	}

	let json = {}
	const text = await response.text()
	if (text) {
		try {
			json = JSON.parse(text)
		} catch {
			json = {}
		}
	}
	if (response.ok) return json

	const error = json?.error ?? {}
	throw new ApiError({
		statusCode: response.status,
		code: String(error.code ?? `http_${response.status}`),
		message: String(error.message ?? `Request failed (${response.status}).`),
		retryAfterSec: Number(response.headers.get('retry-after')) || Number(error.details?.retryAfterSec) || null,
		details: error.details,
	})
}

async function tryRefresh() {
	if (refreshing) {
		await refreshing
		return (await tokens()) !== null
	}
	const current = await tokens()
	if (!current?.refreshToken) return false

	refreshing = (async () => {
		try {
			const latest = await tokens()
			if (latest && latest.refreshToken !== current.refreshToken && latest.accessToken) {
				lastRefresh = REFRESH.ok
				return true
			}
			const json = await request('POST', '/api/auth/refresh', {
				body: { refreshToken: current.refreshToken },
				authenticated: false,
				allowRefresh: false,
			})
			const session = (await Store.session()) ?? {}
			await Store.saveSession({ ...session, tokens: bundleFrom(json, current.deviceId) })
			lastRefresh = REFRESH.ok
			return true
		} catch (error) {
			if (error instanceof ApiError && (error.isUnauthorized || error.isForbidden)) {
				const checkAgain = await tokens()
				if (checkAgain && checkAgain.refreshToken !== current.refreshToken && checkAgain.accessToken) {
					lastRefresh = REFRESH.ok
					return true
				}
				lastRefresh = REFRESH.revoked
				await Store.clearSession()
			} else {
				lastRefresh = REFRESH.offline
			}
			return false
		} finally {
			refreshing = null
		}
	})()
	return refreshing
}

export const Api = {
	lastRefreshOutcome: () => lastRefresh,
	baseUrl,

	health: () => request('GET', '/api/health', { authenticated: false }),
	version: () => request('GET', '/api/version', { authenticated: false }),
	serviceStatus: () => request('GET', '/api/service/status', { authenticated: false }),

	/** Username OR email, exactly like the app: both fields are sent so an
	 *  older control server still understands the call. */
	async login(identifier, password) {
		const json = await request('POST', '/api/auth/login', {
			body: { identifier, username: identifier, password },
			authenticated: false,
		})
		await Store.saveSession({ user: json.user ?? null, subscription: json.subscription ?? null, tokens: bundleFrom(json, null) })
		return json
	},

	async restore() {
		const bundle = await tokens()
		if (!bundle?.refreshToken) return REFRESH.revoked
		if (await tryRefresh()) return REFRESH.ok
		return lastRefresh === REFRESH.offline ? REFRESH.offline : REFRESH.revoked
	},

	async logout() {
		const bundle = await tokens()
		try {
			if (bundle?.refreshToken) {
				await request('POST', '/api/auth/logout', { body: { refreshToken: bundle.refreshToken } })
			}
		} catch {
			// Signing out locally must succeed even when the server call fails.
		} finally {
			await Store.clearSession()
		}
	},

	me: () => request('GET', '/api/auth/me'),

	/*
	 * Sign in by link: the same device-authorization flow the desktop client
	 * uses. POST /api/auth/link/start returns a user code, the user confirms it
	 * on the website, POST /api/auth/link/poll hands back real tokens.
	 *
	 * This is what replaces the old storage bridge. The extension no longer
	 * reads a token the website happened to leave behind - it asks for one that
	 * was minted for it. `pollSecret` never leaves this worker, so the code in
	 * the URL is worthless on its own.
	 *
	 * Unauthenticated on purpose: we have no session yet, that is the point.
	 */
	linkStart({ client = 'extension', deviceName } = {}) {
		const name = String(deviceName ?? '').trim().slice(0, 64)
		return request('POST', '/api/auth/link/start', {
			body: name ? { client, deviceName: name } : { client },
			authenticated: false,
			allowRefresh: false,
		})
	},

	linkPoll({ requestId, pollSecret }) {
		return request('POST', '/api/auth/link/poll', {
			body: { requestId, pollSecret },
			authenticated: false,
			allowRefresh: false,
		})
	},

	/** Stores the tokens an approved link handed back, as a normal session. */
	async saveLinkedSession(json) {
		await Store.saveSession({
			user: json.user ?? null,
			subscription: json.subscription ?? null,
			tokens: bundleFrom(json, null),
		})
		lastRefresh = REFRESH.ok
		return json.user ?? null
	},

	async nodes() {
		const json = await request('GET', '/api/nodes')
		return Array.isArray(json.nodes) ? json.nodes : []
	},

	/** Registers the browser as a device and upgrades to device-scoped tokens,
	 *  which /api/vpn/* requires. Only the public key is sent. */
	async registerDevice({ deviceName, publicKey, platform }) {
		const json = await request('POST', '/api/devices/register', {
			body: { deviceName, publicKey, platform },
		})
		const session = (await Store.session()) ?? {}
		await Store.saveSession({ ...session, tokens: bundleFrom(json, json.device?.id ?? null) })
		return json
	},

	devices: () => request('GET', '/api/devices'),
	activeMap: () => request('GET', '/api/user/active-map'),
	/** Статистика использования: тот же эндпоинт, что у ПК и телефона. */
	analytics: (period) => request('GET', `/api/user/analytics?period=${encodeURIComponent(String(period || 'day'))}`),
	reportMapCountry: (countryCode) => request('POST', '/api/user/map-origin', { body: { countryCode } }),
	revokeDevice: (id) => request('DELETE', `/api/devices/${encodeURIComponent(String(id))}`),

	connect: (nodeId) => request('POST', '/api/vpn/connect', { body: nodeId ? { nodeId } : {} }),
	disconnect: (payload) =>
		request('POST', '/api/vpn/disconnect', {
			body: payload && typeof payload === 'object' ? payload : payload ? { sessionId: payload } : {},
		}),
	reportStats: ({ downloadBytes, uploadBytes, sessionId, transport = 'browser' } = {}) =>
		request('POST', '/api/vpn/stats', {
			body: { downloadBytes, uploadBytes, sessionId, transport },
		}),
	status: () => request('GET', '/api/vpn/status'),

	/** Public IP as seen from the current path. While the gateway is up this must
	 *  report the node's address - that is the proof traffic really egresses there. */
	async probeExitIp() {
		try {
			const json = await request('GET', '', {
				authenticated: false,
				absoluteUrl: 'https://api.ipify.org?format=json',
			})
			return typeof json.ip === 'string' ? json.ip : null
		} catch {
			return null
		}
	},
}
