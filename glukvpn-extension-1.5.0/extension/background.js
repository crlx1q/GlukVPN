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
import { pickNode as chooseNode } from './lib/pick.js'
import { DEFAULT_SETTINGS, Store } from './lib/store.js'
import { generateKeyPair, isValidKey, publicKeyFor } from './lib/x25519.js'
import { Telemetry } from './lib/telemetry.js'

// ------------------------------------------------------------ bug reports ----
//
// This is an MV3 service worker: there is no `window` here, so the two global
// hooks live on `self`. Anything that escapes a handler - a rejected promise
// from a poll, a throw inside an alarm - now lands in the control server's bug
// log together with the phase it happened in, instead of dying quietly in a
// worker nobody has devtools open on.
self.addEventListener('unhandledrejection', (event) => {
	Telemetry.report(event?.reason, 'background:unhandledrejection')
})

self.addEventListener('error', (event) => {
	Telemetry.report(event?.error ?? event?.message, 'background:error')
})

const POLL_ALARM = 'gluk-poll'
const MAINTENANCE_ALARM = 'gluk-maintenance'
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

function safeError(error, fallbackCode = 'error') {
	const source = error instanceof ApiError ? error : null
	const details = source?.details && typeof source.details === 'object' ? source.details : null
	const safeDevices = Array.isArray(details?.devices)
		? details.devices.slice(0, 20).map((device) => ({
			id: device?.id ?? device?.deviceId ?? null,
			deviceName: device?.deviceName ?? device?.name ?? null,
			platform: device?.platform ?? null,
			lastSeen: device?.lastSeen ?? null,
			isCurrent: device?.isCurrent === true,
			status: device?.status ?? null,
			connected: device?.connected === true,
			connectedNode: device?.connectedNode ? {
				id: device.connectedNode.id ?? null,
				name: device.connectedNode.name ?? null,
				country: device.connectedNode.country ?? null,
				countryCode: device.connectedNode.countryCode ?? null,
				city: device.connectedNode.city ?? null,
			} : null,
		}))
		: undefined
	const safeDetails = details ? {
		maxDevices: Number(details.maxDevices) || undefined,
		activeDevices: Number(details.activeDevices) || undefined,
		retryAfterSec: Number(details.retryAfterSec) || undefined,
		nodeId: details.nodeId == null ? undefined : String(details.nodeId),
		devices: safeDevices,
	} : null
	return {
		message: source?.message || String(error?.message ?? error ?? 'Unexpected error'),
		code: source?.code || String(error?.code ?? fallbackCode),
		status: source?.statusCode || 0,
		retryAfterSec: source?.retryAfterSec ?? safeDetails?.retryAfterSec ?? null,
		details: safeDetails,
	}
}

async function fail(message, code = 'error', meta = {}) {
	const error = { message, code, status: meta.status ?? 0, retryAfterSec: meta.retryAfterSec ?? null, details: meta.details ?? null }
	await patchRuntime({ phase: PHASE.error, error })
	await setBadge(PHASE.error)
	return { ok: false, error: message, code, ...error }
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

const LINK_ALARM = 'gluk-link'
// Chrome clamps alarms to ~30 seconds, so the alarm alone would make approval
// feel broken. It is the safety net; the fast loop below is what the user sees.
const LINK_FAST_POLL_MS = 2000
const LINK_FAST_WINDOW_MS = 25000

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
		await withTimeout(connect({ nodeId: settings.preferredNodeId, userInitiated: false }), HANDLER_TIMEOUT_MS, 'autoconnect')
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

/*
 * Which node to connect to.
 *
 * The ranking itself lives in lib/pick.js, shared with the popup and ported
 * from the Dart selector, so the browser, Windows and Android all answer the
 * same way: latency first, then current load, then spare capacity. Sorting by
 * load alone - what this used to do - sent everyone to an idle node on the
 * other side of the planet.
 */
function pickNode(nodes, preferredId) {
	const list = Array.isArray(nodes) ? nodes : []
	const chosen = chooseNode(list, preferredId)
	if (chosen.node) return chosen.node
	// Nothing scored as usable: a stale heartbeat, or a one-node fleet that just
	// went quiet. Trying it anyway beats refusing to connect at all.
	return list[0] ?? null
}

/*
 * Which proxy listener on the node this browser should use.
 *
 * PROD and BETA are two separate listeners on the same machine: 8443 is wired
 * to the prod control plane (127.0.0.1:8081), 8444 to beta (127.0.0.1:8082).
 * Crossing them is not a soft failure - the gateway checks our credentials
 * against the other database, rejects them, and answers 407 forever while the
 * popup shows a healthy tunnel.
 *
 * So the channel decides the port, and a stale 8443 saved in settings from
 * before the split can no longer follow the user into beta. A genuinely custom
 * port (a private build on 9443) is still honoured, because it cannot belong
 * to the wrong channel.
 */
function gatewayFor(settings, node) {
	const paired = (value) => value === 8443 || value === 8444
	const channelPort = settings.channel === 'beta' ? 8444 : 8443
	const advertised = Number(node?.browserProxyPort) || 0
	const saved = Number(settings.gateway?.port) || 0
	let port = channelPort
	if (advertised && !paired(advertised)) port = advertised
	else if (saved && !paired(saved)) port = saved
	return {
		// An explicit host wins: the TLS certificate is issued for a name
		// (de-01.gluk.tech), and the node record carries a bare IP.
		host: settings.gateway.host?.trim() || node?.browserProxyHost || node?.host || '',
		port,
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
		// Keep the account session when registration hits its device cap. The
		// account-scoped token can still list/revoke devices, then registration
		// resumes without another password or a needless key rotation.
		try {
			await ensureDeviceScope()
		} catch (error) {
			const serialized = safeError(error, 'device_registration_failed')
			await patchRuntime({ phase: PHASE.idle, error: serialized })
			return { ok: true, user: result.user ?? null, registrationPending: true, error: serialized }
		}
		if (settings.autoConnect) void connect({ userInitiated: false })
		return { ok: true, user: result.user ?? null }
	} catch (error) {
		const serialized = safeError(error, 'login_failed')
		return { ok: false, error: serialized.message, ...serialized }
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

async function connect({ nodeId, userInitiated = true } = {}) {
	// Persist only the user's requested destination. Maintenance recovery can
	// safely resume this exact node after an MV3 restart; a manual disconnect
	// clears it and an automatic startup attempt never creates a new intent.
	const settingsAtRequest = await Store.settings()
	const previousIntent = (await Store.runtime())?.connectIntent
	const connectIntent = userInitiated
		? { requested: true, nodeId: nodeId ?? settingsAtRequest.preferredNodeId ?? null, channel: settingsAtRequest.channel, requestedAt: Date.now() }
		: previousIntent
	if (connectIntent) await patchRuntime({ connectIntent })
	// No link, no attempt. Entering the connecting phase here is what made the
	// popup animate a handshake on a machine with no network at all.
	try {
		if (typeof navigator !== 'undefined' && navigator.onLine === false) {
			return fail('This computer is offline. Connect to a network and try again.', 'offline')
		}
	} catch {}
	// A fresh attempt starts with fresh numbers. Leaving the previous session's
	// stats in place let the popup show the old exit IP as if it were still
	// true while a new tunnel was being dialled (browser restart with a tunnel
	// that had been up, or a connect issued on top of a live one). Only the old
	// session id is kept, so a failed attempt can still close it on the server.
	const previous = await Store.runtime()
	await patchRuntime({
		phase: PHASE.connecting,
		error: null,
		connectedAt: null,
		session: previous?.session?.id ? { id: previous.session.id } : null,
		stats: null,
	})
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
			tunnelIncognito: settings.tunnelIncognito,
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
			const serialized = safeError(error, 'connect_failed')
			if (error.code === 'maintenance' || error.statusCode === 503 && /maintenance/i.test(error.message)) {
				await enterMaintenance(serialized)
				return { ok: false, error: serialized.message, ...serialized }
			}
			// Only the explicit registration code opens the device-slot manager.
			// Other 409s (busy tunnel, stale session, key conflict) retain their own
			// actionable code and message.
			if (error.code === 'device_limit_reached') {
				await patchRuntime({ phase: PHASE.error, error: serialized, connectIntent })
				await setBadge(PHASE.error)
				return { ok: false, error: serialized.message, ...serialized }
			}
			if (error.isForbidden) return fail(error.message, error.code || 'forbidden', serialized)
			if (error.isNetwork) return fail(error.message, 'offline', serialized)
			return fail(error.message, error.code, serialized)
		}
		return fail('Could not start the tunnel.', 'unknown')
	}
}

async function disconnect({ silent, preserveIntent = false } = {}) {
	if (!silent) await patchRuntime({ phase: PHASE.disconnecting, connectIntent: null, maintenance: null })
	// Clear the proxy first: the disconnect call must not travel through the
	// tunnel it is about to tear down.
	try {
		await ProxyEngine.clear()
	} catch {}
	chrome.alarms.clear(POLL_ALARM)
	try {
		const runtime = await Store.runtime()
		if ((await Store.session())?.tokens) {
			await Api.disconnect({
				sessionId: runtime?.session?.id ?? undefined,
				downloadBytes: runtime?.stats?.bytesRx ?? 0,
				uploadBytes: runtime?.stats?.bytesTx ?? 0,
			})
		}
	} catch {}
	const signedIn = Boolean((await Store.session())?.tokens)
	const after = await Store.runtime()
	await patchRuntime({
		phase: signedIn ? PHASE.idle : PHASE.signedOut,
		session: null,
		gateway: null,
		connectedAt: null,
		stats: null,
		error: null,
		connectIntent: preserveIntent ? after?.connectIntent ?? null : null,
		maintenance: preserveIntent ? after?.maintenance ?? null : null,
	})
	await setBadge(signedIn ? PHASE.idle : PHASE.signedOut)
	return { ok: true }
}

async function enterMaintenance(error, service) {
	const runtime = await Store.runtime()
	const settings = await Store.settings()
	const intent = runtime?.connectIntent ?? (runtime?.phase === PHASE.connected ? {
		requested: true,
		nodeId: runtime?.node?.id ?? settings.preferredNodeId ?? null,
		channel: settings.channel,
		requestedAt: Date.now(),
	} : null)
	try { await ProxyEngine.clear() } catch {}
	try { await chrome.alarms.clear(POLL_ALARM) } catch {}
	const retryAfterSec = Number(service?.retryAfterSec ?? error?.retryAfterSec ?? error?.details?.retryAfterSec) || 30
	await patchRuntime({
		phase: PHASE.idle,
		session: null,
		gateway: null,
		stats: null,
		connectedAt: null,
		connectIntent: intent,
		maintenance: { active: true, retryAfterSec, nodeId: error?.details?.nodeId ?? runtime?.node?.id ?? null },
		service: { ...(runtime?.service ?? {}), ...(service ?? {}), maintenance: true, retryAfterSec },
		error: { message: error?.message || 'GlukVPN is undergoing maintenance.', code: 'maintenance', status: 503, retryAfterSec, details: error?.details ?? null },
	})
	await setBadge(PHASE.idle)
	try { await chrome.alarms.create(MAINTENANCE_ALARM, { delayInMinutes: Math.max(0.5, retryAfterSec / 60) }) } catch {}
}

async function checkMaintenance() {
	const runtime = await Store.runtime()
	try {
		const service = await Api.serviceStatus()
		await patchRuntime({ service })
		if (service?.maintenance) {
			if (runtime?.phase === PHASE.connected || runtime?.connectIntent?.requested) {
				await enterMaintenance({ code: 'maintenance', message: 'GlukVPN is undergoing maintenance.', retryAfterSec: service.retryAfterSec }, service)
			}
			return { ok: true, service }
		}
		try { await chrome.alarms.clear(MAINTENANCE_ALARM) } catch {}
		await patchRuntime({ maintenance: null, error: runtime?.error?.code === 'maintenance' ? null : runtime?.error })
		const settings = await Store.settings()
		const intent = runtime?.connectIntent
		if (intent?.requested && intent.channel === settings.channel && runtime?.phase !== PHASE.connected && runtime?.phase !== PHASE.connecting && (await Store.session())?.tokens) {
			void connect({ nodeId: intent.nodeId, userInitiated: false })
		}
		return { ok: true, service }
	} catch (error) {
		if (runtime?.maintenance?.active) {
			const retry = Number(runtime.maintenance.retryAfterSec) || 30
			try { await chrome.alarms.create(MAINTENANCE_ALARM, { delayInMinutes: Math.max(0.5, retry / 60) }) } catch {}
		}
		const serialized = safeError(error, 'service_status_failed')
		return { ok: false, error: serialized.message, ...serialized }
	}
}

async function poll() {
	const runtime = await Store.runtime()
	if (runtime?.phase !== PHASE.connected) return
	try {
		const status = await Api.status()
		if (status?.service) await patchRuntime({ service: status.service })
		if (status?.service?.maintenance || status?.nodeMaintenance || status?.lastClosedReason === 'maintenance') {
			await enterMaintenance({
				code: 'maintenance',
				message: status?.nodeMaintenance ? 'The selected VPN server is under maintenance.' : 'GlukVPN is undergoing maintenance.',
				retryAfterSec: status?.service?.retryAfterSec,
				details: { nodeId: runtime?.node?.id, retryAfterSec: status?.service?.retryAfterSec },
			}, status.service)
			return
		}
		if (status.connected === false) {
			// The control plane closed the session (revoked device, admin action,
			// subscription lapse). Stop pretending we are up.
			await disconnect({ silent: true })
			await patchRuntime({ error: { message: 'The server closed this session.', code: 'closed' } })
			return
		}
		const gateway = runtime.gateway
		const session = await Store.session()
		const device = await Store.device()
		const token = session?.tokens?.accessToken
		const credentials = token
			? { username: device?.id ?? 'browser', password: token }
			: await ProxyEngine.credentials()
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
		if (stats && (stats.bytesRx > 0 || stats.bytesTx > 0)) {
			Api.reportStats({
				sessionId: runtime.session?.id ?? undefined,
				downloadBytes: stats.bytesRx,
				uploadBytes: stats.bytesTx,
				transport: 'browser',
			}).catch(() => {})
		}
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
		if (error instanceof ApiError && error.code === 'maintenance') {
			await enterMaintenance(safeError(error, 'maintenance'))
			return
		}
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

// ----------------------------------------------------------- link sign-in ---

/*
 * Sign in by link - the same flow the desktop client uses.
 *
 * The old bridge worked the other way round: the website was asked to sign in
 * and a content script lifted whatever refresh token it could find in page
 * storage. So the extension could only sign in on an origin that had already
 * signed in, the token was never minted for this browser, and the whole thing
 * broke whenever the site changed how it stores sessions. Now the extension
 * starts a request, the website approves it, and the server hands tokens to
 * whoever holds `pollSecret` - which never leaves this worker.
 *
 * MV3 makes the waiting part awkward: this worker is torn down while the user
 * is over on the website. The pending request therefore lives in runtime state
 * and an alarm resumes polling. `getState` polls too, which is what makes
 * reopening the popup after approval feel instant despite the alarm floor.
 */
async function startSiteLink() {
	const settings = await Store.settings()
	const info = detectBrowser()
	const started = await Api.linkStart({ client: 'extension', deviceName: info.deviceName })

	// The server builds the confirmation URL from its own SITE_BASE_URL and pins
	// the channel with &api=. Only the origin is swapped, and only when the user
	// pointed the extension at a different site: dropping the query would take
	// the channel with it, which is exactly the bug that produced "this sign-in
	// link is unknown or has expired" for seconds-old links.
	let verifyUrl = String(started.verifyUrl ?? '')
	const base = String(settings.siteBase || '').replace(/\/+$/, '')
	if (base && verifyUrl) {
		try {
			const current = new URL(verifyUrl)
			const wanted = new URL(base)
			if (current.origin !== wanted.origin) {
				verifyUrl = wanted.origin + current.pathname + current.search
			}
		} catch {}
	}
	if (!verifyUrl) throw new Error('The server did not return a sign-in link.')

	await patchRuntime({
		link: {
			requestId: started.requestId,
			pollSecret: started.pollSecret,
			userCode: started.userCode ?? null,
			verifyUrl,
			expiresAt: started.expiresAt ?? null,
			intervalSec: Number(started.intervalSec) || 2,
			startedAt: Date.now(),
		},
	})
	try {
		await chrome.tabs.create({ url: verifyUrl })
	} catch (error) {
		await patchRuntime({ link: null })
		throw error
	}
	await armLinkAlarm()
	// Most people are already signed in on the site and approve within seconds.
	void pollLinkUntil(Date.now() + LINK_FAST_WINDOW_MS)
	return {
		ok: true,
		userCode: started.userCode ?? null,
		verifyUrl,
		expiresAt: started.expiresAt ?? null,
	}
}

async function armLinkAlarm() {
	try {
		await chrome.alarms.create(LINK_ALARM, { delayInMinutes: 0.5 })
	} catch {}
}

async function clearLink(patch) {
	try {
		await chrome.alarms.clear(LINK_ALARM)
	} catch {}
	await patchRuntime({ link: null, ...(patch ?? {}) })
}

async function pollLinkUntil(deadline) {
	while (Date.now() < deadline) {
		await new Promise((resolve) => setTimeout(resolve, LINK_FAST_POLL_MS))
		const outcome = await runLinkPoll()
		if (outcome !== 'pending') return outcome
	}
	return 'pending'
}

/** One poll. Returns 'idle' | 'pending' | 'approved' | 'denied' | 'expired'. */
async function runLinkPoll() {
	const runtime = await Store.runtime()
	const link = runtime?.link
	if (!link?.requestId || !link?.pollSecret) return 'idle'
	if ((await Store.session())?.tokens?.refreshToken) {
		await clearLink()
		return 'approved'
	}
	if (link.expiresAt && Date.parse(link.expiresAt) < Date.now()) {
		await clearLink({
			error: { code: 'link_expired', message: 'The sign-in link expired. Start again.' },
		})
		return 'expired'
	}

	let outcome = null
	try {
		outcome = await Api.linkPoll({ requestId: link.requestId, pollSecret: link.pollSecret })
	} catch {
		// Offline, a timeout or a 5xx is not a verdict. Keep the request alive and
		// let the alarm try again - the code is valid for five minutes.
		await armLinkAlarm()
		return 'pending'
	}

	const status = String(outcome?.status ?? '')
	if (status === 'approved') {
		await Api.saveLinkedSession(outcome)
		await clearLink({ phase: PHASE.idle, error: null })
		await setBadge(PHASE.idle)
		// Register at once so this browser appears in the devices list without
		// waiting for a first connect.
		try {
			await ensureDeviceScope()
		} catch (error) {
			await patchRuntime({ phase: PHASE.idle, error: safeError(error, 'device_registration_failed') })
		}
		try {
			chrome.runtime.sendMessage({ type: 'signedIn' }).catch(() => {})
		} catch {}
		if ((await Store.settings()).autoConnect) void connect({ userInitiated: false })
		return 'approved'
	}
	if (status === 'pending' || status === 'slow_down') {
		await armLinkAlarm()
		return 'pending'
	}
	if (status === 'denied') {
		await clearLink({
			error: { code: 'link_denied', message: 'The sign-in request was rejected on the website.' },
		})
		return 'denied'
	}
	await clearLink({
		error: { code: 'link_expired', message: 'The sign-in link is no longer valid. Start again.' },
	})
	return 'expired'
}

const HANDLERS = {
	getState: async () => {
		// Fast path for sign-in by link: the popup asks for state every five
		// seconds, so coming back to it right after approving on the website
		// collects the tokens at once instead of waiting for the alarm.
		void runLinkPoll()
		void poll()
		return state()
	},
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
	async serviceStatus() {
		return checkMaintenance()
	},
	async activeMap() {
		try {
			return { ok: true, ...(await Api.activeMap()) }
		} catch (error) {
			const serialized = safeError(error, 'active_map_failed')
			return { ok: false, error: serialized.message, ...serialized }
		}
	},
	async retryPendingConnect() {
		const runtime = await Store.runtime()
		const settings = await Store.settings()
		const intent = runtime?.connectIntent
		if (!intent?.requested || intent.channel !== settings.channel) return { ok: false, error: 'There is no connection to resume.', code: 'no_pending_connect' }
		return connect({ nodeId: intent.nodeId, userInitiated: false })
	},
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
				tunnelIncognito: settings.tunnelIncognito,
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
				await Store.clearSession()
				await patchRuntime({ phase: PHASE.signedOut, session: null, gateway: null, stats: null, connectIntent: null, maintenance: null })
				await setBadge(PHASE.signedOut)
			}
			return { ok: true, ...result }
		} catch (error) {
			return { ok: false, error: error?.message ?? 'Could not revoke device.' }
		}
	},
	/** Sign in by link, unified with the desktop client. Opens the site with a
	 *  one-time code, then collects tokens minted for this browser. */
	async linkWithSite() {
		if ((await Store.session())?.tokens?.refreshToken) return { ok: true, already: true }
		try {
			return await startSiteLink()
		} catch (error) {
			await patchRuntime({ link: null })
			return {
				ok: false,
				error: error?.message ?? 'Could not start sign-in by link.',
				code: error?.code ?? 'link_failed',
			}
		}
	},

	/** Popup progress while the user is over on the website. */
	async linkStatus() {
		const status = await runLinkPoll()
		const runtime = await Store.runtime()
		return {
			ok: true,
			status,
			link: runtime?.link ?? null,
			signedIn: Boolean((await Store.session())?.tokens?.refreshToken),
		}
	},

	async linkCancel() {
		await clearLink({ error: null })
		return { ok: true }
	},

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
		.catch((error) => {
			const serialized = safeError(error, 'unexpected_error')
			sendResponse({ ok: false, error: serialized.message, ...serialized })
		})
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
	if (alarm.name === LINK_ALARM) void runLinkPoll()
	if (alarm.name === MAINTENANCE_ALARM) void checkMaintenance()
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
			await withTimeout(connect({ nodeId: settings.preferredNodeId, userInitiated: false }), 40000, 'autoconnect')
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

