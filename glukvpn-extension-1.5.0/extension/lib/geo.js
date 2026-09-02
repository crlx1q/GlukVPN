/*
 * Where to draw a marker for a country the API tells us about. The control
 * plane returns country / countryCode / city (GeoIP on login, node records for
 * exits) but no coordinates, so the map needs its own lookup.
 * Values match site/assets/js/config.js for the nodes that already exist.
 */

const CITIES = {
	frankfurt: [50.11, 8.68],
	berlin: [52.52, 13.4],
	paris: [48.86, 2.35],
	amsterdam: [52.37, 4.9],
	london: [51.51, -0.13],
	warsaw: [52.23, 21.01],
	stockholm: [59.33, 18.06],
	helsinki: [60.17, 24.94],
	istanbul: [41.01, 28.98],
	ashburn: [39.04, -77.49],
	'new york': [40.71, -74.01],
	'los angeles': [34.05, -118.24],
	singapore: [1.35, 103.82],
	tokyo: [35.68, 139.69],
	moscow: [55.75, 37.62],
	almaty: [43.24, 76.89],
	astana: [51.13, 71.43],
	dubai: [25.2, 55.27],
}

const COUNTRIES = {
	DE: [51.16, 10.45],
	FR: [46.6, 2.35],
	NL: [52.13, 5.29],
	US: [39.5, -98.35],
	GB: [54.0, -2.0],
	TR: [39.0, 35.0],
	SG: [1.35, 103.82],
	JP: [36.2, 138.25],
	KZ: [48.0, 68.0],
	RU: [58.0, 60.0],
	UA: [48.38, 31.17],
	PL: [52.0, 19.0],
	SE: [62.0, 15.0],
	FI: [64.0, 26.0],
	ES: [40.0, -4.0],
	IT: [42.8, 12.6],
	CH: [46.8, 8.2],
	AT: [47.6, 14.1],
	CZ: [49.8, 15.5],
	RO: [45.9, 25.0],
	AE: [24.0, 54.0],
	IN: [22.0, 79.0],
	CN: [35.0, 105.0],
	KR: [36.5, 127.8],
	HK: [22.32, 114.17],
	AU: [-25.0, 134.0],
	BR: [-10.0, -52.0],
	CA: [56.0, -106.0],
	MX: [23.0, -102.0],
	ZA: [-29.0, 24.0],
	EG: [26.0, 30.0],
	GE: [42.3, 43.4],
	AM: [40.2, 45.0],
	AZ: [40.4, 47.9],
	KG: [41.2, 74.8],
	UZ: [41.4, 64.6],
	BY: [53.7, 27.9],
}

/** Falls back to the map centre used by the site's home marker (Kazakhstan). */
export function latLonFor({ city, countryCode } = {}) {
	const key = String(city ?? '').trim().toLowerCase()
	if (key && CITIES[key]) return CITIES[key]
	const cc = String(countryCode ?? '').trim().toUpperCase()
	if (cc && COUNTRIES[cc]) return COUNTRIES[cc]
	return [48.0, 68.0]
}

/* ----------------------------------------------------------- localization -- */

export const GEO_DICTIONARY = {
	countries: {
		DE: { ru: 'Германия', en: 'Germany' },
		NL: { ru: 'Нидерланды', en: 'Netherlands' },
		FR: { ru: 'Франция', en: 'France' },
		US: { ru: 'США', en: 'United States' },
		GB: { ru: 'Великобритания', en: 'United Kingdom' },
		FI: { ru: 'Финляндия', en: 'Finland' },
		SE: { ru: 'Швеция', en: 'Sweden' },
		PL: { ru: 'Польша', en: 'Poland' },
		CH: { ru: 'Швейцария', en: 'Switzerland' },
		AT: { ru: 'Австрия', en: 'Austria' },
		ES: { ru: 'Испания', en: 'Spain' },
		IT: { ru: 'Италия', en: 'Italy' },
		TR: { ru: 'Турция', en: 'Turkey' },
		CA: { ru: 'Канада', en: 'Canada' },
		BR: { ru: 'Бразилия', en: 'Brazil' },
		KZ: { ru: 'Казахстан', en: 'Kazakhstan' },
		RU: { ru: 'Россия', en: 'Russia' },
		UA: { ru: 'Украина', en: 'Ukraine' },
		UZ: { ru: 'Узбекистан', en: 'Uzbekistan' },
		KG: { ru: 'Кыргызстан', en: 'Kyrgyzstan' },
		GE: { ru: 'Грузия', en: 'Georgia' },
		AE: { ru: 'ОАЭ', en: 'United Arab Emirates' },
		IN: { ru: 'Индия', en: 'India' },
		SG: { ru: 'Сингапур', en: 'Singapore' },
		JP: { ru: 'Япония', en: 'Japan' },
		KR: { ru: 'Южная Корея', en: 'South Korea' },
		AU: { ru: 'Австралия', en: 'Australia' },
		BY: { ru: 'Беларусь', en: 'Belarus' },
		AM: { ru: 'Армения', en: 'Armenia' },
		AZ: { ru: 'Азербайджан', en: 'Azerbaijan' },
	},
	cities: {
		frankfurt: { ru: 'Франкфурт', en: 'Frankfurt' },
		berlin: { ru: 'Берлин', en: 'Berlin' },
		amsterdam: { ru: 'Амстердам', en: 'Amsterdam' },
		paris: { ru: 'Париж', en: 'Paris' },
		london: { ru: 'Лондон', en: 'London' },
		warsaw: { ru: 'Варшава', en: 'Warsaw' },
		stockholm: { ru: 'Стокгольм', en: 'Stockholm' },
		helsinki: { ru: 'Хельсинки', en: 'Helsinki' },
		istanbul: { ru: 'Стамбул', en: 'Istanbul' },
		ashburn: { ru: 'Ашберн', en: 'Ashburn' },
		'new york': { ru: 'Нью-Йорк', en: 'New York' },
		'los angeles': { ru: 'Лос-Анджелес', en: 'Los Angeles' },
		singapore: { ru: 'Сингапур', en: 'Singapore' },
		tokyo: { ru: 'Токио', en: 'Tokyo' },
		moscow: { ru: 'Москва', en: 'Moscow' },
		almaty: { ru: 'Алматы', en: 'Almaty' },
		astana: { ru: 'Астана', en: 'Astana' },
		dubai: { ru: 'Дубай', en: 'Dubai' },
	},
}

export function localizeCountry(code, lang = 'ru') {
	if (!code) return ''
	const cc = String(code).trim().toUpperCase()
	const entry = GEO_DICTIONARY.countries[cc]
	return entry?.[lang] || entry?.en || code
}

export function localizeCity(city, lang = 'ru') {
	if (!city) return ''
	const key = String(city).trim().toLowerCase()
	const entry = GEO_DICTIONARY.cities[key]
	return entry?.[lang] || entry?.en || city
}

export function formatNodeLocation(node, lang = 'ru') {
	if (!node) return ''
	const countryCode = node.countryCode || node.country
	const countryName = localizeCountry(countryCode, lang)
	const cityName = localizeCity(node.city, lang)
	if (cityName && countryName) return `${cityName}, ${countryName}`
	return cityName || countryName || node.name || node.id || ''
}

export function placeLabel({ city, region, country, countryCode }, lang = 'ru') {
	const cName = localizeCountry(countryCode || country, lang)
	const cityName = localizeCity(city || region, lang)
	const parts = [cityName, cName].filter(Boolean)
	return parts.length ? parts.join(', ') : 'Unknown location'
}

