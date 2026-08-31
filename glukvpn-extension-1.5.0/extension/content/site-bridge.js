/*
 * Site bridge: hands the vpn.gluk.tech session to the extension.
 *
 * The website already keeps a refresh token in localStorage under
 * "gluk.<channel>.refresh" (site/assets/js/auth.js). Instead of asking for the
 * password a second time, the extension borrows that token once, exchanges it
 * for a device-scoped pair via POST /api/devices/register, and hands the
 * rotated refresh token back so the website stays signed in.
 */

const KEYS = { prod: 'gluk.prod.refresh', beta: 'gluk.beta.refresh' }
const POLL_MS = 1000
const POLL_LIMIT = 240 // give the user four minutes to finish logging in

let done = false
let ticks = 0

function readTokens() {
	const out = {}
	for (const [channel, key] of Object.entries(KEYS)) {
		try {
			const value = localStorage.getItem(key)
			if (value) out[channel] = value
		} catch {
			/* storage can be blocked; nothing to hand over then */
		}
	}
	return out
}

function toast(text, tone = 'ok') {
	const el = document.createElement('div')
	el.textContent = text
	el.style.cssText = [
		'position:fixed',
		'z-index:2147483647',
		'right:18px',
		'bottom:18px',
		'max-width:300px',
		'padding:13px 15px',
		'border-radius:15px',
		'font:600 13px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif',
		'color:#f5f3fb',
		'background:rgba(20,15,30,.92)',
		`border:1px solid ${tone === 'ok' ? 'rgba(124,92,246,.5)' : 'rgba(255,107,107,.5)'}`,
		'box-shadow:0 16px 48px rgba(96,45,220,.45)',
		'backdrop-filter:blur(8px)',
	].join(';')
	document.body?.appendChild(el)
	setTimeout(() => el.remove(), 6000)
}

async function offer(reason) {
	if (done) return true
	const tokens = readTokens()
	if (!Object.keys(tokens).length) return false

	let reply
	try {
		reply = await chrome.runtime.sendMessage({
			type: 'siteSession',
			payload: { tokens, reason, origin: location.origin },
		})
	} catch {
		// service worker asleep or extension reloaded; try again on the next tick
		return false
	}

	// Rotation invalidated the token we borrowed, so write the fresh one back or
	// the website would silently log itself out on the next page load.
	if (reply?.rotated?.channel && reply.rotated.refreshToken) {
		try {
			localStorage.setItem(KEYS[reply.rotated.channel], reply.rotated.refreshToken)
		} catch {
			/* ignore */
		}
	}

	if (reply?.ok) {
		done = true
		toast(`GlukVPN extension linked to ${reply.username ?? 'your account'}. Open it from the toolbar.`)
		return true
	}
	if (reply?.already) {
		done = true
		return true
	}
	if (reply?.error && reason !== 'poll') toast(`GlukVPN extension: ${reply.error}`, 'err')
	return false
}

const timer = setInterval(async () => {
	ticks += 1
	if (ticks > POLL_LIMIT || (await offer('poll'))) clearInterval(timer)
}, POLL_MS)

// The site emits this after a successful login or a token rotation.
document.addEventListener('gluk:auth', () => void offer('event'))
window.addEventListener('storage', () => void offer('storage'))

void offer('load')
