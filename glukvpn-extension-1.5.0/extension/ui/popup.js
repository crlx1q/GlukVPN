/*
 * Popup controller.
 *
 * Hard rules learned from the last round of bug reports:
 *  - every call to the service worker has a deadline and a visible outcome;
 *    "spinning forever" is treated as a bug, not as a state
 *  - the worker is asleep most of the time in MV3, so the first message after
 *    opening the popup is retried once before anything is called broken
 *  - a failed request never blanks a screen: the last good data stays on
 *    screen with an inline retry next to it
 *  - the power button is never disabled - if it looks pressable it must react
 *  - every control writes through to storage the instant it changes, and the
 *    background poll is not allowed to overwrite a value the user just set
 *  - the connect animation is a report, not a decoration: it only runs while
 *    a real attempt is in flight
 */

import { createTranslator, resolveLanguage, errorKeyFor } from '../lib/i18n.js'
import { formatNodeLocation, localizeCountry, localizeCity } from '../lib/geo.js'
import { bestNode } from '../lib/pick.js'
import { paintIcons, iconSvg } from './icons.js'
import { flagSvg } from './flags.js'
import { Telemetry } from '../lib/telemetry.js'

/* Bug reports. The popup is a real document, so the DOM globals exist here.
 * The open view travels with the report - it is usually the whole repro. */
function crashContext(kind) {
	try {
		return `popup:${kind}:${state?.view ?? 'boot'}`
	} catch {
		return `popup:${kind}`
	}
}

window.addEventListener('error', (event) => {
	Telemetry.report(event?.error ?? event?.message, crashContext('error'))
})

window.addEventListener('unhandledrejection', (event) => {
	Telemetry.report(event?.reason, crashContext('unhandledrejection'))
})

/* The shared modules hand out a translator factory and a flag element
 * builder. These adapters keep the rest of the file readable. */
let translate = createTranslator('en')

function t(key, vars) {
	return translate(key, vars)
}

function setLanguage(preference) {
	// 'auto' resolves through GeoIP, then the browser locale, then the clock.
	const lang = resolveLanguage(preference, state?.runtime?.geo?.countryCode)
	translate = createTranslator(lang)
	document.documentElement.lang = lang
	return lang
}

// The city is passed through as well: the control plane often sends a display
// name ("Kazakhstan") rather than an ISO code, and sometimes only a city.
function paintFlag(holder, code, city) {
	if (!holder) return
	holder.replaceChildren(flagSvg(code, 22, city))
}

const $ = (id) => document.getElementById(id)
const VIEWS = ['vpn', 'servers', 'settings', 'profile']
const CALL_TIMEOUT_MS = 20000
const NODES_CACHE = 'gluk.popup.nodes'
const SAVE_DEBOUNCE_MS = 320
// A connect attempt that produces nothing for this long is a failure, not a
// state. Without this the spinner ran forever on a dead network.
const CONNECT_WATCHDOG_MS = 30000

const DEFAULTS = {
	channel: 'prod',
	apiBase: { prod: 'https://api.gluk.tech', beta: 'https://beta-api.gluk.tech' },
	siteBase: 'https://vpn.gluk.tech',
	gateway: { host: '', port: 8443, scheme: 'https' },
	killSwitch: true,
	bypass: ['localhost', '127.0.0.1', '*.local', '10.*', '192.168.*'],
	autoConnect: false,
	preferredNodeId: null,
	tunnelMode: 'all',
	siteList: [],
	language: 'auto',
	tunnelIncognito: false,
}

// A metric that is still unknown while connected shows a skeleton - but not
// forever. Past this age the value is treated as unavailable and an em dash
// takes over (the exit-IP probe can legitimately be blocked, for instance).
const METRIC_SKELETON_MAX_MS = 75000
const DASH = '\u2014'

// Chrome's own "Allow in Incognito" switch: null = not asked yet / unknown.
let incognitoAllowed = null

// PROD / BETA card. Versions are probed best-effort when Settings opens and
// kept here so re-renders never cost a request.
const CHANNELS = ['prod', 'beta']
const CHANNEL_PROBE_TIMEOUT_MS = 1500
const CHANNEL_CACHE_MS = 60000
const channelInfo = {
	prod: { status: 'unknown', version: null, checkedAt: 0 },
	beta: { status: 'unknown', version: null, checkedAt: 0 },
}
let channelProbe = null
let channelSwitching = false
// Sticky until the next attempt or until the user leaves Settings, so the
// five-second state poll cannot wipe it before it has been read.
let channelError = null

let state = null
let settings = { ...DEFAULTS }
let nodes = []
let view = 'vpn'
let busySince = 0
let tickTimer = null
let pollTimer = null
let advancedOpen = false
let devModeOpen = false
let savePending = false
let saveTimer = null
let saveStateTimer = null
// Until this moment passes, incoming state must not overwrite the local
// settings object. This is the other half of the "toggle snaps back" fix:
// the worker keeps reporting the old values for a beat after a write.
let saveGuardUntil = 0
let deviceActiveCount = 0
// Device paging. The fetched rows are kept here so flipping pages never costs
// another request, and five per page stops a long list from eating the popup.
const DEVICES_PER_PAGE = 5
let deviceRows = []
let deviceMax = 0
let deviceFailure = ''
let devicePage = 0
// ROUND 9 (block 4.3): which bucket #seg-devices is showing.
let deviceFilter = 'all'
let loginMode = 'site'
let connectWatchdog = null
let localPhase = null
let activeMapRevision=0
let activeMapData = null
let activeMapBusy = false
let limitModalFingerprint = ''
let dismissedLimitFingerprint = ''
let limitModalError = null

// ------------------------------------------------------------- messaging ---

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const isOnline = () => {
	try {
		return navigator.onLine !== false
	} catch {
		return true
	}
}

/** One attempt. Always resolves - never throws, never hangs. */
function sendOnce(message) {
	return new Promise((resolve) => {
		let settled = false
		const done = (value) => {
			if (settled) return
			settled = true
			resolve(value)
		}
		const timer = setTimeout(() => done({ ok: false, error: t('err.timeout'), code: 'timeout' }), CALL_TIMEOUT_MS)
		try {
			chrome.runtime.sendMessage(message, (response) => {
				clearTimeout(timer)
				const lastError = chrome.runtime.lastError
				if (lastError) return done({ ok: false, error: lastError.message, code: 'asleep' })
				if (response === undefined || response === null) return done({ ok: false, error: t('err.wakeFailed'), code: 'asleep' })
				done(response)
			})
		} catch (error) {
			clearTimeout(timer)
			done({ ok: false, error: String(error?.message ?? error), code: 'asleep' })
		}
	})
}

/**
 * Talks to the background worker. The payload is sent both nested and spread
 * so the call works whichever shape the worker reads.
 */
async function call(type, payload = {}) {
	const message = { type, payload, ...payload }
	let response = await sendOnce(message)
	// MV3 tears the worker down aggressively; the first message after opening
	// the popup often lands while it is still booting. That is not an error.
	if (!response?.ok && response?.code === 'asleep') {
		await sleep(300)
		response = await sendOnce(message)
	}
	// The worker wraps every reply in { ok, data }. A handler that failed
	// politely reports ok:false *inside* that envelope - unwrap it, otherwise
	// a refused connect would be read as a successful one.
	if (response?.ok === true && response.data && typeof response.data === 'object' && response.data.ok === false) {
		const inner = response.data
		return {
			ok: false,
			error: inner.error,
			code: inner.code ?? inner.error?.code ?? 'error',
			status: inner.status ?? inner.statusCode ?? 0,
			retryAfterSec: inner.retryAfterSec ?? null,
			details: inner.details ?? inner.error?.details ?? null,
		}
	}
	return response ?? { ok: false, error: t('err.unknown'), code: 'unknown' }
}

/** Turns anything the worker can return into a sentence for the user. */
function humanError(response) {
	if (!response) return t('err.unknown')
	const raw = response.error ?? response
	const probe = typeof raw === 'string' ? { message: raw, code: response.code } : { message: raw?.message, code: raw?.code ?? response.code }
	const key = errorKeyFor(probe)
	if (key) return t(key)
	const text = String(probe.message ?? '').trim()
	return text || t('err.unknown')
}

// ---------------------------------------------------------------- callouts --

/**
 * A framed notice. An error is a thing that happened, so it gets a red frame,
 * an icon and a title - not a grey sentence floating above the layout.
 */
function calloutNode({ title, text, kind = 'bad', actionLabel, onAction } = {}) {
	const box = document.createElement('div')
	box.className = 'callout ' + (kind === 'ok' ? 'ok' : kind === 'info' ? 'info' : kind === 'warn' ? 'warn' : 'err')
	const ic = document.createElement('span')
	ic.className = 'c-ic'
	ic.appendChild(iconSvg(kind === 'ok' ? 'check' : kind === 'info' ? 'info' : kind === 'warn' ? 'warn' : 'alert'))
	box.appendChild(ic)
	const body = document.createElement('div')
	body.className = 'c-body'
	const heading = title ?? (kind === 'ok' || kind === 'info' ? '' : t('err.title'))
	if (heading) {
		const h = document.createElement('div')
		h.className = 'c-title'
		h.textContent = heading
		body.appendChild(h)
	}
	if (text) {
		const p = document.createElement('div')
		p.className = 'c-text'
		p.textContent = text
		body.appendChild(p)
	}
	if (actionLabel && onAction) {
		const b = document.createElement('button')
		b.type = 'button'
		b.className = 'c-act'
		b.textContent = actionLabel
		b.addEventListener('click', onAction)
		body.appendChild(b)
	}
	box.appendChild(body)
	return box
}

/**
 * Shows a message in one of the banner slots.
 *
 * Everything goes through calloutNode now. The old implementation wrote a bare
 * `class="banner"` for the failure case, and the stylesheet only had rules for
 * `.banner.err` - which is why connection errors rendered as plain text with
 * no frame at all.
 */
function banner(id, text, { kind = 'bad', title, actionLabel, onAction } = {}) {
	const node = $(id)
	if (!node) return
	node.textContent = ''
	if (!text) {
		// Clearing only the text used to leave the frame behind, which rendered
		// as a tall empty slab at the top of the view.
		node.hidden = true
		node.className = ''
		return
	}
	node.className = 'banner-slot'
	node.hidden = false
	node.appendChild(calloutNode({ title, text, kind, actionLabel, onAction }))
}

// -------------------------------------------------------------- formatting -

function bytesLabel(bytes) {
	const value = Number(bytes)
	if (!Number.isFinite(value) || value < 0) return '0 B'
	const units = ['B', 'KB', 'MB', 'GB', 'TB']
	let index = 0
	let scaled = value
	while (scaled >= 1024 && index < units.length - 1) {
		scaled /= 1024
		index += 1
	}
	const digits = scaled >= 100 || index === 0 ? 0 : 1
	return `${scaled.toFixed(digits)} ${units[index]}`
}

function durationLabel(ms) {
	const total = Math.max(0, Math.floor(Number(ms) / 1000))
	if (!Number.isFinite(total)) return '--'
	const hours = Math.floor(total / 3600)
	const minutes = Math.floor((total % 3600) / 60)
	const seconds = total % 60
	const pad = (n) => String(n).padStart(2, '0')
	return hours > 0 ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${pad(minutes)}:${pad(seconds)}`
}

function pingLabel(ms) {
	const value = Number(ms)
	return Number.isFinite(value) && value > 0 ? `${Math.round(value)} ${t('stat.msUnit')}` : '--'
}

function signalOf(ms) {
	const value = Number(ms)
	if (!Number.isFinite(value) || value <= 0) return 2
	if (value <= 60) return 3
	if (value <= 140) return 2
	return 1
}

// -------------------------------------------------------------------- geo ---

const PLACES = {
	DE: [51.2, 10.4], FR: [46.6, 2.4], NL: [52.2, 5.3], US: [39.8, -98.6], GB: [54.0, -2.0],
	TR: [39.0, 35.2], SG: [1.35, 103.8], JP: [36.2, 138.3], KZ: [48.0, 68.0], RU: [55.8, 37.6],
	PL: [52.1, 19.4], SE: [60.1, 18.6], FI: [64.0, 26.0], NO: [60.5, 8.5], DK: [56.0, 10.0],
	CH: [46.8, 8.2], ES: [40.2, -3.7], IT: [42.8, 12.6], CA: [56.1, -106.3], AU: [-25.3, 133.8],
	IN: [21.0, 78.0], BR: [-14.2, -51.9], UA: [48.4, 31.2], CZ: [49.8, 15.5], AT: [47.5, 14.6],
	RO: [45.9, 25.0], BE: [50.5, 4.5], IE: [53.4, -8.2], PT: [39.4, -8.2], LT: [55.2, 23.9],
	LV: [56.9, 24.6], EE: [58.6, 25.0], MX: [23.6, -102.5], AR: [-38.4, -63.6], CL: [-35.7, -71.5],
	ZA: [-30.6, 22.9], AE: [23.4, 53.8], IL: [31.0, 34.9], HK: [22.3, 114.2], KR: [35.9, 127.8],
	CN: [35.9, 104.2], ID: [-0.8, 113.9], IS: [64.9, -19.0], BD: [23.7, 90.4], CO: [4.6, -74.3],
	UZ: [41.4, 64.6], KG: [41.2, 74.8], GE: [42.3, 43.4], AM: [40.1, 45.0], AZ: [40.1, 47.6],
	BY: [53.7, 27.9], MD: [47.4, 28.4], HU: [47.2, 19.5], BG: [42.7, 25.5], GR: [39.1, 21.8],
	HR: [45.1, 15.2], RS: [44.0, 21.0], SK: [48.7, 19.7], SI: [46.2, 14.8], TJ: [38.9, 71.3],
	TM: [38.9, 59.6], EG: [26.8, 30.8], TH: [15.9, 101.0], VN: [14.1, 108.3], MY: [4.2, 101.9],
	NZ: [-40.9, 174.9],
}

const CITIES = {
	frankfurt: [50.11, 8.68], berlin: [52.52, 13.4], paris: [48.86, 2.35], amsterdam: [52.37, 4.9],
	london: [51.51, -0.13], 'new york': [40.71, -74.01], 'los angeles': [34.05, -118.24],
	istanbul: [41.01, 28.98], singapore: [1.35, 103.82], tokyo: [35.68, 139.69],
	astana: [51.16, 71.47], almaty: [43.24, 76.89], aqmola: [51.16, 71.47], akmola: [51.16, 71.47],
	qyzylorda: [44.85, 65.51], kyzylorda: [44.85, 65.51], shymkent: [42.32, 69.59], aqtobe: [50.28, 57.17],
	moscow: [55.76, 37.62], warsaw: [52.23, 21.01], stockholm: [59.33, 18.07],
	helsinki: [60.17, 24.94], zurich: [47.38, 8.54], madrid: [40.42, -3.7], milan: [45.46, 9.19],
	vienna: [48.21, 16.37], prague: [50.08, 14.44], toronto: [43.65, -79.38], sydney: [-33.87, 151.21],
	mumbai: [19.08, 72.88], 'sao paulo': [-23.55, -46.63], kyiv: [50.45, 30.52], dubai: [25.2, 55.27],
	'hong kong': [22.32, 114.17], seoul: [37.57, 126.98], oslo: [59.91, 10.75], copenhagen: [55.68, 12.57],
	tashkent: [41.3, 69.24], bishkek: [42.87, 74.59], tbilisi: [41.72, 44.79], baku: [40.41, 49.87],
	yerevan: [40.18, 44.51], minsk: [53.9, 27.57],
}

function latLonFor(place) {
	const city = String(place?.city ?? '').trim().toLowerCase()
	if (city && CITIES[city]) return CITIES[city]
	const code = String(place?.countryCode ?? place?.country ?? '').trim().toUpperCase()
	if (code && PLACES[code]) return PLACES[code]
	return null
}

function placeLabel(place, lang = 'ru') {
	const cName = localizeCountry(place?.countryCode || place?.country, lang) || place?.country
	const cityName = localizeCity(place?.city || place?.region, lang) || place?.city || place?.region
	const parts = [cityName, cName].map((p) => String(p ?? '').trim()).filter(Boolean)
	const unique = parts.filter((part, index) => parts.indexOf(part) === index)
	return unique.length ? unique.join(', ') : ''
}

/** Equirectangular projection onto the shipped 119x60 dotted map. */
function project(lat, lon) {
	return { x: ((Number(lon) + 180) / 360) * 119, y: ((90 - Number(lat)) / 180) * 60 }
}

function normalizedError(error) {
	const raw = error?.error ?? error
	return typeof raw === 'string'
		? { message: raw, code: error?.code, status: error?.status, details: error?.details }
		: { ...raw, code: raw?.code ?? error?.code, status: raw?.status ?? error?.status, details: raw?.details ?? error?.details }
}

function isDeviceLimit(error) {
	return String(normalizedError(error)?.code ?? '').toLowerCase() === 'device_limit_reached'
}

/** Renders an error into a slot. Everything lands in a red frame. */
function showError(id, error) {
	if (!$(id)) return
	if (!error) {
		banner(id, '')
		return
	}
	if (isDeviceLimit(error)) {
		openDeviceLimitModal(normalizedError(error))
		banner(id, t('err.tooManyDevices'), { title: t('limit.title') })
		return
	}
	const normalized = normalizedError(error)
	if (normalized.code === 'maintenance') {
		banner(id, t('maintenance.body', { seconds: normalized.retryAfterSec ?? normalized.details?.retryAfterSec ?? 30 }), {
			title: t('maintenance.title'), kind: 'warn',
		})
		return
	}
	banner(id, humanError({ error: normalized }), { title: t('err.connectTitle') })
}

// -------------------------------------------------------------- when/geo ---

function whenLabel(value) {
	if (!value) return t('dev.never')
	const then = new Date(value).getTime()
	if (!Number.isFinite(then)) return t('dev.never')
	const diff = then - Date.now()
	const abs = Math.abs(diff)
	const units = [
		['minute', 60000],
		['hour', 3600000],
		['day', 86400000],
	]
	try {
		const rtf = new Intl.RelativeTimeFormat(currentLang(), { numeric: 'auto' })
		if (abs < 60000) return rtf.format(0, 'minute')
		for (let i = units.length - 1; i >= 0; i -= 1) {
			const [unit, ms] = units[i]
			if (abs >= ms) return rtf.format(Math.round(diff / ms), unit)
		}
	} catch {}
	return new Date(then).toLocaleDateString()
}

// Timezone -> country. Used only when the worker has no IP geolocation yet,
// so the map still knows roughly where "you" are instead of giving up.
const TZ_COUNTRY = {
	'Asia/Almaty': 'KZ', 'Asia/Qyzylorda': 'KZ', 'Asia/Aqtobe': 'KZ', 'Asia/Aqtau': 'KZ',
	'Asia/Atyrau': 'KZ', 'Asia/Oral': 'KZ', 'Europe/Moscow': 'RU', 'Europe/Samara': 'RU',
	'Asia/Yekaterinburg': 'RU', 'Asia/Novosibirsk': 'RU', 'Europe/Kyiv': 'UA', 'Europe/Kiev': 'UA',
	'Europe/Minsk': 'BY', 'Asia/Tashkent': 'UZ', 'Asia/Bishkek': 'KG', 'Asia/Tbilisi': 'GE',
	'Asia/Yerevan': 'AM', 'Asia/Baku': 'AZ', 'Europe/Berlin': 'DE', 'Europe/Paris': 'FR',
	'Europe/Amsterdam': 'NL', 'Europe/Istanbul': 'TR', 'Asia/Singapore': 'SG', 'Asia/Tokyo': 'JP',
	'America/New_York': 'US', 'America/Chicago': 'US', 'America/Los_Angeles': 'US',
	'Europe/London': 'GB', 'Europe/Warsaw': 'PL',
}

function currentLang() {
	const pref = settings.language ?? 'auto'
	if (pref === 'ru' || pref === 'en') return pref
	try {
		return (navigator.language || 'en').slice(0, 2)
	} catch {
		return 'en'
	}
}

/** Best-effort "where am I". Never returns null once a timezone is readable. */
function resolveGeo() {
	const geo = state?.runtime?.geo ?? null
	if (geo && (geo.countryCode || geo.city)) return geo
	try {
		const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
		const cc = TZ_COUNTRY[tz]
		if (cc) {
			return {
				countryCode: cc,
				city: String(tz.split('/').pop() ?? '').replace(/_/g, ' '),
				approximate: true,
			}
		}
	} catch {}
	return geo
}

// ---------------------------------------------------------------- routing ---

function setPoint(dotId, ringId, point) {
	for (const id of [dotId, ringId]) {
		const node = $(id)
		if (!node) continue
		node.setAttribute('cx', point.x.toFixed(2))
		node.setAttribute('cy', point.y.toFixed(2))
	}
}

/** Draws "you" and "the server" and the arc between them. */
function drawRoute(home, server, phase = 'idle') {
	const you = home ? project(home[0], home[1]) : { x: 82.44, y: 12.24 }
	setPoint('you-dot', 'you-ring', you)
	const path = $('conn-path')
	const show = (id, on) => {
		const node = $(id)
		if (node) node.style.opacity = on ? '' : '0'
	}
	show('you-dot', true)
	show('you-ring', true)
	if (!server) {
		show('server-dot', false)
		show('server-ring', false)
		if (path) {
			path.style.opacity = '0'
			path.setAttribute('d', 'M' + you.x.toFixed(2) + ',' + you.y.toFixed(2) + ' L' + you.x.toFixed(2) + ',' + you.y.toFixed(2))
		}
		return
	}
	const target = project(server[0], server[1])
	setPoint('server-dot', 'server-ring', target)
	show('server-dot', true)
	show('server-ring', true)
	// Lift the control point so the arc bows away from the globe instead of
	// cutting a straight line across it.
	const midX = (you.x + target.x) / 2
	const midY = (you.y + target.y) / 2
	const span = Math.hypot(target.x - you.x, target.y - you.y)
	const lift = Math.min(14, Math.max(3, span * 0.32))
	if (path) {
		path.setAttribute(
			'd',
			'M' + you.x.toFixed(2) + ',' + you.y.toFixed(2) + ' Q' + midX.toFixed(2) + ',' + (midY - lift).toFixed(2) + ' ' + target.x.toFixed(2) + ',' + target.y.toFixed(2),
		)
		// Solid while the tunnel is up, faint while it is only a proposal, and
		// dead while there is no link to carry it.
		path.style.opacity = phase === 'connected' ? '1' : phase === 'offline' ? '0.14' : '0.45'
	}
}

// ------------------------------------------------------------------ views ---

function syncGlide() {
	const glide = $('nav-glide')
	const target = document.querySelector(`.nav-item[data-view="${view}"]`)
	// Measured, not hard-coded, so the pill lands exactly on the button
	// whatever spacing the rail happens to use - including the account chip
	// at the very bottom, which is now a tab like any other.
	if (glide && target && target.offsetHeight) {
		glide.style.height = `${target.offsetHeight}px`
		glide.style.transform = `translateY(${Math.round(target.offsetTop)}px)`
		glide.style.opacity = '1'
	}
	for (const item of document.querySelectorAll('.nav-item')) {
		item.classList.toggle('active', item.dataset.view === view)
		item.setAttribute('aria-current', item.dataset.view === view ? 'page' : 'false')
	}
}

function setView(next) {
	if (!VIEWS.includes(next)) return
	view = next
	for (const section of document.querySelectorAll('.view')) {
		const on = section.id === `view-${next}`
		section.classList.toggle('active', on)
		// Both the class and the attribute, or `.hidden { display:none }` wins
		// and the view never appears.
		section.classList.toggle('hidden', !on)
		section.hidden = !on
	}
	syncGlide()
	if (next === 'servers') ensureNodes()
	if (next === 'settings') {
		ensureDevices()
		// Both are best effort and both come back through a render, so the
		// section opens at once and fills in as answers arrive.
		probeIncognitoAccess()
		if (channelCardVisible()) ensureChannelVersions()
	} else if (channelError) {
		channelError = null
		renderChannelCard()
	}
	if (next === 'profile') {
		ensureDevices()
		renderProfile()
	}
	// A hidden element measures 0 wide, so the sliding pill can only be placed
	// after the section is on screen.
	requestAnimationFrame(() => {
		syncSegment('seg-lang', settings.language ?? 'auto')
		syncSegment('seg-tunnel', settings.tunnelMode ?? 'all')
		syncGlide()
	})
}

function applyI18n(root = document) {
	for (const node of root.querySelectorAll('[data-i18n]')) {
		node.textContent = t(node.getAttribute('data-i18n'))
	}
	const identifier = $('identifier')
	if (identifier) identifier.placeholder = t('login.identifier')
	const password = $('password')
	if (password) password.placeholder = t('login.password')
	const hint = $('tunnel-hint')
	if (hint) {
		const map = { all: 'settings.tunnelAllHint', except: 'settings.tunnelExceptHint', only: 'settings.tunnelOnlyHint' }
		hint.textContent = t(map[settings.tunnelMode] ?? map.all)
	}
	// The list label says what the list actually does in the selected mode.
	const listLabel = $('site-list-label')
	if (listLabel) {
		listLabel.textContent = settings.tunnelMode === 'only' ? t('settings.siteListOnly') : t('settings.siteListExcept')
	}
	const acctName = $('acct-name')
	if (acctName && !acctName.textContent.trim()) acctName.textContent = t('nav.profile')
}

// ----------------------------------------------------------------- render ---

function phaseOf() {
	if (localPhase) return localPhase
	return String(state?.runtime?.phase ?? (state?.signedIn === false ? 'signedOut' : 'idle'))
}

function statusInfo() {
	const phase = phaseOf()
	const map = {
		connected: { text: t('status.connected'), cls: 'on' },
		connecting: { text: t('status.connecting'), cls: 'busy' },
		disconnecting: { text: t('status.disconnecting'), cls: 'busy' },
		error: { text: t('status.error'), cls: 'bad' },
		signedOut: { text: t('status.signedOut'), cls: '' },
	}
	return map[phase] ?? { text: t('status.idle'), cls: '' }
}

function nodeById(id) {
	return nodes.find((node) => String(node?.id ?? node?.nodeId) === String(id)) ?? null
}

/*
 * Id of the server the browser is actually using.
 *
 * The service worker publishes what it connected to as `runtime.node`. There
 * has never been a `runtime.nodeId`, so the old lookup always fell through to
 * `preferredNodeId` - which is null after an automatic connect. That is why
 * the card read "no server selected" while the tunnel was up.
 */
function activeNodeId() {
	const live = state?.runtime?.node
	const id = live?.id ?? live?.nodeId ?? settings.preferredNodeId
	return id ? String(id) : ''
}

function activeNode() {
	const live = state?.runtime?.node
	// The row from the server list carries load and ping; the runtime copy is
	// the fallback for a popup opened before the list finished loading.
	if (live?.id ?? live?.nodeId) return nodeById(live.id ?? live.nodeId) ?? live

	const manual = settings.preferredNodeId ? nodeById(settings.preferredNodeId) : null
	if (manual) return manual

	// Nothing was chosen by hand, so name the server Auto would take instead of
	// claiming none is selected. Same ranking as Windows and Android.
	// `paid` is left at its default: the control plane does not mark premium
	// nodes yet, so nothing is filtered out by it today.
	return bestNode(nodes, {
		preferCountryCode: state?.runtime?.geo?.countryCode ?? '',
	}).node
}

function renderVpn() {
	const online = isOnline()
	const phase = phaseOf()
	const info = online ? statusInfo() : { text: t('status.offline'), cls: 'bad' }
	const hero = $('hero')
	if (hero) {
		hero.classList.toggle('on', online && phase === 'connected')
		// The whole point of the spinner is to say "something is happening".
		// With the machine offline nothing is happening, so it must not spin.
		hero.classList.toggle('busy', online && (phase === 'connecting' || phase === 'disconnecting'))
		hero.classList.toggle('offline', !online)
		hero.classList.toggle('bad', online && phase === 'error')
	}
	const badge = $('status-badge')
	if (badge) badge.className = `badge ${info.cls}`.trim()
	const badgeText = $('status-text')
	if (badgeText) badgeText.textContent = info.text
	// The status is shown once, on the map badge. It used to be repeated in
	// the top bar, which just read as "connected connected".
	document.body.classList.toggle('is-connected', online && phase === 'connected')
	document.body.classList.toggle('is-offline', !online)

	// Where the user is.
	const currentLang = resolveLanguage(settings.language, state?.runtime?.geo?.countryCode)
	const geo = resolveGeo()
	const homeLabel = $('home-label')
	if (homeLabel) {
		if (state?.signedIn === false) homeLabel.textContent = t('loc.signIn')
		else homeLabel.textContent = placeLabel(geo, currentLang) || t('loc.unknown')
	}
	paintFlag($('home-flag'), geo?.countryCode ?? geo?.country, geo?.city)

	// Where the traffic goes.
	const node = activeNode()
	const curName = $('cur-name')
	if (curName) curName.textContent = node ? formatNodeLocation(node, currentLang) : t('node.none')
	const curMeta = $('cur-meta')
	if (curMeta) {
		const bits = []
		if (node?.load !== undefined && node?.load !== null) bits.push(t('node.load', { n: Math.round(Number(node.load)) }))
		if (node?.ping) bits.push(pingLabel(node.ping))
		// Once a node is resolved - chosen by hand or picked automatically - the
		// "fastest server" placeholder is stale and gets out of the way.
		curMeta.textContent = node ? bits.join(' \u00b7 ') : t('node.fastest')
		curMeta.hidden = Boolean(node) && bits.length === 0
	}
	paintFlag($('cur-flag'), node?.countryCode ?? node?.country, node?.city)

	// Both ends are drawn whenever they are known, like the phone app: you can
	// always see where you are and where the tunnel lands, connected or not.
	const target = node ? latLonFor({ city: node.city, countryCode: node.countryCode ?? node.country }) : null
	drawRoute(latLonFor(geo), target, online ? phase : 'offline')

	// Numbers.
	//
	// Three honest states per cell: a value, a skeleton ("on its way"), or an
	// em dash ("there is none"). Anything the worker still holds from an earlier
	// session is ignored unless the tunnel is up or being dialled, so a stale IP
	// can never sit in the grid pretending to be current.
	const live = online && phase === 'connected'
	const dialing = online && phase === 'connecting'
	const stats = live || dialing ? (state?.runtime?.stats ?? {}) : {}
	const session = live || dialing ? (state?.runtime?.session ?? {}) : {}
	const stillLoading = (value) => live && (value === null || value === undefined) && connectedAgeMs() < METRIC_SKELETON_MAX_MS
	const publicIp = stats.publicIp ?? null
	renderMetric($('st-public-ip'), {
		value: live && publicIp ? String(publicIp) : DASH,
		loading: dialing || stillLoading(publicIp),
		chars: 15,
	})
	// The VPN address arrives with the connect result itself, so once the
	// tunnel is up there is nothing left to wait for: value or dash.
	const vpnIp = session.vpnIp ?? state?.runtime?.vpnIp ?? null
	renderMetric($('st-vpn-ip'), { value: live && vpnIp ? String(vpnIp) : DASH, loading: dialing, chars: 15 })
	const ping = Number(stats.ping)
	const pingKnown = Number.isFinite(ping) && ping > 0
	renderMetric($('st-ping'), {
		value: live && pingKnown ? pingLabel(ping) : DASH,
		loading: dialing || stillLoading(pingKnown ? ping : null),
		chars: 6,
	})
	renderMetric($('st-rx'), { value: bytesLabel(live ? stats.bytesRx : 0) })
	renderMetric($('st-tx'), { value: bytesLabel(live ? stats.bytesTx : 0) })
	tickDuration()

	// Errors are shown, never swallowed - and no connection at all outranks
	// whatever stale error the worker is still holding.
	if (!online) {
		banner('vpn-banner', t('err.offlineText'), { title: t('err.offlineTitle'), kind: 'bad' })
	} else {
		const error = state?.runtime?.error
		if (error && phase !== 'connected') showError('vpn-banner', error)
		else banner('vpn-banner', '')
	}
	renderProfile()
}

/** Milliseconds since the tunnel came up; 0 when it is not up. */
function connectedAgeMs() {
	const since = Number(state?.runtime?.since ?? state?.runtime?.connectedAt ?? 0)
	return since > 0 ? Math.max(0, Date.now() - since) : 0
}

function tickDuration() {
	const node = $('st-duration')
	if (!node) return
	const phase = phaseOf()
	if (!isOnline()) {
		renderMetric(node, { value: DASH })
		return
	}
	if (phase === 'connecting') {
		renderMetric(node, { loading: true, chars: 8 })
		return
	}
	const since = Number(state?.runtime?.since ?? state?.runtime?.connectedAt ?? 0)
	if (phase !== 'connected' || !since) {
		renderMetric(node, { value: DASH })
		return
	}
	renderMetric(node, { value: durationLabel(Date.now() - since) })
}

/**
 * One metric cell. `loading` paints a shimmering bar about `chars` characters
 * wide instead of a placeholder string; otherwise the value is written as text.
 *
 * The bar is only rebuilt when its size changes. renderVpn runs on every poll
 * and every runtime broadcast, and replacing the node each time restarted the
 * shimmer from zero - a visible stutter every few seconds.
 */
function renderMetric(el, { value = DASH, loading = false, chars = 6 } = {}) {
	if (!el) return
	if (loading) {
		const width = String(Math.max(2, Math.round(Number(chars) || 6)))
		if (el.dataset.skel !== width) {
			const bar = document.createElement('span')
			bar.className = 'skel'
			bar.style.setProperty('--skel-w', `${width}ch`)
			bar.setAttribute('aria-hidden', 'true')
			el.replaceChildren(bar)
			el.dataset.skel = width
		}
		el.setAttribute('aria-busy', 'true')
		return
	}
	if (el.dataset.skel !== undefined) delete el.dataset.skel
	el.removeAttribute('aria-busy')
	const text = value === null || value === undefined || value === '' ? DASH : String(value)
	if (el.textContent !== text) el.textContent = text
}

function renderServers() {
	const list = $('srv-list')
	if (!list) return
	list.textContent = ''
	if (!nodes.length) {
		const empty = document.createElement('div')
		empty.className = 'empty'
		empty.textContent = t('servers.empty')
		list.appendChild(empty)
		return
	}
	const activeId = activeNodeId() || String(activeNode()?.id ?? '')
	nodes.forEach((node, index) => {
		const id = String(node?.id ?? node?.nodeId ?? index)
		const maintenance = node?.maintenance === true || String(node?.status ?? '').toUpperCase() === 'MAINTENANCE'
		const offline = maintenance || node?.online === false || String(node?.status ?? '').toLowerCase() === 'offline'
		const row = document.createElement('button')
		row.type = 'button'
		row.className = 'srv-row' + (id === activeId ? ' active' : '') + (offline ? ' offline' : '') + (maintenance ? ' maintenance' : '')
		row.style.animationDelay = `${Math.min(index, 8) * 26}ms`

		const flag = document.createElement('span')
		flag.className = 'flag-circle sm'
		// Real SVG artwork. The emoji version rendered as nothing on Windows,
		// which is why this column looked empty.
		paintFlag(flag, node?.countryCode ?? node?.country, node?.city)
		row.appendChild(flag)

		const text = document.createElement('span')
		text.className = 's-text'
		const name = document.createElement('span')
		name.className = 's-name'
		const currentLang = resolveLanguage(settings.language, state?.runtime?.geo?.countryCode)
		name.textContent = formatNodeLocation(node, currentLang) || `${node?.city ?? node?.name ?? id}`
		text.appendChild(name)

		const meta = document.createElement('span')
		meta.className = 's-meta'
		if (offline) {
			meta.textContent = maintenance ? t('node.maintenance') : t('node.offline')
		} else {
			const load = Math.max(0, Math.min(100, Math.round(Number(node?.load ?? 0))))
			const bar = document.createElement('span')
			bar.className = 'load-bar' + (load >= 70 ? ' warm' : '')
			const fill = document.createElement('i')
			fill.style.width = `${load}%`
			bar.appendChild(fill)
			meta.appendChild(bar)
			const label = document.createElement('span')
			label.textContent = t('node.load', { n: load })
			meta.appendChild(label)
		}
		text.appendChild(meta)
		const restrictions = Array.isArray(node?.restrictions) ? node.restrictions : []
		if (restrictions.length) {
			const holder = document.createElement('span')
			holder.className = 's-restrictions'
			for (const restriction of restrictions.slice(0, 4)) {
				const chip = document.createElement('span')
				chip.className = 'restriction'
				chip.textContent = restrictionLabel(restriction)
				holder.appendChild(chip)
			}
			text.appendChild(holder)
		}
		row.appendChild(text)

		const sig = document.createElement('span')
		sig.className = `sig l${signalOf(node?.ping)}`
		sig.appendChild(document.createElement('i'))
		sig.appendChild(document.createElement('i'))
		sig.appendChild(document.createElement('i'))
		row.appendChild(sig)

		const ping = document.createElement('span')
		ping.className = 's-ping'
		ping.textContent = pingLabel(node?.ping)
		row.appendChild(ping)

		row.addEventListener('click', () => chooseNode(id, offline))
		list.appendChild(row)
	})
}

/** True while the user is mid-edit, so a poll must not rewrite the box. */
function isEditing(node) {
	return Boolean(node) && document.activeElement === node
}

function renderSettings() {
	const setValue = (id, value) => {
		const node = $(id)
		// Never yank text out from under the cursor, and never undo a value the
		// user set in the last moment.
		if (!node || isEditing(node)) return
		const next = value ?? ''
		if (node.value !== String(next)) node.value = next
	}
	syncSegment('seg-lang', settings.language ?? 'auto')
	syncSegment('seg-tunnel', settings.tunnelMode ?? 'all')
	setSiteFieldVisible((settings.tunnelMode ?? 'all') !== 'all')
	setValue('s-site-list', (settings.siteList ?? []).join('\n'))
	setValue('s-bypass', (settings.bypass ?? []).join('\n'))
	// ROUND 5: the channel switch belongs to admins only. The beta control plane
	// rejects non-admin accounts and has no sign-up, so showing the switch to
	// everyone only ever produced a login failure the user could not fix. Hidden
	// here and enforced on the server, exactly as in the phone and PC clients.
	const isAdmin = isAdminUser()
	// ROUND 12: the five-tap gesture is gone here too.
	//
	// It was deleted from the phone and the PC in round 11, but this folder was
	// gitignored, so the "developer menu" that was supposed to disappear was
	// still five clicks away in the extension. A gesture is not a permission: it
	// let a normal account uncover a switch the beta plane then refuses, while an
	// admin had to know a trick to reach a control they are entitled to.
	//
	// Testers get the channel card as well (the beta plane accepts them), but
	// not the raw API / site overrides below it - those stay admin-only.
	const channelVisible = channelCardVisible()
	const channelField = $('field-channel')
	if (channelField) {
		channelField.classList.toggle('hidden', !channelVisible)
		channelField.hidden = !channelVisible
	}
	// The developer block behind the switch is for administrators: it holds
	// the API host and site host overrides. Hiding the switch but leaving those
	// rows on screen would only move the foot-gun one line down - a normal user
	// who edits "Control API" ends up with a client that talks to nothing, and
	// no way to tell that they are the reason. The body additionally follows
	// its disclosure: re-rendering must not pop a collapsed section open.
	const devButton = $('btn-devmode')
	if (devButton) {
		devButton.classList.toggle('hidden', !isAdmin)
		devButton.hidden = !isAdmin
	}
	const devBody = $('dev-body')
	if (devBody) {
		const showDev = isAdmin && devModeOpen
		devBody.classList.toggle('hidden', !showDev)
		devBody.hidden = !showDev
	}
	renderChannelCard()
	if (channelVisible && view === 'settings') ensureChannelVersions()
	setValue('s-api-base', settings.apiBase?.[settings.channel ?? 'prod'] ?? '')
	setValue('s-site-base', settings.siteBase ?? '')
	setValue('s-gw-host', settings.gateway?.host ?? '')
	setValue('s-gw-port', settings.gateway?.port ?? 8443)
	// ROUND 5: HTTP was removed from the list because the node stopped serving
	// it. An old stored value would otherwise select nothing at all.
	const scheme = settings.gateway?.scheme ?? 'https'
	setValue('s-gw-scheme', scheme === 'http' ? 'https' : scheme)
	toggleSwitch($('sw-auto'), Boolean(settings.autoConnect))
	toggleSwitch($('sw-kill'), Boolean(settings.killSwitch))
	toggleSwitch($('sw-incognito'), Boolean(settings.tunnelIncognito))
	applyI18n()
	renderIncognitoNote()
}

// ----------------------------------------------------------- incognito ----

/**
 * Chrome keeps the real permission behind its own per-extension switch, so the
 * toggle in our settings is only half of the story. This asks Chrome for the
 * other half; the answer is rendered under the toggle row.
 */
function probeIncognitoAccess() {
	return new Promise((resolve) => {
		let done = false
		const finish = (value) => {
			if (done) return
			done = true
			incognitoAllowed = typeof value === 'boolean' ? value : null
			renderIncognitoNote()
			resolve(incognitoAllowed)
		}
		try {
			if (!chrome?.extension?.isAllowedIncognitoAccess) return finish(null)
			// Callback form works on every Chromium that has the API; a promise is
			// only returned when no callback is passed.
			chrome.extension.isAllowedIncognitoAccess((allowed) => {
				void chrome.runtime.lastError
				finish(allowed)
			})
			setTimeout(() => finish(null), 2000)
		} catch {
			finish(null)
		}
	})
}

/** The line under the incognito toggle: permission state + a way to fix it. */
function renderIncognitoNote() {
	const foot = $('incognito-foot')
	const text = $('incognito-state')
	const link = $('btn-incognito-perm')
	if (!foot || !text || !link) return
	const on = Boolean(settings.tunnelIncognito)
	const allowed = incognitoAllowed
	// The link only makes sense while there is something to grant.
	const showLink = allowed !== true
	link.classList.toggle('hidden', !showLink)
	link.hidden = !showLink
	let message = ''
	let cls = 'hint'
	if (allowed === true) {
		message = t('settings.incognitoAllowed')
		cls = 'hint ok'
	} else if (allowed === false && on) {
		// The user asked for incognito but Chrome will not let us in: this is
		// the one state that needs to be loud.
		message = t('settings.incognitoNotAllowed')
		cls = 'hint warn'
	}
	// Class and attribute both, as everywhere in this file: the stylesheet sets
	// display on these nodes, which silently beats the bare `hidden` attribute.
	text.className = cls + (message ? '' : ' hidden')
	text.textContent = message
	text.hidden = !message
	foot.classList.toggle('hidden', !message && !showLink)
	foot.hidden = !message && !showLink
}

function openIncognitoPermission() {
	let id = ''
	try {
		id = String(chrome.runtime.id ?? '')
	} catch {}
	// chrome:// pages cannot be linked from a popup; chrome.tabs.create can
	// open them, and Chrome highlights the extension named by ?id=.
	openUrl(id ? `chrome://extensions/?id=${id}` : 'chrome://extensions/')
}

// ------------------------------------------------------- channel card -----

function isAdminUser() {
	return Boolean(state?.runtime?.user?.isAdmin ?? state?.user?.isAdmin ?? false)
}

/** Older control servers never send isTester; absent means false. */
function isTesterUser() {
	return Boolean(state?.runtime?.user?.isTester ?? state?.user?.isTester ?? false)
}

function channelCardVisible() {
	return isAdminUser() || isTesterUser()
}

function currentChannel() {
	return settings.channel === 'beta' ? 'beta' : 'prod'
}

function channelLabel(channel) {
	return channel === 'beta' ? 'BETA' : 'PRODUCTION'
}

/** The tunnel must be down before the control plane can change under it. */
function tunnelBusy() {
	const phase = phaseOf()
	return phase === 'connected' || phase === 'connecting' || phase === 'disconnecting'
}

function channelBase(channel) {
	const base = String(settings.apiBase?.[channel] ?? DEFAULTS.apiBase[channel] ?? '').trim()
	return base.replace(/\/+$/, '')
}

/**
 * Is a control plane answering on that channel, and which version?
 *
 * Direct GET of /api/version - the API hosts are always in the PAC's direct
 * list, so this works whether or not the tunnel is up. A short deadline: this
 * is a liveness check, not a request that is allowed to keep a switch waiting.
 */
async function probeChannel(channel) {
	const base = channelBase(channel)
	if (!base) return { ok: false, version: null }
	try {
		const response = await fetch(`${base}/api/version`, {
			method: 'GET',
			cache: 'no-store',
			credentials: 'omit',
			headers: { accept: 'application/json' },
			signal: AbortSignal.timeout(CHANNEL_PROBE_TIMEOUT_MS),
		})
		if (!response.ok) return { ok: false, version: null }
		let json = null
		try {
			json = await response.json()
		} catch {
			json = null
		}
		const looksLikeControlPlane =
			json && typeof json === 'object' && (typeof json.channel === 'string' || json.service === 'glukvpn-control')
		if (!looksLikeControlPlane) return { ok: false, version: null }
		const version = String(json.version ?? '').trim()
		return { ok: true, version: version || null }
	} catch {
		return { ok: false, version: null }
	}
}

function rememberChannel(channel, probe) {
	channelInfo[channel] = {
		status: probe.ok ? 'up' : 'down',
		version: probe.ok ? probe.version : null,
		checkedAt: Date.now(),
	}
}

/** Probes both channels, at most once per minute, one flight at a time. */
function ensureChannelVersions(force = false) {
	if (channelProbe) return channelProbe
	const fresh = CHANNELS.every((channel) => Date.now() - channelInfo[channel].checkedAt < CHANNEL_CACHE_MS)
	if (fresh && !force) return Promise.resolve()
	for (const channel of CHANNELS) $(`chan-${channel}`)?.classList.add('busy')
	channelProbe = Promise.all(
		CHANNELS.map(async (channel) => {
			rememberChannel(channel, await probeChannel(channel))
			$(`chan-${channel}`)?.classList.remove('busy')
		}),
	)
		.catch(() => {})
		.finally(() => {
			channelProbe = null
			renderChannelCard()
		})
	return channelProbe
}

function setChannelError(text, kind = 'warn') {
	channelError = text ? { text, kind } : null
	renderChannelCard()
}

function renderChannelCard() {
	if (!$('field-channel')) return
	const current = currentChannel()
	const locked = tunnelBusy()
	for (const channel of CHANNELS) {
		const pill = $(`chan-${channel}`)
		if (!pill) continue
		const on = channel === current
		pill.classList.toggle('on', on)
		pill.classList.toggle('locked', locked)
		pill.setAttribute('aria-pressed', on ? 'true' : 'false')
		pill.setAttribute('aria-disabled', locked ? 'true' : 'false')
		const info = channelInfo[channel]
		const ver = $(`chan-ver-${channel}`)
		if (ver) {
			ver.classList.toggle('up', info.status === 'up')
			ver.classList.toggle('down', info.status === 'down')
			const label = ver.querySelector('.chan-ver-text')
			if (label) {
				label.textContent =
					info.status === 'up' ? (info.version ?? '?')
					: info.status === 'down' ? t('dev.channelOff')
					: '\u2026'
			}
		}
	}
	const status = $('chan-status')
	if (status) {
		const info = channelInfo[current]
		const version = info.status === 'up' && info.version ? info.version : info.status === 'down' ? t('dev.channelOff') : '\u2026'
		status.textContent = t('dev.channelUsing', { channel: channelLabel(current), version })
		status.classList.toggle('beta', current === 'beta')
	}
	const errorLine = $('chan-error')
	if (errorLine) {
		// A live tunnel outranks a stale probe failure: the pills are dimmed,
		// and the line says why.
		const shown = locked ? { text: t('dev.channelDisconnectFirst'), kind: 'warn' } : channelError
		errorLine.textContent = shown?.text ?? ''
		errorLine.classList.toggle('bad', shown?.kind === 'bad')
		errorLine.classList.toggle('hidden', !shown)
		errorLine.hidden = !shown
	}
}

/**
 * PROD <-> BETA.
 *
 * The target is probed first, and nothing changes unless it answers: a switch
 * to a dead channel used to sign the user out and then fail to sign them back
 * in, which read as a broken account rather than as a server that is down.
 */
async function switchChannel(target) {
	if (!CHANNELS.includes(target) || channelSwitching) return
	const from = currentChannel()
	if (target === from) return
	if (tunnelBusy()) {
		setChannelError(t('dev.channelDisconnectFirst'), 'warn')
		return
	}
	channelSwitching = true
	activeMapData = null
	renderAccountMap()
	closeDeviceLimitModal(false)
	setChannelError('')
	const pill = $(`chan-${target}`)
	pill?.classList.add('busy')
	const probe = await probeChannel(target)
	rememberChannel(target, probe)
	pill?.classList.remove('busy')
	if (!probe.ok) {
		channelSwitching = false
		// The pills never moved, so there is nothing to revert visually; the
		// render below just refreshes the version line and shows the reason.
		setChannelError(t(target === 'beta' ? 'dev.channelUnavailableBeta' : 'dev.channelUnavailableProd'), 'bad')
		return
	}

	const previousGateway = { ...(settings.gateway ?? {}) }
	settings.channel = target
	const field = $('s-api-base')
	if (field) field.value = settings.apiBase?.[target] ?? ''
	// Port 8443 is the open gateway in OCI for all channels
	const port = 8443
	settings.gateway = { ...(settings.gateway ?? {}), port }
	const portField = $('s-gw-port')
	if (portField) portField.value = String(port)
	renderChannelCard()
	const saved = await saveSettings()
	if (!saved) {
		// Not persisted, so not switched: put the form back the way it was
		// rather than signing out of a channel we are still on.
		settings.channel = from
		settings.gateway = previousGateway
		if (field) field.value = settings.apiBase?.[from] ?? ''
		if (portField) portField.value = String(previousGateway.port ?? (from === 'beta' ? 8444 : 8443))
		channelSwitching = false
		renderChannelCard()
		return
	}
	// A session belongs to exactly one control plane: a prod refresh token is
	// meaningless on beta and produces 401s that read as a broken account.
	banner('set-banner', t('dev.channelSwitched', { channel: target }), { kind: 'info', title: t('dev.title') })
	try {
		await signOut()
	} finally {
		channelSwitching = false
	}
}

/** "Except these" and "only these" are meaningless without somewhere to type. */
function setSiteFieldVisible(show) {
	const field = $('site-field')
	if (!field) return
	// Both, always. The class carries `display:none !important`, so setting
	// only the attribute left the box invisible no matter what.
	field.classList.toggle('hidden', !show)
	field.hidden = !show
}

function setDisclosure(buttonId, bodyId, open) {
	const button = $(buttonId)
	const body = $(bodyId)
	if (button) {
		button.classList.toggle('open', open)
		button.setAttribute('aria-expanded', open ? 'true' : 'false')
	}
	if (body) {
		body.classList.toggle('open', open)
		body.classList.toggle('hidden', !open)
		body.hidden = !open
	}
}

function syncSegment(id, value) {
	const group = $(id)
	if (!group) return
	let active = null
	for (const button of group.querySelectorAll('button')) {
		const on = button.dataset.value === String(value)
		button.classList.toggle('on', on)
		button.classList.toggle('active', on)
		if (on) active = button
	}
	// The pill is positioned from measurements so it lands on the button no
	// matter how wide the translated label turns out to be.
	const glide = group.querySelector('.seg-glide')
	if (glide && active && active.offsetWidth) {
		glide.style.width = active.offsetWidth + 'px'
		glide.style.transform = 'translateX(' + active.offsetLeft + 'px)'
		glide.style.opacity = '1'
	}
}

function toggleSwitch(node, on) {
	if (!node) return
	node.classList.toggle('on', Boolean(on))
	node.setAttribute('aria-checked', on ? 'true' : 'false')
	node.setAttribute('aria-pressed', on ? 'true' : 'false')
}

// Takes the fetched payload, keeps it, and hands the drawing to paintDevices
// so the arrows can redraw a page without touching the network.
function renderDevices(devices, failure) {
	if (failure) {
		deviceRows = []
		deviceMax = 0
		deviceFailure = failure
	} else {
		const rows = Array.isArray(devices) ? devices : (devices?.devices ?? [])
		deviceRows = rows
		deviceMax = Number(devices?.maxDevices ?? state?.user?.maxDevices ?? 0)
		deviceFailure = ''
		// The control server models DeviceStatus as ACTIVE | REVOKED and returns
		// active rows first. A revoked device must never read as a live one.
		deviceActiveCount = rows.filter((d) => !isRevokedDevice(d)).length
		devicePage = 0
	}
	paintDevices()
}

function isRevokedDevice(d) {
	return String(d?.status ?? '').toUpperCase() === 'REVOKED' || Boolean(d?.revokedAt)
}

/** ROUND 9 (block 4.3): which #seg-devices bucket a row belongs to. */
function matchesDeviceFilter(d) {
	if (deviceFilter === 'active') return !isRevokedDevice(d)
	if (deviceFilter === 'revoked') return isRevokedDevice(d)
	return true
}

function paintDevices() {
	const list = $('dev-list')
	if (!list) return
	list.textContent = ''
	const counter = $('dev-count')
	if (counter) counter.textContent = ''
	if (deviceFailure) {
		list.appendChild(
			calloutNode({ text: deviceFailure, actionLabel: t('settings.devicesRetry'), onAction: () => ensureDevices(true) }),
		)
		return
	}
	// ROUND 9 (block 4.3): #seg-devices has been in the markup since round 5 and
	// never filtered anything - it only moved its own sliding pill. A revoked
	// device read exactly like a live one at a glance, which is the whole reason
	// the three buckets exist.
	syncSegment('seg-devices', deviceFilter)
	if (!deviceRows.length) {
		const empty = document.createElement('div')
		empty.className = 'empty'
		empty.textContent = t('settings.devicesEmpty')
		list.appendChild(empty)
		deviceActiveCount = 0
		return
	}
	const revokedOf = isRevokedDevice
	// The counter describes the account, not the current filter: "1 of 3" has to
	// keep meaning "one device slot used" whichever bucket is on screen.
	const max = deviceMax
	if (counter) counter.textContent = max ? t('dev.limit', { used: deviceActiveCount, max }) : String(deviceActiveCount)

	const rows = deviceRows.filter(matchesDeviceFilter)
	if (!rows.length) {
		const empty = document.createElement('div')
		empty.className = 'empty'
		// Says which bucket is empty. A bare "no devices" under an active filter
		// reads as "your devices are gone".
		empty.textContent = deviceFilter === 'revoked' ? t('devices.emptyRevoked') : t('devices.emptyActive')
		list.appendChild(empty)
		return
	}

	const pageCount = Math.max(1, Math.ceil(rows.length / DEVICES_PER_PAGE))
	devicePage = Math.min(Math.max(0, devicePage), pageCount - 1)
	const from = devicePage * DEVICES_PER_PAGE

	const selfId = String(state?.device?.id ?? '')
	rows.slice(from, from + DEVICES_PER_PAGE).forEach((device, index) => {
		const id = String(device?.id ?? device?.deviceId ?? index)
		const revoked = revokedOf(device)
		const isSelf = device?.isCurrent === true || (selfId !== '' && id === selfId)
		const row = document.createElement('div')
		row.className = 'dev-row' + (revoked ? ' revoked' : '')
		row.style.animationDelay = Math.min(index, 8) * 26 + 'ms'

		const icon = document.createElement('span')
		icon.className = 'd-ic'
		icon.appendChild(materialDeviceIcon(device?.platform))
		row.appendChild(icon)

		const text = document.createElement('span')
		text.className = 'd-text'
		const name = document.createElement('span')
		name.className = 'd-name'
		name.textContent = device?.deviceName ?? device?.name ?? device?.platform ?? id
		text.appendChild(name)
		const sub = document.createElement('span')
		sub.className = 'd-sub'
		const bits = []
		if (device?.platform) bits.push(String(device.platform))
		if (revoked) bits.push(t('dev.revoked'))
		else if (device?.connected) bits.push(device?.connectedNode?.name ? t('dev.online') + ' \u00b7 ' + device.connectedNode.name : t('dev.online'))
		else bits.push(t('dev.lastSeen', { when: whenLabel(device?.lastSeen) }))
		sub.textContent = bits.join(' \u00b7 ')
		text.appendChild(sub)
		row.appendChild(text)

		const badge = document.createElement('span')
		badge.className = 'dev-badge' + (revoked ? ' revoked' : isSelf ? ' self' : '')
		badge.textContent = revoked ? t('dev.revoked') : isSelf ? t('dev.thisDevice') : t('dev.active')
		row.appendChild(badge)

		// Revoking an already revoked device is a no-op the API rejects anyway.
		if (!revoked && !isSelf) {
			const revoke = document.createElement('button')
			revoke.type = 'button'
			revoke.className = 'link-btn'
			revoke.textContent = t('settings.revoke')
			revoke.addEventListener('click', () => revokeDevice(id))
			row.appendChild(revoke)
		}
		list.appendChild(row)
	})

	if (pageCount > 1) list.appendChild(devicePagerNode(pageCount))
}

/** Arrows around a "1 of 3" counter. Only drawn when there is a second page. */
function devicePagerNode(pageCount) {
	const pager = document.createElement('div')
	pager.className = 'pager'

	const step = (delta, label, icon, disabled) => {
		const button = document.createElement('button')
		button.type = 'button'
		button.className = 'pager-btn'
		button.disabled = disabled
		button.setAttribute('aria-label', label)
		button.appendChild(iconSvg(icon))
		button.addEventListener('click', () => {
			devicePage = Math.min(Math.max(0, devicePage + delta), pageCount - 1)
			paintDevices()
		})
		return button
	}

	pager.appendChild(step(-1, t('dev.prevPage'), 'back', devicePage <= 0))

	const info = document.createElement('span')
	info.className = 'pager-info'
	info.textContent = t('dev.page', { page: devicePage + 1, total: pageCount })
	pager.appendChild(info)

	pager.appendChild(step(1, t('dev.nextPage'), 'chevron', devicePage >= pageCount - 1))

	return pager
}

/** The profile screen mirrors the Flutter "My profile" page. */
function displayPlan(sub) {
 const code=String(sub?.plan||sub?.planName||'').toLowerCase().replace(/[\s_-]/g,'');
 const base=code.includes('pro')?'Pro':code.includes('basic')?'Basic':code.includes('free')?'Free':'—';
 return /beta|β/.test(code)&&base!=='—'?'β '+base:base;
}
function renderProfile() {
	const user = state?.user ?? null
	const sub = state?.subscription ?? null
	const name = user?.username ?? user?.email ?? user?.name ?? ''
	const set = (id, value) => {
		const node = $(id)
		if (node) node.textContent = value
	}
	set('prof-name', name || '\u2014')
	const initial = $('prof-initial')
	if (initial) initial.textContent = (name || '?').trim().charAt(0).toUpperCase() || '?'

	const status = String(sub?.status ?? '').toUpperCase()
	const label =
		status === 'ACTIVE' ? t('profile.active')
		: status === 'EXPIRED' ? t('profile.expired')
		: status === 'DISABLED' ? t('profile.disabled')
		: t('profile.noSub')
	const chip = $('prof-chip')
	if (chip) {
		chip.textContent = displayPlan(sub)
		chip.className = 'prof-chip plan-badge'
	}
	set('prof-status', label)
	set('prof-plan', displayPlan(sub))
	const until = sub?.expiresAt ? new Date(sub.expiresAt) : null
	set('prof-expires', until && Number.isFinite(until.getTime()) ? until.toLocaleDateString() : status === 'ACTIVE' ? t('profile.unlimited') : '\u2014')
	const max = Number(user?.maxDevices ?? 0)
	set('prof-devices', max ? t('dev.limit', { used: deviceActiveCount, max }) : String(deviceActiveCount || '\u2014'))
}

/**
 * Signed out means one screen and one screen only: the login screen.
 *
 * The element carries both `class="hidden"` and the `hidden` attribute, and
 * `.hidden` is `display:none !important`. Flipping only the attribute - which
 * is what used to happen - left the login screen permanently invisible, so a
 * signed-out popup showed an empty VPN tab instead.
 */
function showLogin(show) {
	const screen = $('screen-login')
	const app = $('app')
	if (screen) {
		screen.classList.toggle('hidden', !show)
		screen.hidden = !show
	}
	if (app) {
		app.classList.toggle('behind', Boolean(show))
		app.setAttribute('aria-hidden', show ? 'true' : 'false')
	}
	document.body.classList.toggle('signed-out', Boolean(show))
	if (!show) return
	setLoginMode(loginMode)
}

/** Password or website - both are always one click away. */
function setLoginMode(mode) {
	loginMode = mode === 'password' ? 'password' : 'site'
	const site = $('login-site')
	const pwd = $('login-password')
	if (site) {
		site.classList.toggle('hidden', loginMode !== 'site')
		site.hidden = loginMode !== 'site'
	}
	if (pwd) {
		pwd.classList.toggle('hidden', loginMode !== 'password')
		pwd.hidden = loginMode !== 'password'
	}
	requestAnimationFrame(() => syncSegment('seg-login', loginMode))
}

function applyState(next) {
	if (next && typeof next === 'object') state = next
	const incoming = state?.settings
	// While a save is in flight - or has only just landed - the worker still
	// reports the previous values. Applying them here is exactly what made
	// every toggle snap back to its old position a second later.
	const accepting = !savePending && Date.now() >= saveGuardUntil
	if (incoming && typeof incoming === 'object' && accepting) {
		settings = {
			...DEFAULTS,
			...incoming,
			apiBase: { ...DEFAULTS.apiBase, ...(incoming.apiBase ?? {}) },
			gateway: { ...DEFAULTS.gateway, ...(incoming.gateway ?? {}) },
			bypass: Array.isArray(incoming.bypass) ? incoming.bypass : DEFAULTS.bypass,
			siteList: Array.isArray(incoming.siteList) ? incoming.siteList : [],
		}
	}
	setLanguage(settings.language)
	document.documentElement.lang = settings.language === 'auto' ? document.documentElement.lang : settings.language
	if (Array.isArray(state?.nodes) && state.nodes.length) {
		nodes = state.nodes
		cacheNodes(nodes)
	}
	// The worker is authoritative once a real phase arrives.
	if (state?.runtime?.phase) localPhase = null
	const account = state?.user ?? null
	const name = account?.username ?? account?.email ?? account?.name ?? ''
	const acctName = $('acct-name')
	if (acctName) acctName.textContent = name || t('nav.profile')
	const initial = $('acct-initial')
	if (initial) initial.textContent = (name || '?').trim().charAt(0).toUpperCase() || '?'
	applyI18n()
	renderSettings()
	renderVpn()
	renderServers()
	showLogin(state?.signedIn === false)
}

// -------------------------------------------------------------- data loads --

function cacheNodes(list) {
	try {
		localStorage.setItem(NODES_CACHE, JSON.stringify(list))
	} catch {}
}

function cachedNodes() {
	try {
		const raw = localStorage.getItem(NODES_CACHE)
		const parsed = raw ? JSON.parse(raw) : null
		return Array.isArray(parsed) ? parsed : []
	} catch {
		return []
	}
}

/** Loads the server list. Failure keeps whatever is on screen and offers a retry. */
async function ensureNodes(force = false) {
	if (nodes.length && !force) {
		banner('srv-banner', '')
		return
	}
	const button = $('btn-refresh')
	button?.classList.add('spinning')
	if (!nodes.length) {
		const list = $('srv-list')
		if (list && !list.childElementCount) {
			const loading = document.createElement('div')
			loading.className = 'empty'
			loading.textContent = t('servers.loading')
			list.appendChild(loading)
		}
	}
	const response = await call('refreshNodes')
	button?.classList.remove('spinning')
	const list = response?.nodes ?? response?.data?.nodes ?? response?.items
	if (response?.ok && Array.isArray(list) && list.length) {
		nodes = list
		cacheNodes(nodes)
		banner('srv-banner', '')
		renderServers()
		return
	}
	if (response?.ok && Array.isArray(list)) {
		nodes = list
		banner('srv-banner', '')
		renderServers()
		return
	}
	// Failed. Fall back to the last known list rather than an empty screen.
	if (!nodes.length) nodes = cachedNodes()
	renderServers()
	banner('srv-banner', nodes.length ? t('servers.cached') : humanError(response), {
		title: t('servers.failed'),
		kind: nodes.length ? 'warn' : 'bad',
		actionLabel: t('servers.retry'),
		onAction: () => ensureNodes(true),
	})
}

let devicesLoaded = false

async function ensureDevices(force = false) {
	if (devicesLoaded && !force) return
	if (state?.signedIn === false) {
		renderDevices([], null)
		return
	}
	devicesLoaded = true
	const response = await call('devices')
	const list = response?.devices ?? response?.items ?? response?.results ?? response?.data?.devices
	if (response?.ok && Array.isArray(list)) {
		renderDevices(list, null)
		return
	}
	devicesLoaded = false
	renderDevices(null, `${t('settings.devicesFailed')} ${humanError(response)}`)
}

/** Pulls fresh state. A failure never blanks the UI - it adds a banner. */
async function refreshState({ quiet = false } = {}) {
	const response = await call('getState')
	if (response?.ok) {
		const next = response.state ?? response.data ?? response
		applyState(next)
		if (!quiet) banner('vpn-banner', state?.runtime?.error ? humanError({ error: state.runtime.error }) : '', { title: t('err.connectTitle') })
		return true
	}
	// Keep the last known screen. Never wipe the settings form.
	if (!state) {
		applyState({ settings: { ...DEFAULTS }, signedIn: true, runtime: null, nodes: cachedNodes() })
	}
	if (!quiet) {
		banner('vpn-banner', humanError(response), { actionLabel: t('common.retry'), onAction: () => refreshState() })
		banner('set-banner', humanError(response), { actionLabel: t('common.retry'), onAction: () => refreshState() })
	}
	return false
}

// ---------------------------------------------------------------- actions ---

function markBusy(on) {
	busySince = on ? Date.now() : 0
}

function isBusy() {
	// A stuck flag is worse than a double click: it expires by itself.
	return busySince > 0 && Date.now() - busySince < 25000
}

function clearWatchdog() {
	if (connectWatchdog) clearTimeout(connectWatchdog)
	connectWatchdog = null
}

async function togglePower() {
	const phase = phaseOf()
	if (state?.signedIn === false) {
		showLogin(true)
		return
	}
	const going = phase === 'connected' || phase === 'connecting'
	// No link, no attempt, no animation. Pretending to dial on a dead network
	// is the bug, not the missing spinner.
	if (!going && !isOnline()) {
		localPhase = null
		renderVpn()
		banner('vpn-banner', t('err.offlineText'), { title: t('err.offlineTitle') })
		return
	}
	if (isBusy()) return
	markBusy(true)
	banner('vpn-banner', '')
	try {
		if (!going) {
			// Optimistic feedback so the button never feels dead - but it is now
			// on a leash: if nothing comes back, it becomes an error instead of
			// spinning until the popup is closed.
			localPhase = 'connecting'
			// Numbers from the previous session are not "this" session's: drop
			// them now so the grid shows skeletons, never a stale address.
			state = {
				...(state ?? {}),
				runtime: { ...(state?.runtime ?? {}), phase: 'connecting', error: null, stats: null, session: null, connectedAt: null },
			}
			renderVpn()
			clearWatchdog()
			connectWatchdog = setTimeout(() => {
				if (phaseOf() !== 'connecting') return
				localPhase = 'error'
				markBusy(false)
				renderVpn()
				banner('vpn-banner', t('err.connectTimeoutText'), {
					title: t('err.connectTitle'),
					actionLabel: t('common.retry'),
					onAction: () => togglePower(),
				})
			}, CONNECT_WATCHDOG_MS)
		}
		// Auto picks the target when the user never chose one, so a power click
		// no longer means "whatever came first in the list".
		const nodeId = activeNodeId() || activeNode()?.id || nodes[0]?.id || null
		const response = going ? await call('disconnect', { silent: false }) : await call('connect', nodeId ? { nodeId } : {})
		clearWatchdog()
		if (!response?.ok) {
			localPhase = 'error'
			renderVpn()
			if (isDeviceLimit(response) || normalizedError(response).code === 'maintenance') showError('vpn-banner', response)
			else banner('vpn-banner', humanError(response), {
				title: t('err.connectTitle'),
				actionLabel: t('common.retry'),
				onAction: () => togglePower(),
			})
		} else {
			localPhase = null
		}
	} finally {
		markBusy(false)
		await refreshState({ quiet: true })
	}
}

async function chooseNode(nodeId, offline) {
	if (offline) return
	const response = await call('selectNode', { nodeId })
	if (!response?.ok) {
		banner('srv-banner', humanError(response), { actionLabel: t('common.retry'), onAction: () => chooseNode(nodeId, false) })
		return
	}
	banner('srv-banner', '')
	await refreshState({ quiet: true })
	setView('vpn')
	// Selecting a server while connected should move the tunnel there.
	if (phaseOf() === 'connected') {
		markBusy(true)
		const reconnect = await call('connect', { nodeId })
		markBusy(false)
		if (!reconnect?.ok) banner('vpn-banner', humanError(reconnect), { title: t('err.connectTitle') })
		await refreshState({ quiet: true })
	}
}

function linesOf(id) {
	return String($(id)?.value ?? '')
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean)
}

function buildSettingsPatch() {
	// The channel is owned by the PROD/BETA card, which only writes it after the
	// target has answered - so the in-memory value is the truth here.
	const channel = currentChannel()
	return {
		channel,
		apiBase: { ...settings.apiBase, [channel]: String($('s-api-base')?.value ?? '').trim() || settings.apiBase?.[channel] },
		siteBase: String($('s-site-base')?.value ?? '').trim() || settings.siteBase,
		gateway: {
			host: String($('s-gw-host')?.value ?? '').trim(),
			port: Number($('s-gw-port')?.value) || 8443,
			scheme: $('s-gw-scheme')?.value ?? 'https',
		},
		bypass: linesOf('s-bypass'),
		siteList: linesOf('s-site-list'),
		tunnelMode: settings.tunnelMode ?? 'all',
		language: settings.language ?? 'auto',
		autoConnect: Boolean(settings.autoConnect),
		killSwitch: Boolean(settings.killSwitch),
		tunnelIncognito: Boolean(settings.tunnelIncognito),
		preferredNodeId: settings.preferredNodeId ?? null,
	}
}

function setSaveState(kind, text) {
	const node = $('save-state')
	if (!node) return
	clearTimeout(saveStateTimer)
	node.className = 'save-state' + (kind ? ' ' + kind : '')
	node.textContent = text ?? ''
	if (kind === 'ok') saveStateTimer = setTimeout(() => setSaveState('', ''), 1600)
}

/**
 * Debounced write-through. Every control calls this the moment it changes.
 *
 * This is the whole "settings do not save" bug: the switches and segments only
 * mutated the in-memory object, the text fields had no listener at all, and
 * the one function that did persist was bound to a #btn-save button that does
 * not exist in the markup. Five seconds later the poll rebuilt `settings` from
 * storage and every change vanished.
 */
function queueSave() {
	setSaveState('busy', t('settings.saving'))
	// Hold off the poll for the whole debounce window plus the round trip.
	saveGuardUntil = Date.now() + SAVE_DEBOUNCE_MS + 2500
	clearTimeout(saveTimer)
	saveTimer = setTimeout(() => {
		saveSettings()
	}, SAVE_DEBOUNCE_MS)
}

async function saveSettings() {
	clearTimeout(saveTimer)
	const patch = buildSettingsPatch()
	// Keep the local copy authoritative straight away so nothing can flicker
	// back while the write is in flight.
	settings = { ...settings, ...patch }
	savePending = true
	let response
	try {
		response = await call('saveSettings', patch)
	} finally {
		savePending = false
		saveGuardUntil = Date.now() + 1200
	}
	if (!response?.ok) {
		setSaveState('bad', t('settings.saveFailedShort'))
		banner('set-banner', humanError(response), {
			title: t('settings.saveFailed'),
			actionLabel: t('common.retry'),
			onAction: saveSettings,
		})
		return false
	}
	banner('set-banner', '')
	setSaveState('ok', t('settings.saved'))
	await refreshState({ quiet: true })
	return true
}

async function resetSettings() {
	clearTimeout(saveTimer)
	const response = await call('resetSettings')
	if (!response?.ok) {
		banner('set-banner', humanError(response), { actionLabel: t('common.retry'), onAction: resetSettings })
		return
	}
	banner('set-banner', '')
	saveGuardUntil = 0
	savePending = false
	setSaveState('ok', t('settings.resetDone'))
	await refreshState()
}

async function testGateway() {
	const host = String($('s-gw-host')?.value ?? '').trim()
	const result = $('gw-result')
	if (!host) {
		if (result) {
			result.className = 'hint bad'
			result.textContent = t('settings.enterHost')
		}
		return
	}
	if (result) {
		result.className = 'hint'
		result.textContent = t('settings.probing')
	}
	const gateway = { host, port: Number($('s-gw-port')?.value) || 8443, scheme: $('s-gw-scheme')?.value ?? 'https' }
	const response = await call('testGateway', { gateway })
	if (!result) return
	if (response?.ok) {
		result.className = 'hint ok'
		result.textContent = t('settings.reachable', { ms: Math.round(Number(response.data?.ping ?? response.ping ?? 0)) })
	} else {
		result.className = 'hint bad'
		result.textContent = `${t('settings.unreachable')} ${humanError(response)}`
	}
}

async function revokeDevice(deviceId) {
	const response = await call('revokeDevice', { deviceId })
	if (!response?.ok) {
		banner('set-banner', humanError(response))
		return
	}
	await ensureDevices(true)
}

async function signOut() {
	await call('logout')
	activeMapData = null
	renderAccountMap()
	closeDeviceLimitModal(false)
	devicesLoaded = false
	localPhase = null
	await refreshState()
	// Signing out lands on the login screen, exactly like it used to.
	showLogin(true)
}

async function submitLogin() {
	const identifier = String($('identifier')?.value ?? '').trim()
	const password = String($('password')?.value ?? '')
	if (!identifier || !password) {
		banner('login-banner', t('login.needBoth'))
		return
	}
	if (!isOnline()) {
		banner('login-banner', t('err.offlineText'), { title: t('err.offlineTitle') })
		return
	}
	const button = $('btn-login')
	if (button) {
		button.disabled = true
		button.textContent = t('login.submitting')
	}
	const response = await call('login', { identifier, password })
	if (button) {
		button.disabled = false
		button.textContent = t('login.submit')
	}
	if (!response?.ok) {
		banner('login-banner', humanError(response), { title: t('login.failed') })
		return
	}
	banner('login-banner', '')
	devicesLoaded = false
	await refreshState()
}

async function siteLogin() {
	const button = $('btn-site-login')
	if (button) button.disabled = true
	banner('login-banner', t('login.opened'), { kind: 'info', title: t('login.waiting') })
	const response = await call('linkWithSite')
	if (!response?.ok) {
		if (button) button.disabled = false
		banner('login-banner', humanError(response), { title: t('login.openFailed') })
		return
	}
	// Showing the code matters: it is how the user checks that the page in front
	// of them is approving *this* browser and not a request someone else started.
	if (response.userCode) {
		banner('login-banner', `${t('login.opened')} · ${response.userCode}`, {
			kind: 'info',
			title: t('login.waiting'),
		})
	}
	// The server keeps the code alive for five minutes; wait exactly that long.
	// The worker keeps polling on an alarm even after this popup closes, so
	// giving up here only ends the animation, never the sign-in.
	const deadline = Date.now() + 300000
	while (Date.now() < deadline) {
		await sleep(1500)
		await refreshState({ quiet: true })
		if (state?.signedIn) break
		const failure = state?.runtime?.error
		if (failure?.code === 'link_denied' || failure?.code === 'link_expired') {
			if (button) button.disabled = false
			banner('login-banner', failure.message, { title: t('login.openFailed') })
			return
		}
		if (!state?.runtime?.link) break
	}
	if (button) button.disabled = false
	if (state?.signedIn) {
		banner('login-banner', '')
		setView('vpn')
	}
}

// ------------------------------------------------------- round 9 additions --

function openUrl(url) {
	try {
		if (chrome?.tabs?.create) {
			chrome.tabs.create({ url })
			return
		}
	} catch {}
	try {
		window.open(url, '_blank', 'noopener')
	} catch {}
}

/** Opens a path on the configured site, honouring the developer override. */
function openSite(path) {
	const base = String(settings.siteBase ?? DEFAULTS.siteBase).replace(/\/+$/, '')
	openUrl(base + path)
}

function ownVersion() {
	try {
		return String(chrome.runtime.getManifest().version ?? '')
	} catch {
		return ''
	}
}

/** "1.5.0" against "1.6.0", without pulling in a semver library. */
function isNewer(candidate, current) {
	const parse = (v) => String(v ?? '').split(/[.\-+]/).map((part) => Number.parseInt(part, 10) || 0)
	const a = parse(candidate)
	const b = parse(current)
	for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
		const left = a[i] ?? 0
		const right = b[i] ?? 0
		if (left !== right) return left > right
	}
	return false
}

/**
 * ROUND 9 (block 4.4): tells the user a newer build exists.
 *
 * This extension is distributed as a CRX from our own site, not through the
 * store, so Chrome will never update it on its own. Without this the user
 * simply never finds out. It is the least important thing on screen, so a
 * failed check is silent - an update notice must never turn into an error.
 */
async function checkExtensionUpdate() {
	const current = ownVersion()
	if (!current) return
	const base = String(settings.siteBase ?? DEFAULTS.siteBase).replace(/\/+$/, '')
	let manifest = null
	try {
		const response = await fetch(base + '/api/version.json', { cache: 'no-store' })
		if (!response.ok) return
		manifest = await response.json()
	} catch {
		return
	}
	const entry = manifest?.extension ?? manifest?.chrome ?? null
	const latest = String(entry?.version ?? '')
	if (!latest || !isNewer(latest, current)) return
	const raw = String(entry?.url ?? entry?.download ?? '') || '/download/'
	banner('update-banner', t('update.text', { version: latest, current }), {
		kind: 'info',
		title: t('update.title'),
		actionLabel: t('update.action'),
		onAction: () => openUrl(raw.startsWith('http') ? raw : base + raw),
	})
}

// ------------------------------------------------------------------- wiring -

function wire() {
	// The account chip is a tab, not a shortcut: it selects the profile view
	// and lights up in the rail like every other entry.
	for (const item of document.querySelectorAll('.nav-item')) {
		item.addEventListener('click', () => setView(item.dataset.view))
	}
	$('btn-power')?.addEventListener('click', togglePower)
	$('btn-servers-jump')?.addEventListener('click', () => setView('servers'))
	$('btn-refresh')?.addEventListener('click', () => ensureNodes(true))
	$('rail-brand')?.addEventListener('click', () => setView('vpn'))

	$('seg-lang')?.addEventListener('click', (event) => {
		const button = event.target.closest('button')
		if (!button) return
		settings.language = button.dataset.value
		setLanguage(settings.language)
		syncSegment('seg-lang', settings.language)
		applyI18n()
		renderVpn()
		renderServers()
		renderSettings()
		queueSave()
	})

	$('seg-tunnel')?.addEventListener('click', (event) => {
		const button = event.target.closest('button')
		if (!button) return
		settings.tunnelMode = button.dataset.value
		syncSegment('seg-tunnel', settings.tunnelMode)
		setSiteFieldVisible(settings.tunnelMode !== 'all')
		applyI18n()
		queueSave()
		if (settings.tunnelMode !== 'all') $('s-site-list')?.focus()
	})

	$('sw-auto')?.addEventListener('click', () => {
		settings.autoConnect = !settings.autoConnect
		toggleSwitch($('sw-auto'), settings.autoConnect)
		queueSave()
	})
	$('sw-kill')?.addEventListener('click', () => {
		settings.killSwitch = !settings.killSwitch
		toggleSwitch($('sw-kill'), settings.killSwitch)
		queueSave()
	})
	// Saving is enough to make this live: the worker re-applies the proxy
	// settings, scopes included, whenever settings change while connected.
	$('sw-incognito')?.addEventListener('click', () => {
		settings.tunnelIncognito = !settings.tunnelIncognito
		toggleSwitch($('sw-incognito'), settings.tunnelIncognito)
		renderIncognitoNote()
		queueSave()
		// The user may have just flipped Chrome's own switch and come back.
		probeIncognitoAccess()
	})
	$('btn-incognito-perm')?.addEventListener('click', openIncognitoPermission)

	// PROD / BETA. The handler probes the target before anything is changed;
	// see switchChannel for the order of operations.
	for (const channel of CHANNELS) {
		$(`chan-${channel}`)?.addEventListener('click', () => switchChannel(channel))
	}

	// ROUND 9 (block 4.3): the device filter finally does something.
	$('seg-devices')?.addEventListener('click', (event) => {
		const button = event.target.closest('button')
		if (!button) return
		deviceFilter = button.dataset.value ?? 'all'
		devicePage = 0
		paintDevices()
	})

	// Everything that holds a value writes through. Text areas and inputs save
	// as you type (debounced) and again on blur, selects on change.
	for (const id of ['s-gw-scheme']) {
		$(id)?.addEventListener('change', queueSave)
	}
	for (const id of ['s-site-list', 's-bypass', 's-api-base', 's-site-base', 's-gw-host', 's-gw-port']) {
		const node = $(id)
		if (!node) continue
		node.addEventListener('input', queueSave)
		node.addEventListener('change', queueSave)
		node.addEventListener('blur', () => saveSettings())
	}

	$('btn-advanced')?.addEventListener('click', () => {
		advancedOpen = !advancedOpen
		setDisclosure('btn-advanced', 'advanced-body', advancedOpen)
	})
	$('btn-devmode')?.addEventListener('click', () => {
		devModeOpen = !devModeOpen
		setDisclosure('btn-devmode', 'dev-body', devModeOpen)
	})

	$('btn-test-gw')?.addEventListener('click', testGateway)
	$('btn-reset')?.addEventListener('click', resetSettings)
	$('btn-signout')?.addEventListener('click', signOut)
	$('btn-login')?.addEventListener('click', submitLogin)
	$('btn-site-login')?.addEventListener('click', siteLogin)
	$('limit-close')?.addEventListener('click', () => closeDeviceLimitModal(true))
	$('limit-server')?.addEventListener('click', () => { closeDeviceLimitModal(true); setView('servers') })
	$('limit-retry')?.addEventListener('click', async () => {
		const result = await call('retryPendingConnect')
		if (result?.ok || result?.code === 'no_pending_connect') { closeDeviceLimitModal(false); await refreshState({ quiet: true }) }
		else if (isDeviceLimit(result)) openDeviceLimitModal(result)
		else $('limit-error').textContent = humanError(result)
	})
	document.addEventListener('keydown', (event) => {
		const modal = $('limit-modal')
		if (event.key === 'Escape' && modal && !modal.hidden) closeDeviceLimitModal(true)
	})
	// ROUND 9 (block 4.1)
	$('btn-register')?.addEventListener('click', () => openSite('/login/?mode=register'))
	$('btn-forgot')?.addEventListener('click', () => openSite('/login/?mode=recover'))
	$('seg-login')?.addEventListener('click', (event) => {
		const button = event.target.closest('button')
		if (!button) return
		setLoginMode(button.dataset.value)
	})
	$('identifier')?.addEventListener('keydown', (event) => {
		if (event.key === 'Enter') $('password')?.focus()
	})
	$('password')?.addEventListener('keydown', (event) => {
		if (event.key === 'Enter') submitLogin()
	})
	$('btn-pwd-toggle')?.addEventListener('click', () => {
		const field = $('password')
		if (!field) return
		const show = field.type === 'password'
		field.type = show ? 'text' : 'password'
		const button = $('btn-pwd-toggle')
		if (button) button.textContent = show ? t('login.hide') : t('login.show')
	})

	// Losing the link mid-session must stop the animation immediately, not at
	// the next five-second poll.
	window.addEventListener('online', () => {
		renderVpn()
		refreshState({ quiet: true })
	})
	window.addEventListener('offline', () => {
		clearWatchdog()
		if (localPhase === 'connecting') localPhase = 'error'
		markBusy(false)
		renderVpn()
	})

	// A pending debounce must not be lost when the popup closes.
	window.addEventListener('blur', () => {
		if (saveTimer) saveSettings()
	})

	try {
		chrome.runtime.onMessage.addListener((message) => {
			if (!message || typeof message !== 'object') return
			if (message.type === 'state' || message.type === 'runtime') {
				const runtime = message.runtime ?? message.payload ?? null
				if (runtime) {
					if (runtime.phase) {
						localPhase = null
						clearWatchdog()
					}
					state = { ...(state ?? {}), runtime }
					renderVpn()
				}
			}
		})
	} catch {}
}

async function boot() {
	paintIcons()
	setLanguage('auto')
	applyI18n()
	wire()
	setView('vpn')
	setDisclosure('btn-advanced', 'advanced-body', false)
	setDisclosure('btn-devmode', 'dev-body', false)
	syncGlide()
	// Show the cached list immediately so the servers tab is never empty while
	// the worker wakes up.
	nodes = cachedNodes()
	renderServers()
	// Asked once up front so the incognito row can render its state the moment
	// Settings is opened, instead of flashing from "unknown" to an answer.
	probeIncognitoAccess()
	await refreshState()
	paintIcons()
	if (!nodes.length) ensureNodes()
	// The version line carries the real manifest version rather than a hard-coded
	// string that goes stale on the next release. ROUND 12: it is no longer a door
	// to anything - the developer block is admin-gated instead of hidden behind a
	// gesture.
	const versionButton = $('btn-version')
	if (versionButton) versionButton.textContent = 'GlukVPN ' + (ownVersion() || '\u2014')
	// Fire and forget: an update notice must never delay the popup.
	checkExtensionUpdate()
	tickTimer = setInterval(tickDuration, 1000)
	refreshServiceAndMap()
	pollTimer = setInterval(() => {
		refreshState({ quiet: true })
		refreshServiceAndMap()
	}, 5000)
	window.addEventListener('unload', () => {
		clearInterval(tickTimer)
		clearInterval(pollTimer)
		clearWatchdog()
	})
}

// A crash during boot used to leave a blank popup with no explanation.
boot().catch((error) => {
	banner('vpn-banner', String(error?.message ?? error), { actionLabel: t('common.retry'), onAction: () => location.reload() })
})


// ---------------- Sprint 2: device slots, account map and service state -----
function limitFingerprint(error) {
	const ids = (error?.details?.devices ?? []).map((d) => d?.id).filter(Boolean).sort().join(',')
	return `${error?.code}:${error?.details?.maxDevices ?? ''}:${ids}`
}

function closeDeviceLimitModal(dismiss = true) {
	const modal = $('limit-modal')
	if (!modal) return
	if (dismiss) dismissedLimitFingerprint = limitModalFingerprint
	modal.hidden = true
	modal.classList.add('hidden')
	$('app')?.removeAttribute('inert')
}

function renderLimitDevices(devices) {
	const list = $('limit-devices')
	if (!list) return
	list.replaceChildren()
	for (const device of (devices ?? [])) {
		const id = String(device?.id ?? device?.deviceId ?? '')
		if (!id) continue
		const row = document.createElement('div')
		row.className = 'modal-device'
		const icon = document.createElement('span')
		icon.className = 'd-ic'
		icon.appendChild(materialDeviceIcon(device?.platform))
		row.appendChild(icon)
		const text = document.createElement('span')
		text.className = 'd-text'
		const name = document.createElement('span')
		name.className = 'd-name'
		name.textContent = device?.deviceName ?? device?.name ?? device?.platform ?? id
		const sub = document.createElement('span')
		sub.className = 'd-sub'
		const node = device?.connectedNode
		const where = node ? [node.city, node.country || node.name].filter(Boolean).join(', ') : ''
		sub.textContent = [device?.platform, device?.connected ? t('dev.online') : t('dev.lastSeen', { when: whenLabel(device?.lastSeen) }), where, device?.status].filter(Boolean).join(' · ')
		text.append(name, sub)
		row.appendChild(text)
		const release = document.createElement('button')
		release.type = 'button'
		release.className = 'btn btn-danger'
		release.textContent = t('limit.release')
		release.addEventListener('click', async () => {
			release.disabled = true
			$('limit-error').textContent = ''
			const response = await call('revokeDevice', { deviceId: id })
			if (!response?.ok) {
				release.disabled = false
				$('limit-error').textContent = humanError(response)
				return
			}
			if (device?.isCurrent || String(state?.device?.id ?? '') === id) {
				closeDeviceLimitModal(false)
				activeMapData = null
				renderAccountMap()
				await refreshState()
				return
			}
			const resumed = await call('retryPendingConnect')
			if (resumed?.ok || resumed?.code === 'no_pending_connect') {
				closeDeviceLimitModal(false)
				dismissedLimitFingerprint = ''
				await refreshState({ quiet: true })
			} else if (isDeviceLimit(resumed)) {
				limitModalError = normalizedError(resumed)
				renderLimitDevices(limitModalError.details?.devices ?? [])
				$('limit-error').textContent = t('limit.stillFull')
			} else {
				$('limit-error').textContent = humanError(resumed)
				release.disabled = false
			}
		})
		row.appendChild(release)
		list.appendChild(row)
	}
	if (!list.childElementCount) {
		const empty = document.createElement('div')
		empty.className = 'empty'
		empty.textContent = t('settings.devicesEmpty')
		list.appendChild(empty)
	}
}

async function openDeviceLimitModal(error) {
	if (!isDeviceLimit(error)) return
	limitModalError = normalizedError(error)
	limitModalFingerprint = limitFingerprint(limitModalError)
	if (dismissedLimitFingerprint === limitModalFingerprint) return
	let devices = limitModalError.details?.devices
	if (!Array.isArray(devices) || !devices.length) {
		const response = await call('devices')
		devices = response?.data?.devices ?? response?.devices ?? []
	}
	renderLimitDevices(devices)
	const modal = $('limit-modal')
	if (!modal) return
	modal.hidden = false
	modal.classList.remove('hidden')
	$('app')?.setAttribute('inert', '')
	requestAnimationFrame(() => modal.querySelector('.modal-card')?.focus())
}

function renderAccountMap() {
  if(!activeMapData)activeMapRevision++
	const group = $('account-map')
	const count = $('map-count')
	if (!group || !count) return
	group.replaceChildren()
	const devices = state?.signedIn === false ? [] : (activeMapData?.devices ?? []).filter(d=>d.status==='ACTIVE')
	let placed = 0
	for (const device of devices) {
		const origin = device?.origin
		const location = device?.node?.location
		if (![origin?.lat, origin?.lon, location?.lat, location?.lon].every(Number.isFinite)) continue
		const a = project(origin.lat, origin.lon)
		const b = project(location.lat, location.lon)
		// Дуга поднимается пропорционально расстоянию, а не на фиксированные
		// 5 единиц: иначе близкие точки склеиваются в прямую линию.
		const lift = Math.max(3.5, Math.abs(b.x - a.x) * 0.16)
		const path = document.createElementNS('http://www.w3.org/2000/svg', 'path')
		path.setAttribute('class', 'account-route')
		path.setAttribute('d', `M ${a.x} ${a.y} Q ${(a.x + b.x) / 2} ${Math.max(1.5, Math.min(a.y, b.y) - lift)} ${b.x} ${b.y}`)
		const title = document.createElementNS('http://www.w3.org/2000/svg', 'title')
		title.textContent = `${device.deviceName ?? device.platform ?? t('settings.devices')} → ${formatNodeLocation(device.node, currentLang()) || device.node?.name || t('loc.unknown')}`
		path.appendChild(title)
		group.appendChild(path)
		for (const [point, cls] of [[a, 'account-origin'], [b, 'account-node']]) {
      const key=cls+':'+point.x+':'+point.y;
      if(Array.from(group.querySelectorAll('circle')).some(el=>el.dataset.point===key))continue;
			// Точка в один пиксель — недостижимая цель для мыши, поэтому
			// карта больше не интерактивна: ни tabindex, ни подсказок по
			// наведению. Ореол нужен только для того, чтобы точка читалась
			// поверх точек континентов.
			const halo = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
			halo.setAttribute('class', cls + '-halo')
			halo.setAttribute('cx', point.x)
			halo.setAttribute('cy', point.y)
			halo.setAttribute('r', '2.5')
			group.appendChild(halo)
			const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
      dot.dataset.point=key;
			dot.setAttribute('class', cls)
			dot.setAttribute('cx', point.x)
			dot.setAttribute('cy', point.y)
			dot.setAttribute('r', '.95')
			group.appendChild(dot)
		}
		placed += 1
	}
	const guest = state?.signedIn === false;
	count.hidden = guest;
	count.classList.toggle('hidden', guest);
	// Чип «Устройства · N» с числом в бейдже и шевроном — как в приложении.
	const countLabel = document.createElement('span')
	countLabel.textContent = currentLang()==='ru'?'Устройства':'Devices'
	const countNum = document.createElement('b')
	countNum.className = 'map-count-num'
	countNum.textContent = String(activeMapData?.activeTunnels ?? '—')
	const countChev = document.createElement('i')
	countChev.className = 'map-count-chev'
	countChev.setAttribute('aria-hidden', 'true')
	count.replaceChildren(materialDeviceIcon('devices'), countLabel, countNum, countChev);
	count.onclick = openAccountDevices;
	count.title = currentLang()==='ru'?'Подключения аккаунта':'Account connections';
	updateAccountDevices();
}

async function refreshServiceAndMap() {
	if (activeMapBusy) return
	activeMapBusy = true
  const revision=activeMapRevision, accountId=state?.user?.id;
	try {
		const serviceResponse = await call('serviceStatus')
		const service = serviceResponse?.data?.service ?? serviceResponse?.service
		if (service && state?.runtime) {
			state.runtime = { ...state.runtime, service }
			if (service.maintenance) showError('vpn-banner', { code: 'maintenance', retryAfterSec: service.retryAfterSec })
		}
		if (state?.signedIn === false) {
			activeMapData = null
		} else {
			let countryCode;
			try { countryCode = TZ_COUNTRY[Intl.DateTimeFormat().resolvedOptions().timeZone]; } catch (_) {}
			const mapResponse = await call('activeMap', { countryCode })
      if(revision!==activeMapRevision||accountId!==state?.user?.id||state?.signedIn===false||channelSwitching)return;
      activeMapData=mapResponse?.ok ? (mapResponse?.data ?? mapResponse) : null;
		}
		renderAccountMap()
  } catch(error) {
    if(revision===activeMapRevision){activeMapData=null;renderAccountMap();}
	} finally {
		activeMapBusy = false
	}
}


function restrictionLabel(restriction) {
	const code = String(restriction?.code ?? '').toLowerCase()
	const known = ['bittorrent', 'smtp25', 'p2p_ports']
	if (known.includes(code)) return t(`restriction.${code}`)
	// Policy-provided custom text is untrusted content: textContent at the call
	// site guarantees it is displayed literally and never interpreted as HTML.
	return String(restriction?.label ?? restriction?.value ?? t('err.forbidden')).slice(0, 120)
}

// Ready-made Material Icons (same glyphs as Flutter Icons.*), locally bundled PNG.
function materialDeviceIcon(platform) {
 const p=String(platform||'').toLowerCase(),el=document.createElement('span');
 const kind=p==='devices'?'devices':/android|ios|phone/.test(p)?'phone':/chrome|browser|ext/.test(p)?'web':p==='server'?'server':'computer';
 el.className='material-device material-device--'+kind;el.setAttribute('aria-hidden','true');return el;
}
// Панель «Устройства» — выпадашка, привязанная к чипу над картой, а не
// модальное окно: полупрозрачный слой с размытием, который не накрывает
// карточку сервера и закрывается кликом мимо или Esc.
function openAccountDevices() {
 const panel=ensureAccountDevicesPanel();
 const next=panel.hidden;
 setAccountDevicesOpen(next);
 if(next)updateAccountDevices();
}
function ensureAccountDevicesPanel() {
 let panel=$('account-devices-pop');
 if(panel)return panel;
 panel=document.createElement('div');
 panel.id='account-devices-pop';panel.className='account-devices-pop';panel.hidden=true;
 panel.setAttribute('role','dialog');panel.setAttribute('aria-labelledby','account-devices-title');
 panel.innerHTML='<header><span id="account-devices-title"></span><button type="button" data-close aria-label="Close">×</button></header><p data-summary></p><div data-rows></div>';
 (document.querySelector('.hero')||document.body).appendChild(panel);
 panel.querySelector('[data-close]').onclick=()=>setAccountDevicesOpen(false);
 document.addEventListener('click',event=>{
  if(panel.hidden||panel.contains(event.target)||$('map-count')?.contains(event.target))return;
  setAccountDevicesOpen(false);
 });
 document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!panel.hidden)setAccountDevicesOpen(false);});
 return panel;
}
function setAccountDevicesOpen(open) {
 const panel=$('account-devices-pop');if(!panel)return;
 panel.hidden=!open;
 const chip=$('map-count');
 if(chip){chip.classList.toggle('is-open',!!open);chip.setAttribute('aria-expanded',open?'true':'false');}
}
function updateAccountDevices() {
 const panel=$('account-devices-pop');if(!panel)return;
 const ru=currentLang()==='ru',rows=panel.querySelector('[data-rows]');
 if(state?.signedIn===false||channelSwitching){setAccountDevicesOpen(false);rows.replaceChildren();return;}
 rows.replaceChildren();
 panel.querySelector('#account-devices-title').textContent=ru?'Устройства онлайн':'Devices online';
 panel.querySelector('[data-summary]').textContent=activeMapData ? (ru?`${activeMapData.activeTunnels} подключено · лимит устройств ${activeMapData.maxDevices}`:`${activeMapData.activeTunnels} connected · device limit ${activeMapData.maxDevices}`):(ru?'Подключения сейчас недоступны':'Connections unavailable');
 for(const d of activeMapData?.devices??[])rows.appendChild(accountDeviceRow(d,ru));
 if(activeMapData&&!activeMapData.devices?.length){
  const empty=document.createElement('p');empty.className='account-empty';
  empty.textContent=ru?'Нет активных подключений':'No active connections';
  rows.appendChild(empty);
 }
}
// Одна и та же плитка, что на сайте и во Flutter: глиф в сиреневом
// квадрате, имя, «платформа · время», маршрут, зелёная точка и шеврон.
function accountDeviceRow(d, ru) {
 const card=document.createElement('article');card.className='account-device';
 const avatar=document.createElement('div');avatar.className='account-device-avatar';
 avatar.appendChild(materialDeviceIcon(d.platform));card.appendChild(avatar);
 const body=document.createElement('div');body.className='account-device-body';
 const line=(text,cls)=>{const p=document.createElement('p');p.className=cls;p.textContent=text;body.appendChild(p);};
 line(d.deviceName||(ru?'Устройство':'Device'),'account-device-name');
 line(`${d.platform||'—'} · ${durationLabel(Math.max(0,Number(d.durationSec)||0)*1000)}`,'account-device-state');
 line(`→ ${formatNodeLocation(d.node,currentLang())||d.node?.name||'—'}`,'account-device-route');
 if(d.isCurrent)line(ru?'Это устройство':'This device','account-device-current');
 card.appendChild(body);
 const end=document.createElement('div');end.className='account-device-end';
 const live=document.createElement('i');live.className='account-device-live'+(d.status==='ACTIVE'?' is-on':'');
 live.title=d.status==='ACTIVE'?(ru?'Подключено':'Connected'):(ru?'Подключение…':'Connecting…');
 const chev=document.createElement('i');chev.className='account-device-chev';chev.setAttribute('aria-hidden','true');
 end.append(live,chev);card.appendChild(end);
 return card;
}
