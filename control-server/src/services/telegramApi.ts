/**
 * Telegram's HTTP API, and nothing else.
 *
 * Why this file exists separately from `telegramBot.ts`: the bot now has two
 * sides that both have to *send* messages - the admin side
 * (`telegramAdmin.ts`: registrations, purchases, warnings, the daily digest)
 * and the account side (`telegramAccount.ts`: the menus a subscriber uses).
 * Both are imported *by* the bot, so leaving `sendMessage` in the bot module
 * would make each of those imports an import cycle.
 *
 * Everything here is a thin wrapper over one Bot API method. No state, no
 * polling, no business rules: those belong to the modules above.
 */

import { config } from "../config"
import { botChannel, botUsername, rememberBotUsername } from "./telegramLinks"

const API_BASE = "https://api.telegram.org"

// ------------------------------------------------------------------ types --

export type TelegramUser = {
	id: number
	is_bot?: boolean
	first_name?: string
	last_name?: string
	username?: string
}

export type TelegramContact = {
	phone_number: string
	user_id?: number
	first_name?: string
}

export type TelegramChat = {
	id: number
	/** "private" | "group" | "supergroup" | "channel". */
	type: string
	title?: string
	username?: string
}

export type TelegramMessage = {
	message_id: number
	from?: TelegramUser
	chat: TelegramChat
	text?: string
	contact?: TelegramContact
	new_chat_members?: TelegramUser[]
}

export type TelegramCallbackQuery = {
	id: string
	from: TelegramUser
	data?: string
	message?: TelegramMessage
}

/** Delivered when the bot itself is added to, or removed from, a chat. */
export type TelegramChatMemberUpdated = {
	chat: TelegramChat
	from: TelegramUser
	new_chat_member: { user: TelegramUser; status: string }
}

export type TelegramUpdate = {
	update_id: number
	message?: TelegramMessage
	edited_message?: TelegramMessage
	callback_query?: TelegramCallbackQuery
	my_chat_member?: TelegramChatMemberUpdated
}

export type Logger = {
	info: (obj: unknown, msg?: string) => void
	warn: (obj: unknown, msg?: string) => void
	error: (obj: unknown, msg?: string) => void
}

export const consoleLogger: Logger = {
	info: (obj, msg) => console.log(msg ?? "", obj ?? ""),
	warn: (obj, msg) => console.warn(msg ?? "", obj ?? ""),
	error: (obj, msg) => console.error(msg ?? "", obj ?? ""),
}

export type InlineButton = { text: string; callback_data?: string; url?: string }

export type ReplyMarkup =
	| {
			keyboard: Array<Array<{ text: string; request_contact?: boolean }>>
			resize_keyboard?: boolean
			one_time_keyboard?: boolean
	  }
	| { inline_keyboard: InlineButton[][] }
	| { remove_keyboard: true }

// -------------------------------------------------------------- transport --

export function telegramToken(): string {
	return config.TELEGRAM_BOT_TOKEN.trim()
}

/**
 * Messages are sent with `parse_mode: HTML`, so anything that came from a
 * person - a nickname, an email, a device name - has to be escaped or a stray
 * `<` turns the whole message into an API error.
 */
export function escapeHtml(value: string | null | undefined): string {
	return String(value ?? "")
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
}

export async function callTelegram<T>(
	method: string,
	payload: unknown,
	logger: Logger = consoleLogger,
): Promise<T | null> {
	if (!telegramToken()) return null
	try {
		const response = await fetch(`${API_BASE}/bot${telegramToken()}/${method}`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(payload),
		})
		const body = (await response.json()) as { ok: boolean; result?: T; description?: string }
		if (!body.ok) {
			// 409 means another process is long-polling this same bot token. It
			// deserves its own loud line, because the symptom users report is not
			// an error at all: the updates that do get through land in whichever
			// process won the race, and if that is the other channel, its database
			// has never seen the code - so the bot answers "код не найден".
			if (response.status === 409 || /conflict/i.test(body.description ?? "")) {
				logger.error(
					{
						method,
						channel: config.CHANNEL,
						botChannel: botChannel(),
						description: body.description,
					},
					"telegram_getupdates_conflict",
				)
				return null
			}
			// The token is in the URL, never in the body, so this is safe to log.
			logger.warn({ method, description: body.description }, "telegram_api_error")
			return null
		}
		return body.result ?? null
	} catch (error) {
		logger.warn({ method, error: String(error) }, "telegram_api_unreachable")
		return null
	}
}

// --------------------------------------------------------------- outbound --

export async function sendTelegramMessage(
	chatId: string | number,
	text: string,
	replyMarkup?: ReplyMarkup,
): Promise<boolean> {
	const result = await callTelegram<unknown>("sendMessage", {
		chat_id: chatId,
		text,
		parse_mode: "HTML",
		disable_web_page_preview: true,
		...(replyMarkup ? { reply_markup: replyMarkup } : {}),
	})
	return result !== null
}

/**
 * Redraw a menu in place.
 *
 * Editing rather than sending keeps one card in the chat instead of a wall of
 * near-identical messages every time somebody taps a button. Telegram refuses
 * an edit that changes nothing ("message is not modified"); that is a no-op,
 * not a failure, so it is reported as success.
 */
export async function editTelegramMessage(params: {
	chatId: string | number
	messageId: number
	text: string
	replyMarkup?: ReplyMarkup
}): Promise<boolean> {
	if (!telegramToken()) return false
	try {
		const response = await fetch(`${API_BASE}/bot${telegramToken()}/editMessageText`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({
				chat_id: params.chatId,
				message_id: params.messageId,
				text: params.text,
				parse_mode: "HTML",
				disable_web_page_preview: true,
				...(params.replyMarkup ? { reply_markup: params.replyMarkup } : {}),
			}),
		})
		const body = (await response.json()) as { ok: boolean; description?: string }
		if (body.ok) return true
		if (/not modified/i.test(body.description ?? "")) return true
		consoleLogger.warn({ description: body.description }, "telegram_edit_failed")
		return false
	} catch (error) {
		consoleLogger.warn({ error: String(error) }, "telegram_api_unreachable")
		return false
	}
}

/**
 * Every callback has to be answered, or the button keeps spinning in the
 * client for a minute and the person taps it again.
 */
export async function answerCallbackQuery(params: {
	id: string
	text?: string
	showAlert?: boolean
}): Promise<void> {
	await callTelegram<boolean>("answerCallbackQuery", {
		callback_query_id: params.id,
		...(params.text ? { text: params.text } : {}),
		...(params.showAlert ? { show_alert: true } : {}),
	})
}

export async function leaveChat(chatId: string | number): Promise<boolean> {
	return (await callTelegram<boolean>("leaveChat", { chat_id: chatId })) !== null
}

/**
 * `file_id` of the account owner's current avatar, or null when they have
 * none / hide it.
 *
 * Only ever called while that person is talking to the bot (see the 24-hour
 * rule in `telegramAccount.syncTelegramProfile`): a background sweep over
 * every account would be a request per user per day for a picture nobody
 * asked to see.
 */
export async function profilePhotoId(userId: number): Promise<string | null> {
	const photos = await callTelegram<{
		total_count: number
		photos: Array<Array<{ file_id: string }>>
	}>("getUserProfilePhotos", { user_id: userId, limit: 1 })
	const sizes = photos?.photos?.[0]
	if (!sizes || sizes.length === 0) return null
	// Last entry is the largest size Telegram offers for that photo.
	return sizes[sizes.length - 1]?.file_id ?? null
}

/** Resolve @username once, so deep links keep working if config is left blank. */
export async function resolveBotUsername(): Promise<string> {
	const configured = botUsername()
	if (configured) return configured
	const me = await callTelegram<{ username?: string }>("getMe", {})
	const name = me?.username ?? ""
	// Cached, so every link built afterwards carries a real bot name instead of
	// `t.me/?start=CODE` - a link that opens Telegram search and looks, to the
	// person tapping it, exactly like a broken bot.
	if (name) rememberBotUsername(name)
	return name
}

// ------------------------------------------------------------- formatting --

const MINUTE_MS = 60_000
const GB = 1024 ** 3
const MB = 1024 ** 2

/**
 * Bot messages are written in one local time, expressed as an offset.
 *
 * An offset instead of an IANA zone on purpose: no timezone database has to be
 * present in the runtime, and "12.09 21:15 (UTC+5)" is unambiguous for whoever
 * reads it - unlike a bare "21:15" in a chat shared by several people.
 */
function toLocal(date: Date): Date {
	return new Date(date.getTime() + config.TELEGRAM_TZ_OFFSET_MIN * MINUTE_MS)
}

export function tzLabel(): string {
	const offset = config.TELEGRAM_TZ_OFFSET_MIN
	const sign = offset < 0 ? "-" : "+"
	const hours = Math.floor(Math.abs(offset) / 60)
	const minutes = Math.abs(offset) % 60
	return `UTC${sign}${hours}${minutes ? `:${String(minutes).padStart(2, "0")}` : ""}`
}

/** Local calendar day as YYYY-MM-DD. What "one digest per day" is keyed on. */
export function localDay(date: Date): string {
	return toLocal(date).toISOString().slice(0, 10)
}

/** Local hour, 0-23. */
export function localHour(date: Date): number {
	return toLocal(date).getUTCHours()
}

/** "12.09 21:15" */
export function localTime(date: Date): string {
	const local = toLocal(date)
	const day = String(local.getUTCDate()).padStart(2, "0")
	const month = String(local.getUTCMonth() + 1).padStart(2, "0")
	const hours = String(local.getUTCHours()).padStart(2, "0")
	const minutes = String(local.getUTCMinutes()).padStart(2, "0")
	return `${day}.${month} ${hours}:${minutes}`
}

/** "12.09.2026" - for dates where the time of day is noise. */
export function localDate(date: Date): string {
	const local = toLocal(date)
	const day = String(local.getUTCDate()).padStart(2, "0")
	const month = String(local.getUTCMonth() + 1).padStart(2, "0")
	return `${day}.${month}.${local.getUTCFullYear()}`
}

/**
 * "12.4 ГБ" / "812 МБ" / "0 МБ".
 *
 * Rounded harder as the number grows: nobody reads the tenths of a gigabyte on
 * "412.7 ГБ", but "0.4 ГБ" instead of "412 МБ" hides the scale.
 */
export function formatBytes(bytes: number): string {
	if (!Number.isFinite(bytes) || bytes <= 0) return "0 МБ"
	const gb = bytes / GB
	if (gb >= 1) return `${gb >= 10 ? Math.round(gb) : gb.toFixed(1)} ГБ`
	const mb = bytes / MB
	if (mb >= 1) return `${mb >= 10 ? Math.round(mb) : mb.toFixed(1)} МБ`
	return `${Math.max(1, Math.round(bytes / 1024))} КБ`
}
