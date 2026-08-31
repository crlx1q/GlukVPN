/*
 * GlukVPN browser service worker.
 *
 * Lifecycle, in the same order the phone app does it:
 *   1. sign in                       POST /api/auth/login          (username or email)
 *   2. register this browser         POST /api/devices/register    (platform: chrome | edge | ...)
 *   3. ask for a tunnel              POST /api/vpn/connect         (session + node + tunnel config)
 *   4. point the browser at the node chrome.proxy + PAC
 *   5. poll                          GET  /api/vpn/status          (peerReady, traffic, subscription)
 *
 * Step 2 is what makes the device show up in the devices table as a browser, so
 * the admin panel and Settings > Devices list "Chrome 141 - Windows / chrome"
 * next to the Android phone, and revoking it from there kills this session too.
 */

import { Api, ApiError, REFRESH } from './lib/api.js'
import { detectBrowser } from './lib/browser.js'
import { ProxyEngine } from './lib/proxy.js'
import { DEFAULT_SETTINGS, Store } from './lib/store.js'
import { generateKeyPair, isValidKey, publicKeyFor } from './lib/x25519.js'

const POLL_ALARM = 'gluk-poll'
const PHASE = {
	signedOut: 'signedOut',
	idle: 'idle',
	connecting: 'connecting',
	connected: 'connected',
	disconnecting: 'disconnecting',
	error: 'error',
}

// ---------------------------------------------------------------- state ----

async function patchRuntime(patch) {
	const current = (await Store.runtime()) ?? {}
	const next = { ...current, ...patch, updatedAt: Date.now() }
	await Store.saveRuntime(next)
	broadcast(next)
	return next
}

function broadcast(runtime) {
	// The popup may be closed; a missing receiver is not an error worth logging.
	try {
		chrome.runtime.sendMessage({ type: 'runtime', payload: runtime }).catch(() => {})
	} catch {}
}

const HANDLER_TIMEOUT_MS = 40000

/*
 * Guarantees a promise settles.
 *
 * Without this, one hung fetch left runtime.phase on 'connecting' forever: the
 * popup showed a spinner, the power button looked dead, and nothing ever told
 * the user why. Now every path lands on a terminal phase.
 */
function withTimeout(promise, ms, label) {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			const error = new Error(`Timed out: ${label ?? 'request'}`)
			error.code = 'timeout'
			reject(error)
		}, ms)
		Promise.resolve(promise).then(
			(value) => {
				clearTimeout(timer)
				resolve(value)
			},
			(error) => {
				clearTimeout(timer)
				reject(error)
			},
		)
	})
}

const ICONS = {
	on: { 16: 'icons/on/icon16.png', 32: 'icons/on/icon32.png', 48: 'icons/on/icon48.png', 128: 'icons/on/icon128.png' },
	off: { 16: 'icons/off/icon16.png', 32: 'icons/off/icon32.png', 48: 'icons/off/icon48.png', 128: 'icons/off/icon128.png' },
}

async function setBadge(phase) {
	const map = {
		[PHASE.connected]: { text: 'ON', color: '#4fd88c' },
		[PHASE.connecting]: { text: '...', color: '#c4b5fd' },
		[PHASE.error]: { text: '!', color: '#ff6b6b' },
	}
	const badge = map[phase] ?? { text: '', color: '#8b5cf6' }
	// Same rule as the popup logo: the mark stays grey until traffic is really
	// routed, so the toolbar alone tells you whether you are protected.
	try {
		await chrome.action.setIcon({ path: phase === PHASE.connected ? ICONS.on : ICONS.off })
	} catch {}
	try {
		await chrome.action.setBadgeText({ text: badge.text })
		await chrome.action.setBadgeBackgroundColor({ color: badge.color })
	} catch {}
}

async function fail(message, code = 'error') {
	await patchRuntime({ phase: PHASE.error, error: { message, code } })
	await setBadge(PHASE.error)
	return { ok: false, error: message, code }
}

/**
 * MV3 tears this worker down whenever it feels like it. A stored `connecting`
 * phase that survives the teardown is a lie - nothing is in flight any more -
 * and the popup used to inherit it as a spinner that could never finish.
 * Runs on every worker start, so a half-finished attempt always resolves into
 * something the user can act on.
 */
async function repairStalePhase() {
	try {
		const runtime = await Store.runtime()
		const phase = runtime?.phase
		if (phase === PHASE.connecting || phase === PHASE.disconnecting) {
			await patchRuntime({
				phase: PHASE.error,
				error: { code: 'interrupted', message: 'The last connection attempt was interrupted. Try again.' },
			})
			await setBadge(PHASE.error)
			return
		}
		if (phase === PHASE.connected) {
			// Reporting "connected" while the browser is not actually routed
			// through our gateway is worse than reporting nothing.
			const controlling = await ProxyEngine.isControlling()
			if (!controlling) {
				await patchRuntime({ phase: PHASE.idle, session: null, gateway: null, stats: null })
				await setBadge(PHASE.idle)
			}
		}
	} catch {}
}

const AUTOCONNECT_ALARM = 'gluk-autoconnect'
const AUTOCONNECT_MAX_ATTEMPTS = 8
const AUTOCONNECT_QUICK_RETRIES = 4
const AUTOCONNECT_QUICK_DELAY_MS = 2500

/**
 * Autostart has to survive a browser that boots faster than its own network.
 * The pending intent is stored in runtime state so it also survives the worker
 * being torn down, and an alarm retries it with backoff.
 */
async function scheduleAutoConnect(attempt) {
	const next = Math.min(Math.max(1, attempt), AUTOCONNECT_MAX_ATTEMPTS)
	await patchRuntime({ autoConnect: { pending: true, attempt: next } })
	// Chrome clamps alarms to roughly 30 seconds, so this is the honest floor.
	const delayInMinutes = Math.min(0.5 * 2 ** (next - 1), 10)
	try {
		await chrome.alarms.create(AUTOCONNECT_ALARM, { delayInMinutes })
	} catch {}
}

async function clearAutoConnect() {
	await patchRuntime({ autoConnect: null })
	try {
		await chrome.alarms.clear(AUTOCONNECT_ALARM)
	} catch {}
}

async function runAutoConnect() {
	const runtime = await Store.runtime()
	const pending = runtime?.autoConnect
	if (!pending?.pending) return

	const session = await Store.session()
	if (!session?.tokens) return clearAutoConnect()
	if (runtime?.phase === PHASE.connected || runtime?.phase === PHASE.connecting) {
		return clearAutoConnect()
	}

	const attempt = Number(pending.attempt ?? 1)
	if (typeof navigator !== 'undefined' && navigator.onLine === false) {
		if (attempt >= AUTOCONNECT_MAX_ATTEMPTS) return clearAutoConnect()
		return scheduleAutoConnect(attempt + 1)
	}

	const outcome = await Api.restore()
	if (outcome === REFRESH.revoked) return clearAutoConnect()
	if (outcome === REFRESH.offline) {
		if (attempt >= AUTOCONNECT_MAX_ATTEMPTS) return clearAutoConnect()
		return scheduleAutoConnect(attempt + 1)
	}

	await clearAutoConnect()
	const settings = await Store.settings()
	try {
		await withTimeout(connect({ nodeId: settings.preferredNodeId }), HANDLER_TIMEOUT_MS, 'autoconnect')
	} catch (error) {
		await fail(error?.message ?? 'Could not connect on startup.', 'autoconnect_failed')
	}
}

// --------------------------------------------------------------- helpers ---

function apiHostsFrom(settings) {
	return Object.values(settings.apiBase ?? {})
		.map((url) => {
			try {
				return new URL(url).hostname
			} catch {
				return null
			}
		})
		.filter(Boolean)
}

/**
 * The browser's own WireGuard identity, created once and kept locally.
 *
 * `rotate` mints a fresh pair. That path matters: once this browser's device
 * has been revoked, its public key is permanently unusable, and without a way
 * to issue a new one the account could never register again.
 */
async function ensureKeys(options) {
	const rotate = options?.rotate === true
	const stored = await Store.device()
	if (!rotate && stored?.privateKey && isValidKey(stored.privateKey)) {
		// Recompute the public key so a corrupted record cannot silently register
		// a key we cannot prove we own.
		const publicKey = publicKeyFor(stored.privateKey)
		if (publicKey !== stored.publicKey) await Store.saveDevice({ ...stored, publicKey })
		return { ...stored, publicKey }
	}
	const pair = generateKeyPair()
	const identity = { ...pair, createdAt: new Date().toISOString() }
	await Store.saveDevice(identity)
	return identity
}

/**
 * /api/vpn/* only accepts device-scoped tokens, which register hands out.
 *
 * If the server refuses our key as "already registered" the account is locked
 * out of its own browser: the key is stored locally forever, so every retry
 * sends the same rejected key. Rotating once and retrying is what turns that
 * dead end back into a normal registration.
 */
async function ensureDeviceScope() {
	const session = await Store.session()
	if (!session?.tokens) throw new ApiError({ statusCode: 401, code: 'signed_out', message: 'Sign in first.' })

	const info = detectBrowser()
	let lastError = null

	for (let attempt = 0; attempt < 2; attempt += 1) {
		const identity = await ensureKeys({ rotate: attempt > 0 })
		try {
			const registration = await Api.registerDevice({
				deviceName: info.deviceName.slice(0, 64),
				publicKey: identity.publicKey,
				platform: info.platform.slice(0, 32),
			})
			const device = {
				...identity,
				id: registration.device?.id ?? null,
				deviceName: registration.device?.deviceName ?? info.deviceName,
				platform: registration.device?.platform ?? info.platform,
				browser: info.browser,
				os: info.os,
				maxDevices: registration.maxDevices ?? null,
			}
			await Store.saveDevice(device)
			return device
		} catch (error) {
			lastError = error
			const text = String(error?.message ?? '').toLowerCase()
			const keyRejected = /already registered|public key is already/.test(text)
			if (!keyRejected || attempt > 0) throw error
		}
	}

	throw lastError ?? new ApiError({ statusCode: 409, code: 'device_conflict', message: 'Could not register this browser.' })
}

function pickNode(nodes, preferredId) {
	const usable = nodes.filter((node) => node.connectable !== false && node.online !== false)
	const pool = usable.length ? usable : nodes
	if (preferredId) {
		const match = pool.find((node) => node.id === preferredId)
		if (match) return match
	}
	return [...pool].sort((a, b) => (a.loadPercent ?? 100) - (b.loadPercent ?? 100))[0] ?? null
}

function gatewayFor(settings, node) {
	return {
		// An explicit host wins: the TLS certificate is issued for a name, and the
		// node record carries a bare IP.
		host: settings.gateway.host?.trim() || node?.browserProxyHost || node?.host || '',
		port: Number(node?.browserProxyPort ?? settings.gateway.port) || 8443,
		scheme: settings.gateway.scheme || 'https',
	}
}

function gatewayUrl(gateway, path) {
	const scheme = gateway.scheme === 'http' ? 'http' : 'https'
	return `${scheme}://${gateway.host}:${gateway.port}${path}`
}

/** Is the gateway actually listening?
 *
 *  Called before chrome.proxy is touched, so this request always goes out
 *  directly. Reporting CONNECTED while the gateway is missing is the worst
 *  possible outcome: with the kill switch on the PAC file has no DIRECT
 *  fallback, so the whole browser loses the internet while the UI claims
 *  everything is fine. */
async function probeGateway(gateway) {
	if (!gateway?.host) return { ok: false, code: 'no_gateway', error: 'No gateway host configured.' }
	const started = Date.now()
	try {
		const response = await fetch(gatewayUrl(gateway, '/__gluk/ping'), {
			cache: 'no-store',
			credentials: 'omit',
			signal: AbortSignal.timeout(7000),
		})
		// 401/407 still proves something is listening and speaking our protocol.
		if (response.status >= 500) {
			return { ok: false, code: 'gateway_error', error: `The gateway answered ${response.status}.` }
		}
		return { ok: true, ping: Date.now() - started }
	} catch {
		return {
			ok: false,
			code: 'gateway_unreachable',
			error: `No answer from the browser gateway at ${gateway.host}:${gateway.port} (${gateway.scheme}). Start glukvpn-browser-proxy on the node and open that port, then try again.`,
		}
	}
}

/** Byte counters and RTT straight from the gateway. Best effort: the tunnel is
 *  not broken just because the stats endpoint is missing on an older gateway. */
async function gatewayStats(gateway, credentials) {
	if (!credentials) return null
	try {
		const started = performance.now()
		const response = await fetch(gatewayUrl(gateway, '/__gluk/stats'), {
			headers: { authorization: `Basic ${btoa(`${credentials.username}:${credentials.password}`)}` },
			cache: 'no-store',
			credentials: 'omit',
		})
		const rtt = performance.now() - started
		if (!response.ok) return { ping: Math.round(rtt) }
		const json = await response.json()
		return {
			ping: Math.round(rtt),
			bytesRx: Number(json.bytesRx ?? 0),
			bytesTx: Number(json.bytesTx ?? 0),
			connections: Number(json.connections ?? 0),
			gatewayVersion: json.version ?? null,
		}
	} catch {
		return null
	}
}

// -------------------------------------------------------------- commands ---

async function login({ identifier, password }) {
	try {
		const result = await Api.login(String(identifier ?? '').trim(), String(password ?? ''))
		await patchRuntime({ phase: PHASE.idle, error: null })
		await setBadge(PHASE.idle)
		const settings = await Store.settings()
		// Registering right away means the browser appears in the devices list the
		// moment you sign in, not only after the first connect.
		try {
			await ensureDeviceScope()
		} catch {}
		if (settings.autoConnect) void connect({})
		return { ok: true, user: result.user ?? null }
	} catch (error) {
		const message = error instanceof ApiError ? error.message : 'Sign-in failed.'
		return { ok: false, error: message, code: error?.code ?? 'login_failed', retryAfterSec: error?.retryAfterSec ?? null }
	}
}

async function logout() {
	await disconnect({ silent: true })
	await Api.logout()
	await Store.clearRuntime()
	await patchRuntime({ phase: PHASE.signedOut, error: null, session: null, node: null, stats: null })
	await setBadge(PHASE.signedOut)
	return { ok: true }
}

async function connect({ nodeId }) {
	// No link, no attempt. Entering the connecting phase here is what made the
	// popup animate a handshake on a machine with no network at all.
	try {
		if (typeof navigator !== 'undefined' && navigator.onLine === false) {
			return fail('This computer is offline. Connect to a network and try again.', 'offline')
		}
	} catch {}
	await patchRuntime({ phase: PHASE.connecting, error: null })
	await setBadge(PHASE.connecting)
	try {
		const settings = await Store.settings()
		const device = await ensureDeviceScope()

		const nodes = await Api.nodes()
		await Store.saveNodes(nodes)
		const target = pickNode(nodes, nodeId ?? settings.preferredNodeId)
		if (!target) return fail('No VPN node is available right now.', 'no_nodes')

		const result = await Api.connect(target.id)
		const node = result.node ?? target
		const gateway = gatewayFor(settings, node)
		if (!gateway.host) {
			return fail('Set the browser gateway host in Settings before connecting.', 'no_gateway')
		}

		const probe = await probeGateway(gateway)
		if (!probe.ok) {
			// Never point the browser at a gateway that is not there, and do not
			// leave a half-open session behind on the control plane.
			try {
				await Api.disconnect(result.session?.id ?? null)
			} catch {}
			return fail(probe.error, probe.code)
		}

		// Basic credentials the gateway checks against the control plane: the
		// device id identifies the row, the access token proves it is really us.
		// The token is short lived and the listener always reads the current one.
		const tokens = (await Store.session())?.tokens
		await ProxyEngine.setCredentials(device.id ?? 'browser', tokens?.accessToken ?? '')

		await ProxyEngine.apply({
			gateway,
			apiHosts: apiHostsFrom(settings),
			bypass: settings.bypass,
			killSwitch: settings.killSwitch,
			siteList: settings.siteList,
			tunnelMode: settings.tunnelMode,
		})

		await patchRuntime({
			phase: PHASE.connected,
			error: null,
			connectedAt: Date.now(),
			gateway,
			node: {
				id: node.id,
				country: node.country,
				countryCode: node.countryCode,
				city: node.city ?? null,
				region: node.region ?? null,
				loadPercent: node.loadPercent ?? null,
			},
			session: {
				id: result.session?.id ?? null,
				status: result.session?.status ?? 'PENDING',
				vpnIp: result.session?.assignedVpnIp ?? result.tunnel?.interfaceAddress ?? null,
				dns: result.tunnel?.dns ?? [],
			},
			stats: { bytesRx: 0, bytesTx: 0, ping: probe.ping ?? null, publicIp: null, gatewayReachable: true },
			gatewayMisses: 0,
		})
		await setBadge(PHASE.connected)
		chrome.alarms.create(POLL_ALARM, { periodInMinutes: 0.5 })
		void poll()
		return { ok: true }
	} catch (error) {
		if (error instanceof ApiError) {
			if (error.isConflict) {
				return fail(
					`${error.message} This account allows a limited number of simultaneous tunnels - disconnect another device first.`,
					'limit',
				)
			}
			if (error.isForbidden) return fail(error.message, 'forbidden')
			if (error.isNetwork) return fail(error.message, 'offline')
			return fail(error.message, error.code)
		}
		return fail('Could not start the tunnel.', 'unknown')
	}
}

async function disconnect({ silent } = {}) {
	if (!silent) await patchRuntime({ phase: PHASE.disconnecting })
	// Clear the proxy first: the disconnect call must not travel through the
	// tunnel it is about to tear down.
	try {
		await ProxyEngine.clear()
	} catch {}
	chrome.alarms.clear(POLL_ALARM)
	try {
		const runtime = await Store.runtime()
		if ((await Store.session())?.tokens) await Api.disconnect(runtime?.session?.id ?? null)
	} catch {}
	const signedIn = Boolean((await Store.session())?.tokens)
	await patchRuntime({
		phase: signedIn ? PHASE.idle : PHASE.signedOut,
		session: null,
		gateway: null,
		connectedAt: null,
		stats: null,
		error: null,
	})
	await setBadge(signedIn ? PHASE.idle : PHASE.signedOut)
	return { ok: true }
}

async function poll() {
	const runtime = await Store.runtime()
	if (runtime?.phase !== PHASE.connected) return
	try {
		const status = await Api.status()
		if (status.connected === false) {
			// The control plane closed the session (revoked device, admin action,
			// subscription lapse). Stop pretending we are up.
			await disconnect({ silent: true })
			await patchRuntime({ error: { message: 'The server closed this session.', code: 'closed' } })
			return
		}
		const gateway = runtime.gateway
		const credentials = await ProxyEngine.credentials()
		const [stats, publicIp] = await Promise.all([
			gateway ? gatewayStats(gateway, credentials) : null,
			runtime.stats?.publicIp ? Promise.resolve(runtime.stats.publicIp) : Api.probeExitIp(),
		])
		await patchRuntime({
			session: {
				...(runtime.session ?? {}),
				status: status.session?.status ?? runtime.session?.status ?? null,
				peerReady: Boolean(status.peerReady),
			},
			subscriptionActive: status.subscriptionActive !== false,
			stats: {
				...(runtime.stats ?? {}),
				// Server counters only move for WireGuard peers; the gateway reports
				// the browser's real bytes, so it wins when present.
				bytesRx: stats?.bytesRx ?? Number(status.session?.bytesRx ?? runtime.stats?.bytesRx ?? 0),
				bytesTx: stats?.bytesTx ?? Number(status.session?.bytesTx ?? runtime.stats?.bytesTx ?? 0),
				ping: stats?.ping ?? runtime.stats?.ping ?? null,
				connections: stats?.connections ?? runtime.stats?.connections ?? 0,
				publicIp: publicIp ?? runtime.stats?.publicIp ?? null,
				gatewayReachable: stats !== null,
			},
			gatewayMisses: stats === null ? (runtime.gatewayMisses ?? 0) + 1 : 0,
		})
		// Two misses in a row (~30s) means the gateway went away. Fail loudly and
		// hand the browser its internet back instead of faking a live tunnel.
		if (stats === null && (runtime.gatewayMisses ?? 0) + 1 >= 2) {
			await disconnect({ silent: true })
			await patchRuntime({
				error: {
					code: 'gateway_unreachable',
					message: 'The browser gateway stopped responding, so the tunnel was closed.',
				},
			})
		}
	} catch (error) {
		if (error instanceof ApiError && (error.isUnauthorized || error.isForbidden)) {
			await disconnect({ silent: true })
			await patchRuntime({ error: { message: error.message, code: 'revoked' } })
		}
		// Anything else (offline, 5xx) is transient: keep the tunnel as it is.
	}
}

async function state() {
	const [settings, session, device, runtime, nodes] = await Promise.all([
		Store.settings(),
		Store.session(),
		Store.device(),
		Store.runtime(),
		Store.nodes(),
	])
	const signedIn = Boolean(session?.tokens?.refreshToken)
	return {
		settings,
		user: session?.user ?? null,
		subscription: session?.subscription ?? null,
		device: device ? { id: device.id, deviceName: device.deviceName, platform: device.platform, browser: device.browser, os: device.os } : null,
		nodes,
		runtime: runtime ?? { phase: signedIn ? PHASE.idle : PHASE.signedOut },
		signedIn,
		browser: detectBrowser(),
	}
}

async function refreshNodes() {
	try {
		const nodes = await Api.nodes()
		await Store.saveNodes(nodes)
		return { ok: true, nodes }
	} catch (error) {
		return { ok: false, error: error?.message ?? 'Could not load servers.', nodes: await Store.nodes() }
	}
}

/** Turns the website's session into ours. See content/site-bridge.js. */
async function adoptSiteSession({ tokens, reason } = {}) {
	const available = tokens && typeof tokens === 'object' ? tokens : {}
	if ((await Store.session())?.tokens?.refreshToken) return { ok: false, already: true }
	if (!Object.keys(available).length) return { ok: false }

	const settings = await Store.settings()
	// A beta refresh token is meaningless on prod, so try the configured channel
	// first, fall back to the other one, then remember which one worked.
	const order = settings.channel === 'prod' ? ['prod', 'beta'] : ['beta', 'prod']
	let lastError = null
	for (const channel of order) {
		if (!available[channel]) continue
		try {
			const adopted = await Api.adoptRefreshToken(channel, available[channel])
			if (channel !== settings.channel) await Store.saveSettings({ channel })
			await patchRuntime({ phase: PHASE.idle, error: null })
			await setBadge(PHASE.idle)
			// Register at once so the browser shows up in the devices table
			// (platform: chrome / edge / ...) without waiting for a connect.
			try {
				await ensureDeviceScope()
			} catch {}
			chrome.runtime.sendMessage({ type: 'signedIn' }).catch(() => {})
			if ((await Store.settings()).autoConnect) void connect({})
			return {
				ok: true,
				channel,
				username: adopted.user?.username ?? null,
				rotated: { channel, refreshToken: adopted.rotatedRefreshToken },
			}
		} catch (error) {
			lastError = error
		}
	}
	return {
		ok: false,
		// A silent poll must not spam the page with toasts.
		error: reason === 'poll' ? null : (lastError?.message ?? 'Could not reuse the website session.'),
	}
}

const HANDLERS = {
	getState: () => state(),
	login,
	logout,
	async connect(payload) {
		try {
			return await withTimeout(connect(payload ?? {}), 40000, 'connect')
		} catch (error) {
			return fail(error?.message ?? 'Could not connect.', error?.code ?? 'connect_failed')
		}
	},
	async disconnect(payload) {
		try {
			return await withTimeout(disconnect(payload ?? {}), 25000, 'disconnect')
		} catch {
			// Tear the tunnel down locally anyway: the off switch must always work.
			try {
				await ProxyEngine.clear()
			} catch {}
			const signedIn = Boolean((await Store.session())?.tokens)
			await patchRuntime({
				phase: signedIn ? PHASE.idle : PHASE.signedOut,
				session: null,
				gateway: null,
				connectedAt: null,
				stats: null,
				error: null,
			})
			await setBadge(signedIn ? PHASE.idle : PHASE.signedOut)
			return { ok: true }
		}
	},
	poll: async () => {
		await poll()
		return { ok: true }
	},
	refreshNodes,
	async saveSettings(payload) {
		const settings = await Store.saveSettings(payload ?? {})
		const runtime = await Store.runtime()
		// Re-apply live so a bypass or kill-switch change takes effect at once.
		if (runtime?.phase === PHASE.connected && runtime.gateway) {
			const gateway = { ...runtime.gateway, ...(payload?.gateway ?? {}) }
			if (settings.gateway.host) gateway.host = settings.gateway.host
			await ProxyEngine.apply({
				gateway,
				apiHosts: apiHostsFrom(settings),
				bypass: settings.bypass,
				killSwitch: settings.killSwitch,
				siteList: settings.siteList,
				tunnelMode: settings.tunnelMode,
			})
			await patchRuntime({ gateway })
		}
		return { ok: true, settings }
	},
	async resetSettings() {
		await chrome.storage.local.set({ settings: DEFAULT_SETTINGS })
		return { ok: true, settings: DEFAULT_SETTINGS }
	},
	async selectNode({ nodeId }) {
		await Store.saveSettings({ preferredNodeId: nodeId ?? null })
		const runtime = await Store.runtime()
		if (runtime?.phase === PHASE.connected) {
			await disconnect({ silent: true })
			return connect({ nodeId })
		}
		return { ok: true }
	},
	async devices() {
		try {
			return { ok: true, ...(await Api.devices()) }
		} catch (error) {
			return { ok: false, error: error?.message ?? 'Could not load devices.' }
		}
	},
	async revokeDevice({ deviceId }) {
		if (!deviceId) return { ok: false, error: 'No device id.' }
		try {
			const own = await Store.device()
			const result = await Api.revokeDevice(deviceId)
			// Revoking this browser also kills the tokens we are holding, so drop the
			// tunnel instead of retrying with credentials the server no longer honours.
			if (own?.id && own.id === deviceId) {
				await ProxyEngine.clear()
				await patchRuntime({ phase: PHASE.signedOut, session: null, gateway: null, stats: null })
				await setBadge(PHASE.signedOut)
			}
			return { ok: true, ...result }
		} catch (error) {
			return { ok: false, error: error?.message ?? 'Could not revoke device.' }
		}
	},
	/** Opens the website so the user signs in there, once, on the origin that
	 *  owns the account. content/site-bridge.js does the rest. */
	async linkWithSite() {
		const settings = await Store.settings()
		const base = String(settings.siteBase || 'https://vpn.gluk.tech').replace(/\/+$/, '')
		try {
			await chrome.tabs.create({ url: `${base}/login/` })
			return { ok: true }
		} catch (error) {
			return { ok: false, error: error?.message ?? 'Could not open the website.' }
		}
	},

	siteSession: (payload) => adoptSiteSession(payload),

	/** Settings > Test gateway. Answers the one question that matters before
	 *  connecting: is the proxy on the node actually up? */
	async testGateway(payload) {
		const settings = await Store.settings()
		const gateway = {
			host: String(payload?.host || '').trim() || settings.gateway.host,
			port: Number(payload?.port) || settings.gateway.port,
			scheme: payload?.scheme || settings.gateway.scheme,
		}
		if (!gateway.host) return { ok: false, error: 'Enter a gateway host first.' }
		const probe = await probeGateway(gateway)
		if (!probe.ok) return { ok: false, error: probe.error }
		const stats = await gatewayStats(gateway, await ProxyEngine.credentials())
		return { ok: true, ping: probe.ping, version: stats?.gatewayVersion ?? null }
	},
}

// -------------------------------------------------------------- listeners --

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
	const handler = HANDLERS[message?.type]
	if (!handler) return false
	// One envelope for every reply, and every handler is time-boxed, so the popup
	// can always tell "this failed" apart from "still waiting".
	withTimeout(Promise.resolve(handler(message.payload ?? {})), HANDLER_TIMEOUT_MS, message.type)
		.then((data) => sendResponse({ ok: true, data }))
		.catch((error) =>
			sendResponse({
				ok: false,
				error: error?.message ?? 'Unexpected error',
				code: error?.code ?? null,
			}),
		)
	return true
})

/*
 * The gateway answers every new connection with 407 until it sees credentials.
 * MV3 allows exactly this one blocking webRequest hook (webRequestAuthProvider),
 * which is why proxy auth works without the deprecated blocking API.
 */
chrome.webRequest.onAuthRequired.addListener(
	(details, callback) => {
		if (!details.isProxy) {
			callback({})
			return
		}
		ProxyEngine.credentials()
			.then((credentials) => {
				if (!credentials?.password) {
					callback({ cancel: true })
					return
				}
				callback({ authCredentials: { username: credentials.username, password: credentials.password } })
			})
			.catch(() => callback({ cancel: true }))
	},
	{ urls: ['<all_urls>'] },
	['asyncBlocking'],
)

chrome.proxy.onProxyError.addListener((details) => {
	void patchRuntime({
		error: {
			code: 'gateway',
			message: details?.fatal
				? 'The browser gateway is unreachable. With the kill switch on, traffic is blocked instead of leaking.'
				: details?.error ?? 'Gateway warning',
		},
	})
})

chrome.alarms.onAlarm.addListener((alarm) => {
	if (alarm.name === POLL_ALARM) void poll()
	if (alarm.name === AUTOCONNECT_ALARM) void runAutoConnect()
})

async function bootstrap() {
	// Read the intent before repairing: repairStalePhase can reset a stale
	// "connected" to idle, and that must not erase the reconnect intent.
	const previous = await Store.runtime()
	const wasConnected = previous?.phase === PHASE.connected
	await repairStalePhase()
	const settings = await Store.settings()
	let outcome = await Api.restore()

	// The network is usually not up yet when the browser starts, and that is
	// precisely why "start with the browser" never fired: restore came back
	// offline and this function gave up right here. Retry briefly while the
	// worker is still alive, then hand the job over to an alarm.
	if (outcome === REFRESH.offline && (wasConnected || settings.autoConnect)) {
		for (let attempt = 0; attempt < AUTOCONNECT_QUICK_RETRIES && outcome === REFRESH.offline; attempt += 1) {
			await new Promise((resolve) => setTimeout(resolve, AUTOCONNECT_QUICK_DELAY_MS))
			outcome = await Api.restore()
		}
	}

	if (outcome === REFRESH.revoked) {
		await ProxyEngine.clear()
		await patchRuntime({ phase: PHASE.signedOut, session: null, gateway: null, stats: null })
		await setBadge(PHASE.signedOut)
		return
	}
	if (outcome === REFRESH.offline) {
		// Starting the browser on a train must not sign anybody out.
		await patchRuntime({ error: { code: 'offline', message: 'Working offline - the control plane is unreachable.' } })
		if (wasConnected || settings.autoConnect) await scheduleAutoConnect(1)
		return
	}
	if (wasConnected || settings.autoConnect) {
		// A failed autostart must still end on a phase the popup can render.
		try {
			await withTimeout(connect({ nodeId: settings.preferredNodeId }), 40000, 'autoconnect')
		} catch (error) {
			await fail(error?.message ?? 'Could not connect on startup.', 'autoconnect_failed')
		}
	} else {
		await patchRuntime({ phase: PHASE.idle })
		await setBadge(PHASE.idle)
	}
}

// Every worker wake, not just browser start: this is where an interrupted
// attempt gets turned back into a state the popup can render honestly.
void repairStalePhase()

chrome.runtime.onStartup.addListener(() => void bootstrap())
chrome.runtime.onInstalled.addListener(async (details) => {
	await patchRuntime({ phase: PHASE.signedOut })
	await setBadge(PHASE.signedOut)
	if (details.reason === 'install') {
		const settings = await Store.settings()
		const base = String(settings.siteBase || 'https://vpn.gluk.tech').replace(/\/+$/, '')
		// Sign in on the website once; the bridge hands the session over to us.
		await chrome.tabs.create({ url: `${base}/login/` })
	} else {
		void bootstrap()
	}
})
