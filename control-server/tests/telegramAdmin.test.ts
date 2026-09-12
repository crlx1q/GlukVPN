/**
 * The pure parts of the administration bot: where a notification goes, what it
 * is allowed to say, and when the daily summary is owed.
 *
 * Everything covered here is free of Telegram and of the database on purpose.
 * `notifyAdmins` can only ever reach the chats `adminChatIds()` returns, so a
 * duplicate id there means every registration is announced twice; the masks
 * are what keep a full address out of a group chat; and `digestDue` is the
 * whole of "once per local day", which is the part that silently sends nothing
 * - or sends four times - when it is wrong.
 */

import { afterEach, describe, expect, it, vi } from "vitest"

type Admin = typeof import("../src/services/telegramAdmin")
type Api = typeof import("../src/services/telegramApi")

const KEYS = [
	"TELEGRAM_ADMIN_CHAT_IDS",
	"TELEGRAM_ADMIN_GROUP_ID",
	"TELEGRAM_ALERT_CHAT_ID",
	"TELEGRAM_DIGEST_HOUR",
	"TELEGRAM_TZ_OFFSET_MIN",
] as const

/** config.ts reads the environment once at import, so reset it every time. */
async function loadAdmin(env: Record<string, string> = {}): Promise<Admin> {
	vi.resetModules()
	for (const key of KEYS) delete process.env[key]
	Object.assign(process.env, env)
	return import("../src/services/telegramAdmin")
}

async function loadApi(): Promise<Api> {
	vi.resetModules()
	for (const key of KEYS) delete process.env[key]
	return import("../src/services/telegramApi")
}

afterEach(() => {
	for (const key of KEYS) delete process.env[key]
})

describe("administration destinations", () => {
	it("keeps the group first and never repeats a chat", async () => {
		const admin = await loadAdmin({
			TELEGRAM_ADMIN_GROUP_ID: "-1001234567890",
			TELEGRAM_ADMIN_CHAT_IDS: "555, 777 555",
			TELEGRAM_ALERT_CHAT_ID: "777",
		})

		// The same id in two variables is the normal way to configure this after
		// an upgrade, and must not double every notification.
		expect(admin.adminChatIds()).toEqual(["-1001234567890", "555", "777"])
		expect(admin.isAdminGroup("-1001234567890")).toBe(true)
		// Telegram sends chat ids as numbers; the config is a string.
		expect(admin.isAdminGroup(-1001234567890)).toBe(true)
		expect(admin.isAdminGroup("-100999999999")).toBe(false)
		expect(admin.isAdminChat("555")).toBe(true)
		expect(admin.isAdminChat("42")).toBe(false)
	})

	it("has nowhere to send when nothing is configured", async () => {
		const admin = await loadAdmin()

		expect(admin.adminChatIds()).toEqual([])
		// An unset group must not match "no group", or every chat would be one.
		expect(admin.isAdminGroup("")).toBe(false)
		expect(admin.isAdminChat("555")).toBe(false)
	})
})

describe("redaction", () => {
	it("shows just enough of an address to recognise the account", async () => {
		const admin = await loadAdmin()

		expect(admin.maskEmail("alisher@gmail.com")).toBe("a***@gmail.com")
		expect(admin.maskEmail("not-an-address")).toBe("***")
		expect(admin.maskEmail(null)).toBe("—")
	})

	it("keeps only the tail of a phone number", async () => {
		const admin = await loadAdmin()

		expect(admin.maskPhone("+7 701 234 4567")).toBe("···4567")
		// Too short to be a phone number is treated as no phone number at all,
		// rather than printing the whole of it.
		expect(admin.maskPhone("123")).toBe("—")
		expect(admin.maskPhone(undefined)).toBe("—")
	})
})

describe("daily summary schedule", () => {
	it("waits for the local hour, then sends once per local day", async () => {
		// Defaults: UTC+5, 10:00 local.
		const admin = await loadAdmin()

		// 04:30 UTC is 09:30 local - too early.
		expect(
			admin.digestDue({ lastDigestDay: null }, new Date("2026-09-12T04:30:00Z")),
		).toBe(false)
		expect(
			admin.digestDue({ lastDigestDay: null }, new Date("2026-09-12T05:30:00Z")),
		).toBe(true)
		// Already sent today: the monitor asks every ten minutes, and the answer
		// has to be "no" for the rest of the day.
		expect(
			admin.digestDue({ lastDigestDay: "2026-09-12" }, new Date("2026-09-12T05:30:00Z")),
		).toBe(false)
		// Yesterday's send does not settle today.
		expect(
			admin.digestDue({ lastDigestDay: "2026-09-11" }, new Date("2026-09-12T05:30:00Z")),
		).toBe(true)
	})
})

describe("formatting", () => {
	it("prints times in the configured offset", async () => {
		const api = await loadApi()

		expect(api.tzLabel()).toBe("UTC+5")
		// Late evening UTC is already the next local day - which is the day the
		// digest is keyed on.
		expect(api.localDay(new Date("2026-09-12T19:05:00Z"))).toBe("2026-09-13")
		expect(api.localHour(new Date("2026-09-12T19:05:00Z"))).toBe(0)
		expect(api.localTime(new Date("2026-09-12T16:05:00Z"))).toBe("12.09 21:05")
		expect(api.localDate(new Date("2026-09-12T16:05:00Z"))).toBe("12.09.2026")
	})

	it("rounds traffic harder as it grows", async () => {
		const api = await loadApi()

		expect(api.formatBytes(0)).toBe("0 МБ")
		expect(api.formatBytes(900)).toBe("1 КБ")
		expect(api.formatBytes(5 * 1024 ** 2)).toBe("5.0 МБ")
		expect(api.formatBytes(1.5 * 1024 ** 3)).toBe("1.5 ГБ")
		// Nobody reads the tenths at this scale.
		expect(api.formatBytes(412.7 * 1024 ** 3)).toBe("413 ГБ")
	})

	it("escapes what a person chose as their own name", async () => {
		const api = await loadApi()

		// Sent with parse_mode HTML: a stray "<" in a nickname would turn the
		// whole notification into an API error instead of a message.
		expect(api.escapeHtml("<b>Vasya</b> & co")).toBe("&lt;b&gt;Vasya&lt;/b&gt; &amp; co")
		expect(api.escapeHtml(null)).toBe("")
	})
})
