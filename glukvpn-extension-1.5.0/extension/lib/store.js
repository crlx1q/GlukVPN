/* Persistent state. chrome.storage.local survives service-worker restarts,
 * which MV3 does constantly - nothing important may live in memory only.
 *
 * Every read here is fault tolerant. A half-written or corrupted value must
 * never leave the popup with a blank screen, so reads always fall back to the
 * defaults instead of throwing.
 */

export const TUNNEL_MODES = ['all', 'except', 'only']
export const LANGUAGE_CHOICES = ['auto', 'ru', 'en']

export const DEFAULT_SETTINGS = {
	// Which control plane to talk to. Same split as the app: separate database,
	// separate JWT secret, so a session on one is meaningless on the other.
	channel: 'prod',
	apiBase: { prod: 'https://api.gluk.tech', beta: 'https://beta-api.gluk.tech' },
	// Website that approves a browser sign-in. The extension opens a link here
	// and the person confirms it there. Nothing is read out of the page's own
	// storage any more, so this is purely the origin of the confirmation URL.
	siteBase: 'https://vpn.gluk.tech',
	// Browser gateway on the VPN node. Empty host = derive from the node the
	// control plane hands us.
	gateway: { host: '', port: 8443, scheme: 'https' },
	// No DIRECT fallback in the PAC file: if the gateway is unreachable the
	// browser fails closed instead of quietly leaking to the local ISP.
	killSwitch: true,
	// 'auto' resolves from GeoIP country, then browser locale, then time zone.
	language: 'auto',
	// Split tunnelling: all sites, all except siteList, or only siteList.
	tunnelMode: 'all',
	siteList: [],
	// Hostnames that always go direct (banks, intranet, local dev).
	bypass: ['localhost', '127.0.0.1', '*.local', '10.*', '192.168.*'],
	autoConnect: false,
	preferredNodeId: null,
}

const KEYS = {
	settings: 'settings',
	session: 'session',
	device: 'device',
	runtime: 'runtime',
	nodes: 'nodes',
}

/** Accepts an array or a newline/comma separated string, returns clean hosts. */
export function normaliseList(value) {
	const raw = Array.isArray(value)
		? value
		: typeof value === 'string'
			? value.split(/[\r\n,]+/)
			: []
	const seen = new Set()
	for (const item of raw) {
		const trimmed = String(item ?? '').trim().toLowerCase()
		if (trimmed) seen.add(trimmed)
	}
	return [...seen]
}

/** Repairs anything the user or an older build may have left behind. */
function mergeSettings(stored) {
	const s = stored && typeof stored === 'object' ? stored : {}
	const merged = {
		...DEFAULT_SETTINGS,
		...s,
		apiBase: { ...DEFAULT_SETTINGS.apiBase, ...(s.apiBase ?? {}) },
		gateway: { ...DEFAULT_SETTINGS.gateway, ...(s.gateway ?? {}) },
	}

	merged.bypass = normaliseList(merged.bypass)
	merged.siteList = normaliseList(merged.siteList)
	if (!TUNNEL_MODES.includes(merged.tunnelMode)) merged.tunnelMode = 'all'
	if (!LANGUAGE_CHOICES.includes(merged.language)) merged.language = 'auto'
	if (merged.channel !== 'beta') merged.channel = 'prod'
	merged.killSwitch = Boolean(merged.killSwitch)
	merged.autoConnect = Boolean(merged.autoConnect)

	merged.gateway.host = String(merged.gateway.host ?? '').trim()
	const port = Number(merged.gateway.port)
	merged.gateway.port = Number.isFinite(port) && port > 0 && port < 65536 ? port : 8443
	const scheme = String(merged.gateway.scheme ?? 'https').toLowerCase()
	merged.gateway.scheme = ['https', 'http', 'socks5'].includes(scheme) ? scheme : 'https'

	return merged
}

async function get(key, fallback) {
	try {
		const bag = await chrome.storage.local.get(key)
		return bag?.[key] ?? fallback
	} catch {
		return fallback
	}
}

async function set(key, value) {
	try {
		await chrome.storage.local.set({ [key]: value })
	} catch {}
	return value
}

async function remove(keys) {
	try {
		await chrome.storage.local.remove(keys)
	} catch {}
}

export const Store = {
	async settings() {
		return mergeSettings(await get(KEYS.settings, {}))
	},
	async saveSettings(patch) {
		const current = await Store.settings()
		const p = patch && typeof patch === 'object' ? patch : {}
		const next = mergeSettings({
			...current,
			...p,
			apiBase: { ...current.apiBase, ...(p.apiBase ?? {}) },
			gateway: { ...current.gateway, ...(p.gateway ?? {}) },
		})
		return set(KEYS.settings, next)
	},

	/* tokens + user profile */
	session: () => get(KEYS.session, null),
	saveSession: (value) => set(KEYS.session, value),
	clearSession: () => remove([KEYS.session, KEYS.runtime]),

	/* WireGuard identity of this browser. Private key never leaves here. */
	device: () => get(KEYS.device, null),
	saveDevice: (value) => set(KEYS.device, value),
	clearDevice: () => remove(KEYS.device),

	/* live tunnel state, mirrored so the popup can render instantly */
	runtime: () => get(KEYS.runtime, null),
	saveRuntime: (value) => set(KEYS.runtime, value),
	clearRuntime: () => remove(KEYS.runtime),

	async nodes() {
		const value = await get(KEYS.nodes, [])
		return Array.isArray(value) ? value : []
	},
	saveNodes: (value) => set(KEYS.nodes, Array.isArray(value) ? value : []),
}
