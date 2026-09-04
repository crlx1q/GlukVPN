/**
 * Coarse site categories for the admin "Activity" view.
 *
 * The node agent hands over host names that sing-box sniffed from TLS SNI,
 * HTTP Host headers and QUIC - the same names any resolver on the path already
 * sees. This module reduces them to a registrable domain ("youtube.com", not
 * "rr3---sn-4g5e6nzl.googlevideo.com") and tags them with a category so the
 * panel can say "YouTube - 1.2 GB" instead of listing CDN hostnames.
 *
 * Static and deliberately small: it is a reading aid for the operator, not a
 * classifier, and an unknown domain simply shows up as "other".
 */

/** Second-level public suffixes where the registrable domain has three labels. */
const MULTI_LEVEL_SUFFIXES = new Set([
	"co.uk",
	"org.uk",
	"gov.uk",
	"ac.uk",
	"com.au",
	"net.au",
	"org.au",
	"com.tr",
	"com.br",
	"com.ua",
	"com.kz",
	"org.kz",
	"co.jp",
	"co.kr",
	"com.cn",
	"com.hk",
	"com.tw",
	"co.in",
	"com.mx",
	"com.ar",
	"co.za",
	"com.sg",
	"com.my",
	"com.ph",
	"com.vn",
	"co.nz",
	"com.pl",
	"com.eg",
	"com.sa",
	"co.il",
	"com.ru",
	"org.ru",
	"net.ru",
	"msk.ru",
	"spb.ru",
])

const IPV4 = /^(\d{1,3}\.){3}\d{1,3}$/

/**
 * "rr3---sn-4g5e6nzl.googlevideo.com" -> "googlevideo.com",
 * "www.bbc.co.uk" -> "bbc.co.uk", "10.0.0.1" -> "10.0.0.1".
 */
export function registrableDomain(host: string): string {
	let value = String(host ?? "")
		.trim()
		.toLowerCase()
		.replace(/\.+$/, "")
	if (!value) return ""
	// Strip a port and IPv6 brackets if the sniffer left them in.
	value = value.replace(/^\[|\]$/g, "").replace(/:\d+$/, "")
	if (IPV4.test(value) || value.includes(":")) return value
	const labels = value.split(".").filter(Boolean)
	if (labels.length <= 2) return labels.join(".")
	const lastTwo = labels.slice(-2).join(".")
	if (MULTI_LEVEL_SUFFIXES.has(lastTwo) && labels.length >= 3) {
		return labels.slice(-3).join(".")
	}
	return lastTwo
}

export type DomainCategory =
	| "video"
	| "social"
	| "messaging"
	| "search"
	| "gaming"
	| "streaming-music"
	| "shopping"
	| "cloud"
	| "dev"
	| "ads"
	| "adult"
	| "torrent"
	| "vpn-control"
	| "other"

/** Human labels the panel shows; the codes above stay stable for storage. */
export const CATEGORY_LABELS: Record<DomainCategory, string> = {
	video: "Video",
	social: "Social",
	messaging: "Messaging",
	search: "Search / Google",
	gaming: "Gaming",
	"streaming-music": "Music",
	shopping: "Shopping",
	cloud: "Cloud / Apple / Microsoft",
	dev: "Developer",
	ads: "Ads / Tracking",
	adult: "Adult",
	torrent: "Torrent",
	"vpn-control": "GlukVPN",
	other: "Other",
}

/** Registrable domain -> category. Keys must already be registrable domains. */
const KNOWN: Record<string, DomainCategory> = {
	// video
	"youtube.com": "video",
	"googlevideo.com": "video",
	"ytimg.com": "video",
	"youtu.be": "video",
	"netflix.com": "video",
	"nflxvideo.net": "video",
	"nflximg.net": "video",
	"twitch.tv": "video",
	"ttvnw.net": "video",
	"vimeo.com": "video",
	"kinopoisk.ru": "video",
	"ivi.ru": "video",
	"okko.tv": "video",
	"rutube.ru": "video",
	"disneyplus.com": "video",
	"hbomax.com": "video",
	"max.com": "video",
	"primevideo.com": "video",
	"dailymotion.com": "video",
	"tiktokcdn.com": "video",
	"tiktokv.com": "video",
	// social
	"tiktok.com": "social",
	"instagram.com": "social",
	"cdninstagram.com": "social",
	"facebook.com": "social",
	"fbcdn.net": "social",
	"twitter.com": "social",
	"x.com": "social",
	"twimg.com": "social",
	"vk.com": "social",
	"vk.ru": "social",
	"userapi.com": "social",
	"ok.ru": "social",
	"reddit.com": "social",
	"redd.it": "social",
	"redditmedia.com": "social",
	"pinterest.com": "social",
	"pinimg.com": "social",
	"linkedin.com": "social",
	"licdn.com": "social",
	"threads.net": "social",
	"snapchat.com": "social",
	"tumblr.com": "social",
	// messaging
	"telegram.org": "messaging",
	"t.me": "messaging",
	"telegram.me": "messaging",
	"whatsapp.com": "messaging",
	"whatsapp.net": "messaging",
	"discord.com": "messaging",
	"discordapp.com": "messaging",
	"discord.gg": "messaging",
	"discordapp.net": "messaging",
	"signal.org": "messaging",
	"viber.com": "messaging",
	"slack.com": "messaging",
	"zoom.us": "messaging",
	"skype.com": "messaging",
	"teams.microsoft.com": "messaging",
	"wechat.com": "messaging",
	// search / google
	"google.com": "search",
	"googleapis.com": "search",
	"gstatic.com": "search",
	"googleusercontent.com": "search",
	"gvt1.com": "search",
	"google.kz": "search",
	"google.ru": "search",
	"bing.com": "search",
	"yandex.ru": "search",
	"yandex.net": "search",
	"yandex.kz": "search",
	"duckduckgo.com": "search",
	"wikipedia.org": "search",
	"wikimedia.org": "search",
	// gaming
	"steampowered.com": "gaming",
	"steamcontent.com": "gaming",
	"steamstatic.com": "gaming",
	"steamcommunity.com": "gaming",
	"epicgames.com": "gaming",
	"unrealengine.com": "gaming",
	"xboxlive.com": "gaming",
	"xbox.com": "gaming",
	"playstation.net": "gaming",
	"playstation.com": "gaming",
	"sonyentertainmentnetwork.com": "gaming",
	"nintendo.net": "gaming",
	"riotgames.com": "gaming",
	"leagueoflegends.com": "gaming",
	"blizzard.com": "gaming",
	"battle.net": "gaming",
	"ea.com": "gaming",
	"origin.com": "gaming",
	"ubisoft.com": "gaming",
	"roblox.com": "gaming",
	"rbxcdn.com": "gaming",
	"minecraft.net": "gaming",
	"mojang.com": "gaming",
	"geforcenow.com": "gaming",
	"nvidiagrid.net": "gaming",
	"gfn.ru": "gaming",
	"pubg.com": "gaming",
	"wargaming.net": "gaming",
	"valorant.com": "gaming",
	"supercell.com": "gaming",
	// music
	"spotify.com": "streaming-music",
	"scdn.co": "streaming-music",
	"spotifycdn.com": "streaming-music",
	"apple-music.com": "streaming-music",
	"soundcloud.com": "streaming-music",
	"deezer.com": "streaming-music",
	"music.yandex.ru": "streaming-music",
	// shopping
	"amazon.com": "shopping",
	"aliexpress.com": "shopping",
	"alicdn.com": "shopping",
	"ebay.com": "shopping",
	"wildberries.ru": "shopping",
	"ozon.ru": "shopping",
	"kaspi.kz": "shopping",
	"temu.com": "shopping",
	"shein.com": "shopping",
	// cloud / platform
	"apple.com": "cloud",
	"icloud.com": "cloud",
	"mzstatic.com": "cloud",
	"microsoft.com": "cloud",
	"windows.com": "cloud",
	"windowsupdate.com": "cloud",
	"live.com": "cloud",
	"office.com": "cloud",
	"office365.com": "cloud",
	"azure.com": "cloud",
	"azureedge.net": "cloud",
	"dropbox.com": "cloud",
	"onedrive.com": "cloud",
	"cloudflare.com": "cloud",
	"cloudfront.net": "cloud",
	"akamaihd.net": "cloud",
	"akamaized.net": "cloud",
	"amazonaws.com": "cloud",
	"digitalocean.com": "cloud",
	"oracle.com": "cloud",
	"oraclecloud.com": "cloud",
	// developer
	"github.com": "dev",
	"githubusercontent.com": "dev",
	"gitlab.com": "dev",
	"stackoverflow.com": "dev",
	"npmjs.org": "dev",
	"npmjs.com": "dev",
	"pypi.org": "dev",
	"docker.com": "dev",
	"docker.io": "dev",
	"jetbrains.com": "dev",
	"openai.com": "dev",
	"chatgpt.com": "dev",
	"anthropic.com": "dev",
	"claude.ai": "dev",
	"cursor.com": "dev",
	"cursor.sh": "dev",
	// ads / tracking
	"doubleclick.net": "ads",
	"googlesyndication.com": "ads",
	"googleadservices.com": "ads",
	"google-analytics.com": "ads",
	"googletagmanager.com": "ads",
	"adnxs.com": "ads",
	"criteo.com": "ads",
	"scorecardresearch.com": "ads",
	"facebook.net": "ads",
	"yandex.com": "ads",
	"adriver.ru": "ads",
	"appsflyer.com": "ads",
	"adjust.com": "ads",
	"branch.io": "ads",
	"sentry.io": "ads",
	// adult
	"pornhub.com": "adult",
	"phncdn.com": "adult",
	"xvideos.com": "adult",
	"xnxx.com": "adult",
	"xhamster.com": "adult",
	"onlyfans.com": "adult",
	"redtube.com": "adult",
	"youporn.com": "adult",
	// torrent trackers / indexers
	"thepiratebay.org": "torrent",
	"rutracker.org": "torrent",
	"rutor.info": "torrent",
	"1337x.to": "torrent",
	"nnmclub.to": "torrent",
	"kinozal.tv": "torrent",
	"tracker.openbittorrent.com": "torrent",
	"opentrackr.org": "torrent",
	// ours
	"gluk.tech": "vpn-control",
}

/** Substrings that place an otherwise unknown registrable domain. */
const KEYWORDS: Array<[string, DomainCategory]> = [
	["tracker", "torrent"],
	["torrent", "torrent"],
	["porn", "adult"],
	["xxx", "adult"],
	["sex", "adult"],
	["ads", "ads"],
	["adserv", "ads"],
	["analytics", "ads"],
	["metrics", "ads"],
	["telemetry", "ads"],
	["cdn", "cloud"],
]

export function categorize(host: string): DomainCategory {
	const domain = registrableDomain(host)
	if (!domain) return "other"
	const known = KNOWN[domain]
	if (known) return known
	// "music.yandex.ru" style keys are three-label; retry on the full host.
	const full = String(host ?? "")
		.trim()
		.toLowerCase()
		.replace(/\.+$/, "")
	if (KNOWN[full]) return KNOWN[full] as DomainCategory
	for (const [needle, category] of KEYWORDS) {
		if (domain.includes(needle)) return category
	}
	return "other"
}

export function categoryLabel(code: string | null | undefined): string {
	return CATEGORY_LABELS[(code ?? "other") as DomainCategory] ?? CATEGORY_LABELS.other
}
