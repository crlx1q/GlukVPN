/**
 * Approximate origin of a request, resolved from its IP address.
 *
 * Deliberately coarse: country name, ISO country code and region name. No
 * coordinates, no city-level fix, no GPS permission on the phone — the app only
 * needs enough to place the "you" marker at a country centre on the dotted map.
 *
 * Everything here is best effort. A timeout, an error or a private address
 * leaves the stored value untouched and never blocks or slows down a login
 * (callers fire it without awaiting).
 */

import { config } from "../config"
import { prisma } from "../prisma"

export type ApproximateOrigin = {
	country: string | null
	countryCode: string | null
	region: string | null
}

/** Re-resolve at most once a day per user; the answer barely ever changes. */
const REFRESH_AFTER_MS = 24 * 60 * 60 * 1000

/**
 * Addresses that can never be geolocated: loopback, RFC1918, link-local,
 * CGNAT, and the IPv6 equivalents. Checked as strings so a malformed value
 * simply returns false instead of throwing.
 */
function isLocatableIp(ip: string): boolean {
	const value = ip.trim().toLowerCase()
	if (value.length === 0) return false
	if (value === "::1" || value === "localhost") return false
	// IPv6: loopback, unique-local (fc00::/7) and link-local (fe80::/10).
	if (value.startsWith("fc") || value.startsWith("fd")) return false
	if (value.startsWith("fe8") || value.startsWith("fe9")) return false
	if (value.startsWith("fea") || value.startsWith("feb")) return false

	const octets = value.split(".")
	if (octets.length !== 4) {
		// Any other IPv6 address: allow the lookup, the provider will decide.
		return value.includes(":")
	}
	const [a, b] = octets.map((part) => Number(part))
	if (!Number.isInteger(a) || !Number.isInteger(b)) return false
	if (a === 0 || a === 10 || a === 127) return false
	if (a === 169 && b === 254) return false
	if (a === 172 && b >= 16 && b <= 31) return false
	if (a === 192 && b === 168) return false
	// 100.64.0.0/10 — carrier NAT, geolocates to the carrier at best.
	if (a === 100 && b >= 64 && b <= 127) return false
	return true
}

/** Accept the field names used by the common providers, in order. */
function pick(payload: Record<string, unknown>, keys: string[]): string | null {
	for (const key of keys) {
		const value = payload[key]
		if (typeof value === "string" && value.trim().length > 0) {
			return value.trim().slice(0, 80)
		}
	}
	return null
}

/**
 * Single lookup against the configured provider. Returns null when disabled,
 * when the address is not locatable, or on any transport/parse failure.
 */
export async function lookupOrigin(ip: string): Promise<ApproximateOrigin | null> {
	if (!config.GEOIP_ENABLED) return null
	if (!isLocatableIp(ip)) return null

	const url = config.GEOIP_URL_TEMPLATE.replace("{ip}", encodeURIComponent(ip))
	try {
		const response = await fetch(url, {
			signal: AbortSignal.timeout(config.GEOIP_TIMEOUT_MS),
			headers: { accept: "application/json" },
		})
		if (!response.ok) return null
		const payload = (await response.json()) as Record<string, unknown>
		const countryCode = pick(payload, ["country_code", "countryCode", "country"])
		const country = pick(payload, ["country_name", "countryName", "country"])
		const region = pick(payload, ["region", "region_name", "regionName", "state"])
		if (!country && !countryCode) return null
		return {
			country,
			// ISO-3166 alpha-2, upper-cased; the app maps it to a flag and a dot.
			countryCode: countryCode ? countryCode.toUpperCase().slice(0, 2) : null,
			region,
		}
	} catch {
		// Provider down, DNS failure, timeout, malformed JSON — all non-fatal.
		return null
	}
}

/**
 * Refresh the stored approximate origin of a user after a successful login.
 *
 * Safe to call without awaiting: it swallows every error, so a slow provider
 * can never delay the login response.
 */
export async function refreshUserOrigin(params: {
	userId: string
	ip: string
	knownCountryCode?: string | null
	geoUpdatedAt?: Date | null
}): Promise<ApproximateOrigin | null> {
	if (!config.GEOIP_ENABLED) return null

	const fresh =
		params.geoUpdatedAt !== null &&
		params.geoUpdatedAt !== undefined &&
		Date.now() - params.geoUpdatedAt.getTime() < REFRESH_AFTER_MS
	if (fresh && params.knownCountryCode) return null

	try {
		const origin = await lookupOrigin(params.ip)
		if (!origin) return null
		await prisma.user.update({
			where: { id: params.userId },
			data: {
				lastCountry: origin.country,
				lastCountryCode: origin.countryCode,
				lastRegion: origin.region,
				geoUpdatedAt: new Date(),
			},
		})
		return origin
	} catch {
		return null
	}
}
