/*
 * Client crash reports.
 *
 * Both entry points hand their uncaught errors here - the MV3 service worker
 * through `self`, the popup document through `window` - and this module is the
 * only place that knows how a report reaches the control server:
 *
 *   POST {apiBase}/api/telemetry/error
 *
 * Constraints, because a crash reporter that makes the crash worse is not
 * worth shipping:
 *   - nothing here ever throws; a report that cannot be sent is dropped
 *   - the same error is sent at most once a minute, since a broken poll fires
 *     again on every alarm tick
 *   - one worker lifetime is capped at MAX_PER_SESSION reports
 *   - only the error travels: no request bodies, no tokens, no passwords. Any
 *     that slip into a message are redacted here, and the server scrubs again
 *     on arrival.
 */

import { Api } from './api.js'

const ENDPOINT = '/api/telemetry/error'
const DEDUPE_MS = 60_000
const MAX_PER_SESSION = 10
const LIMITS = { name: 200, message: 800, stack: 4000, context: 200 }

const recent = new Map()
let sent = 0
let enabled = true

const JWT = /eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/g
const BEARER = /(bearer\s+)[A-Za-z0-9._~+/-]{8,}=*/gi
const SECRET = /((?:password|passwd|pass|token|secret|apikey|api_key|authorization)\s*[=:]\s*)[^\s,;"}]{3,}/gi
const LONG_HEX = /\b[0-9a-f]{40,}\b/gi

function scrub(text) {
	return String(text ?? '')
		.replace(JWT, '[jwt]')
		.replace(BEARER, '$1[redacted]')
		.replace(SECRET, '$1[redacted]')
		.replace(LONG_HEX, '[hex]')
}

function clip(text, max) {
	const value = scrub(text).trim()
	if (value.length <= max) return value
	return `${value.slice(0, max - 1)}\u2026`
}

function appVersion() {
	try {
		return chrome.runtime.getManifest().version || 'unknown'
	} catch {
		return 'unknown'
	}
}

// Anything can be thrown in JavaScript, and the popup regularly deals with
// ApiError instances that carry a code rather than a name.
function describe(error) {
	if (error instanceof Error) {
		return {
			name: error.name || error.code || 'Error',
			message: error.message || String(error),
			stack: error.stack || '',
		}
	}
	if (error && typeof error === 'object') {
		let message = error.message || ''
		if (!message) {
			try {
				message = JSON.stringify(error)
			} catch {
				message = String(error)
			}
		}
		return {
			name: String(error.name || error.code || 'ObjectError'),
			message: String(message),
			stack: String(error.stack || ''),
		}
	}
	return { name: 'Error', message: String(error ?? 'unknown error'), stack: '' }
}

async function send(error, context) {
	if (!enabled) return false

	const described = describe(error)
	const name = clip(described.name, LIMITS.name) || 'Error'
	const message = clip(described.message, LIMITS.message) || name
	const where = context ? clip(context, LIMITS.context) : null

	const key = `${name}|${message}|${where ?? ''}`
	const now = Date.now()
	const last = recent.get(key)
	if (last && now - last < DEDUPE_MS) return false
	if (sent >= MAX_PER_SESSION) return false

	if (recent.size > 40) recent.clear()
	recent.set(key, now)
	sent += 1

	const base = await Api.baseUrl()
	if (!base) return false

	const stack = clip(described.stack, LIMITS.stack)
	await fetch(base + ENDPOINT, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({
			platform: 'extension',
			appVersion: appVersion(),
			errorName: name,
			errorMessage: message,
			stackTrace: stack || null,
			context: where,
		}),
	})
	return true
}

export const Telemetry = {
	/** Fire and forget: safe to call from inside an error handler. */
	report(error, context) {
		send(error, context).catch(() => {})
	},

	/** Awaitable variant, for callers that want to know it went out. */
	async reportNow(error, context) {
		try {
			return await send(error, context)
		} catch {
			return false
		}
	},

	/** Kill switch, so a user who opts out stops reporting immediately. */
	setEnabled(value) {
		enabled = value !== false
	},
}
