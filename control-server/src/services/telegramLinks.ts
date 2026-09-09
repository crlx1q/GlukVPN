/**
 * Telegram deep links, and which control plane owns the bot.
 *
 * Why this file exists at all: one bot token can only be long-polled by one
 * process. prod (:8081) and beta (:8082) are two isolated stacks with two
 * separate databases, so if both start the same bot, Telegram hands each
 * update to whichever process won the race - and a code minted by the other
 * one is genuinely absent from the database the answering process can see.
 * The user then gets "\u041a\u043e\u0434 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d \u0438\u043b\u0438 \u0443\u0436\u0435 \u0438\u0441\u0442\u0451\u043a" or "\u042d\u0442\u0430 \u0441\u0441\u044b\u043b\u043a\u0430 \u0434\u043b\u044f \u0432\u0445\u043e\u0434\u0430
 * \u043d\u0435\u0438\u0437\u0432\u0435\u0441\u0442\u043d\u0430" for a link that is seconds old, on every platform, at random.
 *
 * So there are two rules here, and they are the whole fix:
 *
 *   1. `TELEGRAM_BOT_CHANNEL` names the one channel that may long-poll this
 *      token. Everybody else keeps the token (it is still needed to *send*
 *      messages) but never calls getUpdates.
 *   2. Every start payload carries the channel that minted it, so a code that
 *      does arrive at the wrong bot is answered with the real reason instead
 *      of "not found".
 *
 * It lives in its own module because both `registration.ts` and
 * `telegramBot.ts` need it, and `telegramBot.ts` already imports
 * `registration.ts` - putting it in either would be an import cycle.
 */

import { config } from "../config"

/**
 * Assembled from parts rather than written as one literal, so that no tool in
 * the pipeline mistakes it for a real link and rewrites it. This has happened
 * twice already; see the comment in `telegramBot.ts`.
 */
const LINK_SCHEME = "https:"
const TELEGRAM_LINK_HOST = "t.me"

/** `/start login-<CODE>` is a sign-in; anything else is a sign-up token. */
export const LOGIN_PREFIX = "login-"

/**
 * Separates the channel tag from the payload: `<TOKEN>_beta`.
 *
 * Telegram allows `A-Za-z0-9_-` in a start payload. Neither the sign-up token
 * (Crockford alphabet) nor the sign-in code (`XXXX-XXXX`) ever contains an
 * underscore, so the tag can never be mistaken for part of the code.
 */
const CHANNEL_SEPARATOR = "_"

export type ReleaseChannel = "prod" | "beta"

/** Resolved through getMe when TELEGRAM_BOT_USERNAME is left empty. */
let resolvedUsername = ""

/**
 * Cache the name the bot reported for itself.
 *
 * Without this, an empty TELEGRAM_BOT_USERNAME produced links shaped like
 * `t.me/?start=CODE` - a link that opens Telegram search instead of the bot,
 * which is indistinguishable from "the bot is broken" for the person tapping it.
 */
export function rememberBotUsername(name: string): void {
	const clean = name.trim().replace(/^@/, "")
	if (clean) resolvedUsername = clean
}

/** `@name` without the `@`, or "" when it is neither configured nor resolved. */
export function botUsername(): string {
	return config.TELEGRAM_BOT_USERNAME.trim().replace(/^@/, "") || resolvedUsername
}

/** A token is configured, so the bot can at least send messages from here. */
export function telegramConfigured(): boolean {
	return config.TELEGRAM_BOT_TOKEN.trim().length > 0
}

/** The one channel allowed to long-poll this bot token. */
export function botChannel(): ReleaseChannel {
	return config.TELEGRAM_BOT_CHANNEL
}

/** True when this process is the one that answers the bot's chats. */
export function botOwnedHere(): boolean {
	return config.CHANNEL === botChannel()
}

/**
 * True when a Telegram flow started here can actually be finished.
 *
 * This is the check every route should use before offering a Telegram step:
 * a channel that does not own the bot can hand out a deep link, but nothing
 * on the other side will ever be able to read its database.
 */
export function telegramUsable(): boolean {
	return telegramConfigured() && botOwnedHere()
}

/** "" on the channel that owns the bot, `_beta` / `_prod` anywhere else. */
export function channelTag(): string {
	return botOwnedHere() ? "" : CHANNEL_SEPARATOR + config.CHANNEL
}

/** `t.me/<bot>?start=<payload>`, or "" when the bot name is unknown. */
export function telegramStartLink(payload: string): string {
	const name = botUsername()
	if (!name || !telegramConfigured()) return ""
	const base = `${LINK_SCHEME}//${TELEGRAM_LINK_HOST}/${name}`
	return payload ? `${base}?start=${encodeURIComponent(payload)}` : base
}

/**
 * Sign-up / re-bind link: one tap, and the bot already knows who is asking.
 *
 * Tagged even when this channel does not own the bot: the token is useless
 * there, but a tagged payload lets the bot say *why* instead of "not found".
 */
export function telegramDeepLink(token: string): string {
	return telegramStartLink(token ? token + channelTag() : "")
}

/**
 * Sign-in link for the device-authorization flow.
 *
 * Empty unless this channel owns the bot. Every client falls back to
 * `verifyUrl`, which carries `?api=<channel>` and therefore works from any
 * channel - a working web confirmation beats a Telegram button that cannot
 * possibly succeed.
 */
export function telegramLoginLink(userCode: string): string {
	if (!telegramUsable() || !userCode) return ""
	return telegramStartLink(LOGIN_PREFIX + userCode)
}

export type StartPayload = {
	/** The token or `login-<CODE>`, with the channel tag stripped off. */
	value: string
	/** Which control plane minted it. An untagged payload is assumed local. */
	channel: ReleaseChannel
	/** True when the payload carried an explicit channel tag. */
	tagged: boolean
}

/** Split `<payload>[_prod|_beta]` into the payload and the minting channel. */
export function parseStartPayload(raw: string): StartPayload {
	const trimmed = String(raw ?? "").trim()
	const at = trimmed.lastIndexOf(CHANNEL_SEPARATOR)
	if (at > 0) {
		const suffix = trimmed.slice(at + 1).toLowerCase()
		if (suffix === "prod" || suffix === "beta") {
			return { value: trimmed.slice(0, at), channel: suffix, tagged: true }
		}
	}
	// Untagged: either an old client, or a code somebody typed in by hand.
	// Assuming "local" keeps every pre-existing link working unchanged.
	return { value: trimmed, channel: config.CHANNEL, tagged: false }
}

/** PROD / BETA, for a message a human is about to read. */
export function channelLabel(channel: string): string {
	return channel === "beta" ? "BETA" : "PROD"
}
