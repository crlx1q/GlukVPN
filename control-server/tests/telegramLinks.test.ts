/**
 * The channel tag on Telegram start payloads.
 *
 * Regression cover for the bug TabPay reported: prod and beta both long-polled
 * one bot token, so whichever process won the getUpdates race answered from
 * its own database and a code minted seconds earlier came back as
 * "\u041a\u043e\u0434 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d \u0438\u043b\u0438 \u0443\u0436\u0435 \u0438\u0441\u0442\u0451\u043a". The tag is what lets the bot tell "this code is not
 * mine" apart from "this code is old", and `telegramUsable()` is what stops a
 * channel from offering a Telegram step it could never finish.
 */

import { afterEach, describe, expect, it, vi } from "vitest"

type Links = typeof import("../src/services/telegramLinks")

const KEYS = [
	"CHANNEL",
	"TELEGRAM_BOT_CHANNEL",
	"TELEGRAM_BOT_TOKEN",
	"TELEGRAM_BOT_USERNAME",
] as const

const BOT = {
	TELEGRAM_BOT_TOKEN: "123456:test-token",
	TELEGRAM_BOT_USERNAME: "@GlukTestBot",
}

/** config.ts reads the environment once at import, so reset it every time. */
async function loadLinks(env: Record<string, string>): Promise<Links> {
	vi.resetModules()
	for (const key of KEYS) delete process.env[key]
	Object.assign(process.env, env)
	return import("../src/services/telegramLinks")
}

afterEach(() => {
	for (const key of KEYS) delete process.env[key]
})

describe("telegram links", () => {
	it("builds untagged links on the channel that owns the bot", async () => {
		const links = await loadLinks({
			...BOT,
			CHANNEL: "prod",
			TELEGRAM_BOT_CHANNEL: "prod",
		})

		expect(links.botOwnedHere()).toBe(true)
		expect(links.telegramUsable()).toBe(true)
		expect(links.channelTag()).toBe("")
		expect(links.telegramDeepLink("KQ7MN2PXYZ")).toBe(
			"https://t.me/GlukTestBot?start=KQ7MN2PXYZ",
		)
		expect(links.telegramLoginLink("ABCD-2345")).toBe(
			"https://t.me/GlukTestBot?start=login-ABCD-2345",
		)
	})

	it("tags sign-up links and withholds sign-in links on a foreign channel", async () => {
		const links = await loadLinks({
			...BOT,
			CHANNEL: "beta",
			TELEGRAM_BOT_CHANNEL: "prod",
		})

		expect(links.botOwnedHere()).toBe(false)
		expect(links.telegramUsable()).toBe(false)
		expect(links.channelTag()).toBe("_beta")

		// Tagged rather than withheld: the token is useless on the other side,
		// but the tag is what lets the bot say why instead of "code not found".
		expect(links.telegramDeepLink("KQ7MN2PXYZ")).toBe(
			"https://t.me/GlukTestBot?start=KQ7MN2PXYZ_beta",
		)

		// Sign-in has a working web fallback (verifyUrl carries ?api=beta), so a
		// button that cannot possibly succeed is worse than no button.
		expect(links.telegramLoginLink("ABCD-2345")).toBe("")
	})

	it("reads the minting channel back out of a start payload", async () => {
		const links = await loadLinks({
			...BOT,
			CHANNEL: "prod",
			TELEGRAM_BOT_CHANNEL: "prod",
		})

		expect(links.parseStartPayload("KQ7MN2PXYZ_beta")).toEqual({
			value: "KQ7MN2PXYZ",
			channel: "beta",
			tagged: true,
		})
		expect(links.parseStartPayload("login-ABCD-2345_beta")).toEqual({
			value: "login-ABCD-2345",
			channel: "beta",
			tagged: true,
		})

		// Untagged means "issued before this change", and must keep working.
		expect(links.parseStartPayload("KQ7MN2PXYZ")).toEqual({
			value: "KQ7MN2PXYZ",
			channel: "prod",
			tagged: false,
		})
		expect(links.parseStartPayload(" login-ABCD-2345 ")).toEqual({
			value: "login-ABCD-2345",
			channel: "prod",
			tagged: false,
		})
	})

	it("offers nothing when no bot token is configured", async () => {
		const links = await loadLinks({ CHANNEL: "prod", TELEGRAM_BOT_CHANNEL: "prod" })

		expect(links.telegramConfigured()).toBe(false)
		expect(links.telegramUsable()).toBe(false)
		expect(links.telegramDeepLink("KQ7MN2PXYZ")).toBe("")
		expect(links.telegramLoginLink("ABCD-2345")).toBe("")
	})
})
