/** Coarse, labelled geography and UTC observation windows. Never a GPS fix. */
export const COUNTRY_CENTRES: Readonly<Record<string, readonly [number, number]>> = {
	DE: [51.2, 10.4], FR: [46.6, 2.4], NL: [52.2, 5.3], US: [39.8, -98.6], GB: [54, -2],
	TR: [39, 35.2], SG: [1.35, 103.8], JP: [36.2, 138.3], KZ: [48, 68], RU: [61.5, 105.3],
	PL: [52.1, 19.4], SE: [60.1, 18.6], FI: [64, 26], NO: [60.5, 8.5], DK: [56, 10],
	CH: [46.8, 8.2], ES: [40.2, -3.7], IT: [42.8, 12.6], CA: [56.1, -106.3], AU: [-25.3, 133.8],
	IN: [21, 78], BR: [-14.2, -51.9], UA: [48.4, 31.2], CZ: [49.8, 15.5], AT: [47.5, 14.6],
	RO: [45.9, 25], BE: [50.5, 4.5], IE: [53.4, -8.2], PT: [39.4, -8.2], LT: [55.2, 23.9],
	LV: [56.9, 24.6], EE: [58.6, 25], MX: [23.6, -102.5], AR: [-38.4, -63.6], CL: [-35.7, -71.5],
	ZA: [-30.6, 22.9], AE: [23.4, 53.8], IL: [31, 34.9], HK: [22.3, 114.2], KR: [35.9, 127.8],
	CN: [35.9, 104.2], ID: [-0.8, 113.9], IS: [64.9, -19], BD: [23.7, 90.4], CO: [4.6, -74.3],
	UZ: [41.4, 64.6], KG: [41.2, 74.8], GE: [42.3, 43.4], AM: [40.1, 45], AZ: [40.1, 47.6],
	BY: [53.7, 27.9], MD: [47.4, 28.4], HU: [47.2, 19.5], BG: [42.7, 25.5], GR: [39.1, 21.8],
	HR: [45.1, 15.2], RS: [44, 21], SK: [48.7, 19.7], SI: [46.2, 14.8], TJ: [38.9, 71.3],
	TM: [38.9, 59.6], EG: [26.8, 30.8], TH: [15.9, 101], VN: [14.1, 108.3], MY: [4.2, 101.9],
	NZ: [-40.9, 174.9],
}
const NODE_CITIES: Readonly<Record<string, readonly [number, number]>> = {
	"DE:frankfurt": [50.11, 8.68], "DE:frankfurt am main": [50.11, 8.68], "DE:berlin": [52.52, 13.4],
	"FR:paris": [48.86, 2.35], "NL:amsterdam": [52.37, 4.9], "GB:london": [51.51, -0.13],
	"US:new york": [40.71, -74.01], "US:los angeles": [34.05, -118.24],
	"TR:istanbul": [41.01, 28.98], "SG:singapore": [1.35, 103.82], "JP:tokyo": [35.68, 139.69],
}
export type MapLocation = { lat: number; lon: number; source: "node-city" | "node-country"; approximate: true }
export function countryPoint(code: string | null | undefined): readonly [number, number] | null {
	return COUNTRY_CENTRES[String(code ?? "").trim().toUpperCase()] ?? null
}
export function nodeLocation(node: { countryCode: string; city?: string | null }): MapLocation | null {
	const city = NODE_CITIES[`${node.countryCode.toUpperCase()}:${(node.city ?? "").trim().toLowerCase()}`]
	const point = city ?? countryPoint(node.countryCode)
	return point ? { lat: point[0], lon: point[1], source: city ? "node-city" : "node-country", approximate: true } : null
}
export type UsagePeriod = "day" | "week" | "month"
export function usageWindow(period: UsagePeriod, now = new Date()) {
	const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
	if (period === "week") start.setUTCDate(start.getUTCDate() - (start.getUTCDay() + 6) % 7)
	if (period === "month") start.setUTCDate(1)
	return { start, end: now, bucketSize: period === "day" ? "hour" as const : "day" as const }
}
export function usageBucket(date: Date, unit: "hour" | "day"): string {
	return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), unit === "hour" ? date.getUTCHours() : 0)).toISOString()
}
/** Mirrors the database trigger: stale/replayed cumulative counters never subtract or add twice. */
export function counterDelta(previous: bigint, current: bigint): bigint {
	return current > previous ? current - previous : 0n
}
