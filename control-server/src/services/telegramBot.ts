/**
 * The GlukVPN Telegram bot. One file, no framework, no webhook.
 *
 * It does exactly two things:
 *
 *   1. `/start <token>` - the deep link from the sign-up page. The bot answers
 *      with a "Share my contact" button.
 *   2. the shared contact - the bot checks the contact really belongs to the
 *      person sending it, then hands the phone number to the registration
 *      service, which finishes the account.
 *
 * It also delivers verification codes (password reset over Telegram), which is
 * why `sendTelegramMessage` is exported.
 *
 * Long polling, not a webhook: a webhook needs a public HTTPS route, a secret
 * path and an Nginx rule, and it breaks silently whenever the certificate or
 * the domain changes. getUpdates needs nothing but an outbound connection, so
 * it works identically on the server, on a laptop and on beta - and if the
 * process dies, Telegram simply queues the updates until it comes back.
 *
 * The one security rule worth stating out loud: `contact.user_id` must equal
 * `message.from.id`. Telegram lets anyone forward a contact from their address
 * book, so without that check a user could register an account against someone
 * else's phone number - which would defeat the entire point of this step.
 */

import { config } from "../config"
import {
	attachTelegram,
	normalizePhone,
	telegramConfigured,
} from "./registration"

const API_BASE = "https://api.telegram.org"

/** Telegram holds the request open; 50s is comfortably inside its limit. */
const POLL_TIMEOUT_SEC = 50

/** How long a `/start <token>` stays valid inside a chat, in ms. */
const CHAT_TOKEN_TTL_MS = 10 * 60 * 1000

type TelegramUser = {
	id: number
	is_bot?: boolean
	first_name?: string
	username?: string
}

type TelegramContact = {
	phone_number: string
	user_id?: number
	first_name?: string
}

type TelegramMessage = {
	message_id: number
	from?: TelegramUser
	chat: { id: number; type: string }
	text?: string
	contact?: TelegramContact
}

type TelegramUpdate = {
	update_id: number
	message?: TelegramMessage
	edited_message?: TelegramMessage
}

type Logger = {
	info: (obj: unknown, msg?: string) => void
	warn: (obj: unknown, msg?: string) => void
	error: (obj: unknown, msg?: string) => void
}

const consoleLogger: Logger = {
	info: (obj, msg) => console.log(msg ?? "", obj ?? ""),
	warn: (obj, msg) => console.warn(msg ?? "", obj ?? ""),
	error: (obj, msg) => console.error(msg ?? "", obj ?? ""),
}

/** Which token a chat is currently answering for. */
const chatTokens = new Map<number, { token: string; at: number }>()

let running = false

function token(): string {
	return config.TELEGRAM_BOT_TOKEN.trim()
}

async function call<T>(method: string, payload: unknown): Promise<T | null> {
	if (!token()) return null
	try {
		const response = await fetch(`${API_BASE}/bot${token()}/${method}`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(payload),
		})
		const body = (await response.json()) as { ok: boolean; result?: T; description?: string }
		if (!body.ok) {
			// The token is in the URL, never in the body, so this is safe to log.
			consoleLogger.warn({ method, description: body.description }, "telegram_api_error")
			return null
		}
		return body.result ?? null
	} catch (error) {
		consoleLogger.warn({ method, error: String(error) }, "telegram_api_unreachable")
		return null
	}
}

// ------------------------------------------------------------- outbound ----

export type ReplyMarkup =
	| {
			keyboard: Array<Array<{ text: string; request_contact?: boolean }>>
			resize_keyboard?: boolean
			one_time_keyboard?: boolean
	  }
	| { remove_keyboard: true }

export async function sendTelegramMessage(
	chatId: string | number,
	text: string,
	replyMarkup?: ReplyMarkup,
): Promise<boolean> {
	const result = await call<unknown>("sendMessage", {
		chat_id: chatId,
		text,
		parse_mode: "HTML",
		disable_web_page_preview: true,
		...(replyMarkup ? { reply_markup: replyMarkup } : {}),
	})
	return result !== null
}

/** Resolve @username once, so deep links keep working if config is left blank. */
export async function resolveBotUsername(): Promise<string> {
	const configured = config.TELEGRAM_BOT_USERNAME.trim().replace(/^@/, "")
	if (configured) return configured
	const me = await call<{ username?: string }>("getMe", {})
	return me?.username ?? ""
}

// -------------------------------------------------------------- handlers ---

const SHARE_KEYBOARD: ReplyMarkup = {
	keyboard: [[{ text: "📱 Поделиться контактом", request_contact: true }]],
	resize_keyboard: true,
	one_time_keyboard: true,
}

const HIDE_KEYBOARD: ReplyMarkup = { remove_keyboard: true }

function rememberToken(chatId: number, value: string): void {
	chatTokens.set(chatId, { token: value, at: Date.now() })
	// Nothing here is worth a scheduled sweep; drop stale entries opportunistically.
	for (const [chat, entry] of chatTokens) {
		if (Date.now() - entry.at > CHAT_TOKEN_TTL_MS) chatTokens.delete(chat)
	}
}

function takeToken(chatId: number): string | null {
	const entry = chatTokens.get(chatId)
	if (!entry) return null
	if (Date.now() - entry.at > CHAT_TOKEN_TTL_MS) {
		chatTokens.delete(chatId)
		return null
	}
	return entry.token
}

async function handleStart(message: TelegramMessage, argument: string): Promise<void> {
	const chatId = message.chat.id
	const name = message.from?.first_name ?? ""

	if (!argument) {
		await sendTelegramMessage(
			chatId,
			`Привет${name ? ", " + name : ""}! Это бот <b>GlukVPN</b>.\n\n` +
				"Он подтверждает, что аккаунт заводит живой человек.\n\n" +
				"Начните регистрацию на <b>vpn.gluk.tech</b> — на шаге «Телеграм» " +
				"там будет кнопка, которая откроет этот чат уже с кодом.",
			HIDE_KEYBOARD,
		)
		return
	}

	rememberToken(chatId, argument.trim().toUpperCase())
	await sendTelegramMessage(
		chatId,
		"Остался один шаг.\n\n" +
			"Нажмите кнопку <b>«Поделиться контактом»</b> ниже — так мы убедимся, " +
			"что аккаунт принадлежит вам.\n\n" +
			"Мы сохраним только номер телефона. Ни переписка, ни контакты, " +
			"ни что-либо ещё боту не видны.",
		SHARE_KEYBOARD,
	)
}

async function handleContact(message: TelegramMessage): Promise<void> {
	const chatId = message.chat.id
	const contact = message.contact
	const from = message.from
	if (!contact || !from) return

	// The rule that makes this step mean anything: a forwarded contact belongs
	// to somebody else, and accepting one would let a user register against a
	// stranger's phone number.
	if (!contact.user_id || contact.user_id !== from.id) {
		await sendTelegramMessage(
			chatId,
			"Это чужой контакт. Нажмите именно кнопку " +
				"<b>«Поделиться контактом»</b> — она отправляет ваш собственный номер.",
			SHARE_KEYBOARD,
		)
		return
	}

	const pendingToken = takeToken(chatId)
	if (!pendingToken) {
		await sendTelegramMessage(
			chatId,
			"Не вижу, к какой регистрации это относится.\n\n" +
				"Вернитесь на страницу регистрации и снова нажмите кнопку " +
				"перехода в Telegram — ссылка передаёт код автоматически.",
			HIDE_KEYBOARD,
		)
		return
	}

	const phone = normalizePhone(contact.phone_number)
	if (!phone) {
		await sendTelegramMessage(chatId, "Не удалось прочитать номер. Попробуйте ещё раз.", SHARE_KEYBOARD)
		return
	}

	const outcome = await attachTelegram({
		token: pendingToken,
		telegramId: String(from.id),
		telegramUsername: from.username ?? null,
		phone,
	})

	if (outcome.ok) {
		chatTokens.delete(chatId)
		await sendTelegramMessage(
			chatId,
			outcome.kind === "registered"
				? "✅ Готово, аккаунт создан.\n\n" +
					`Логин: <b>${outcome.username}</b>\n\n` +
					"Возвращайтесь на сайт или в приложение и входите с почтой и паролем."
				: "✅ Telegram привязан к аккаунту " + `<b>${outcome.username}</b>.`,
			HIDE_KEYBOARD,
		)
		return
	}

	const reasons: Record<string, string> = {
		unknown:
			"Код не найден или уже истёк. Начните регистрацию на сайте заново — " +
			"ссылка в Telegram живёт 30 минут.",
		email_pending: "Сначала подтвердите почту кодом на сайте, потом возвращайтесь сюда.",
		phone_taken: "На этот номер уже зарегистрирован аккаунт. Воспользуйтесь входом или восстановлением пароля.",
		telegram_taken: "Этот Telegram уже привязан к другому аккаунту.",
	}
	await sendTelegramMessage(
		chatId,
		(outcome.reason ? reasons[outcome.reason] : undefined) ?? reasons.unknown,
		HIDE_KEYBOARD,
	)
}

async function handleMessage(message: TelegramMessage): Promise<void> {
	if (message.contact) {
		await handleContact(message)
		return
	}

	const text = (message.text ?? "").trim()
	if (!text) return

	if (text.startsWith("/start")) {
		await handleStart(message, text.slice("/start".length).trim())
		return
	}
	if (text.startsWith("/cancel")) {
		chatTokens.delete(message.chat.id)
		await sendTelegramMessage(message.chat.id, "Отменил. Ничего не сохранено.", HIDE_KEYBOARD)
		return
	}
	if (text.startsWith("/help")) {
		await sendTelegramMessage(
			message.chat.id,
			"Бот нужен только для подтверждения аккаунта <b>GlukVPN</b>.\n\n" +
				"/start — начать заново\n/cancel — отменить\n\n" +
				"Поддержка: <b>vpn.gluk.tech</b>",
			HIDE_KEYBOARD,
		)
		return
	}

	// A bare code pasted by hand still works - some people will do that.
	if (/^[A-Z0-9]{8,12}$/i.test(text)) {
		await handleStart(message, text)
		return
	}

	await sendTelegramMessage(
		message.chat.id,
		"Не понял. Откройте ссылку со страницы регистрации — она передаёт код сама. " +
			"Или отправьте /help.",
	)
}

// ----------------------------------------------------------------- runner --

/**
 * Start long polling. Safe to call when the token is missing: it simply does
 * nothing, so prod and beta can share one code path and one env template.
 */
export function startTelegramBot(logger: Logger = consoleLogger): void {
	if (!telegramConfigured()) {
		logger.info({}, "telegram_bot_disabled_no_token")
		return
	}
	if (running) return
	running = true

	void (async () => {
		const username = await resolveBotUsername()
		logger.info({ username }, "telegram_bot_started")

		let offset = 0
		// Back off on failure so a Telegram outage does not turn into a tight
		// loop of failing requests for as long as it lasts.
		let backoffMs = 1000

		while (running) {
			const updates = await call<TelegramUpdate[]>("getUpdates", {
				offset,
				timeout: POLL_TIMEOUT_SEC,
				allowed_updates: ["message"],
			})

			if (updates === null) {
				await new Promise((resolve) => setTimeout(resolve, backoffMs))
				backoffMs = Math.min(backoffMs * 2, 60_000)
				continue
			}
			backoffMs = 1000

			for (const update of updates) {
				// Advance the offset even if handling throws: a message that
				// crashes the handler would otherwise be redelivered forever.
				offset = Math.max(offset, update.update_id + 1)
				const message = update.message ?? update.edited_message
				if (!message) continue
				try {
					await handleMessage(message)
				} catch (error) {
					logger.error({ error: String(error) }, "telegram_handler_failed")
				}
			}
		}
	})()
}

export function stopTelegramBot(): void {
	running = false
}

// Running this file directly starts the bot on its own:
//
//   npm run bot        (compiled)
//   npm run bot:dev    (tsx)
//
// Useful when the API is restarting during a deploy and the bot should not be.
if (require.main === module) {
	startTelegramBot()
	process.on("SIGINT", () => {
		stopTelegramBot()
		process.exit(0)
	})
}
