/* Same readouts as the app's lib/utils/format.dart, so a number never looks
 * different in the browser than it does on the phone. */

export function formatBytes(value) {
	const bytes = Number(value ?? 0)
	if (!Number.isFinite(bytes) || bytes <= 0) return { value: '0', unit: 'B' }
	const units = ['B', 'KB', 'MB', 'GB', 'TB']
	let i = 0
	let n = bytes
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024
		i++
	}
	const digits = n >= 100 || i === 0 ? 0 : n >= 10 ? 1 : 2
	return { value: n.toFixed(digits), unit: units[i] }
}

export function bytesLabel(value) {
	const { value: v, unit } = formatBytes(value)
	return `${v} ${unit}`
}

/** mm:ss under an hour, h:mm:ss above it - the app does the same. */
export function formatDuration(ms) {
	const total = Math.max(0, Math.floor(Number(ms ?? 0) / 1000))
	const h = Math.floor(total / 3600)
	const m = Math.floor((total % 3600) / 60)
	const s = total % 60
	const pad = (n) => String(n).padStart(2, '0')
	return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`
}

export function formatPing(ms) {
	if (ms === null || ms === undefined || !Number.isFinite(ms)) return '--'
	return `${Math.round(ms)}`
}

/** low / medium / excellent, the three signal buckets the app renders. */
export function signalLevel(ping) {
	if (ping === null || ping === undefined || !Number.isFinite(ping)) return 0
	if (ping <= 60) return 3
	if (ping <= 140) return 2
	return 1
}

export function flagEmoji(countryCode) {
	const cc = String(countryCode ?? '').trim().toUpperCase()
	if (cc.length !== 2) return '\u{1F3F4}'
	return String.fromCodePoint(...[...cc].map((c) => 0x1f1e6 + c.charCodeAt(0) - 65))
}
