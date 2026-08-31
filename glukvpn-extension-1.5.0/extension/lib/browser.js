/* Which browser is this, really.
 *
 * The answer ends up in the `platform` column of the devices table, so the
 * admin panel lists "chrome" / "edge" / "brave" next to "android" instead of a
 * generic "extension". Chromium forks all claim to be Chrome in the UA string;
 * userAgentData brands is the only place they admit who they are.
 */

const BRAND_MAP = [
	{ match: /microsoft edge/i, id: 'edge', label: 'Edge' },
	{ match: /opera|opr/i, id: 'opera', label: 'Opera' },
	{ match: /yandex/i, id: 'yandex', label: 'Yandex' },
	{ match: /vivaldi/i, id: 'vivaldi', label: 'Vivaldi' },
	{ match: /brave/i, id: 'brave', label: 'Brave' },
	{ match: /google chrome/i, id: 'chrome', label: 'Chrome' },
	{ match: /chromium/i, id: 'chromium', label: 'Chromium' },
]

const OS_MAP = [
	{ match: /windows/i, label: 'Windows' },
	{ match: /mac/i, label: 'macOS' },
	{ match: /linux/i, label: 'Linux' },
	{ match: /cros|chrome ?os/i, label: 'ChromeOS' },
	{ match: /android/i, label: 'Android' },
]

function osLabel(hint) {
	const source = hint || navigator.userAgent || ''
	for (const entry of OS_MAP) if (entry.match.test(source)) return entry.label
	return 'Desktop'
}

export function detectBrowser() {
	const data = navigator.userAgentData
	const brands = data?.brands ?? []
	let id = 'chromium'
	let label = 'Chromium'
	let version = ''

	for (const entry of BRAND_MAP) {
		const hit = brands.find((b) => entry.match.test(b.brand))
		if (hit) {
			id = entry.id
			label = entry.label
			version = String(hit.version ?? '')
			break
		}
	}

	// Older Chromium builds expose no brands; fall back to the UA string.
	if (!brands.length) {
		const ua = navigator.userAgent || ''
		for (const entry of BRAND_MAP) {
			if (entry.match.test(ua)) {
				id = entry.id
				label = entry.label
				break
			}
		}
		if (/edg\//i.test(ua)) {
			id = 'edge'
			label = 'Edge'
		}
		version = (ua.match(/(?:chrome|edg)\/(\d+)/i) ?? [])[1] ?? ''
	}

	const os = osLabel(data?.platform)
	return {
		// Written to devices.platform (max 32 chars, free-form string).
		platform: id,
		browser: label,
		version,
		os,
		// Written to devices.device_name (max 64 chars).
		deviceName: version ? `${label} ${version} - ${os}` : `${label} - ${os}`,
	}
}
