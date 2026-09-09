/**
 * The GlukVPN Telegram bot. One file, no framework, no webhook.
 *
 * It does exactly three things:
 *
 *   1. `/start <token>` - the deep link from the sign-up page. The bot answers
 *      with a "Share my contact" button.
 *   2. the shared contact - the bot checks the contact really belongs to the
 *      person sending it, then hands the phone number to the registration
 *      service, which finishes the account.
 *   3. **ROUND 11:** `/start login-<CODE>` - confirming a sign-in started by a
 *      client (see `services/linkAuth.ts`). The bot shows what is asking, and
 *      the user allows or refuses it in the chat.
 *
 * Point 3 is worth a word on why it is safe. The chat is already bound to an
 * account: sign-up only completes when this exact Telegram user shares their
 * phone number, so `telegramId` is a proven identity, not a self-claimed one.
 * That makes the bot a better confirmation surface than a browser session -
 * approving requires the person to hold the phone that owns the account, and
 * the code in the deep link authorises nothing on its own.
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
import { HttpError } from "../lib/errors"
import { attachTelegram, normalizePhone } from "./registration"
import type { ReleaseChannel } from "./telegramLinks"
import {
	botChannel,
	botOwnedHere,
	botUsername,
	channelLabel,
	LOGIN_PREFIX,
	parseStartPayload,
	rememberBotUsername,
	telegramConfigured,
} from "./telegramLinks"

// The link builders moved to `telegramLinks.ts`, which also owns the channel
// tag: the registration service needs them too, and importing this file from
// there would be a cycle. Re-exported so `routes/link.ts` keeps its import.
export { botUsername, telegramLoginLink } from "./telegramLinks"

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

/** ROUND 11: which sign-in a chat has been asked to confirm. */
const chatLogins = new Map<number, { code: string; at: number }>()

/**
 * ROUND 11: how the bot reaches the link-sign-in store.
 *
 * Injected rather than imported, because approving a request has to mint real
 * tokens and `issueTokens` needs the Fastify instance for `app.jwt`. The route
 * module owns that instance and installs the bridge on registration; when the
 * bot is run standalone (`npm run bot`) nothing installs it, and the bot says
 * so instead of pretending the button works.
 */
type LinkSummary = {
	client: string
	deviceName: string | null
	ip: string | null
	status: string
}

export type TelegramLoginBridge = {
	describe: (userCode: string) => Promise<LinkSummary | null> | LinkSummary | null
	approve: (input: { userCode: string; telegramId: string }) => Promise<{
		ok: boolean
		reason?: string
		username?: string
	}>
	deny: (userCode: string) => Promise<{ ok: boolean }> | { ok: boolean }
}

let loginBridge: TelegramLoginBridge | null = null

export function setTelegramLoginBridge(bridge: TelegramLoginBridge | null): void {
	loginBridge = bridge
}

// `botUsername()` and `telegramLoginLink()` live in `telegramLinks.ts` now.
// That module keeps assembling the host from parts for the same reason as the
// note below, and adds the channel tag to the payload.

// Editor artefact of that corruption, left as a comment: `https://t.me/${name?start=login-${userCode}

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
			// 409 means another process is long-polling this same bot token. It
			// deserves its own loud line, because the symptom users report is not
			// an error at all: the updates that do get through land in whichever
			// process won the race, and if that is the other channel, its database
			// has never seen the code - so the bot answers "код не найден".
			if (response.status === 409 || /conflict/i.test(body.description ?? "")) {
				consoleLogger.error(
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
	const configured = botUsername()
	if (configured) return configured
	const me = await call<{ username?: string }>("getMe", {})
	const name = me?.username ?? ""
	// Cached, so every link built afterwards carries a real bot name instead of
	// `t.me/?start=CODE` - a link that opens Telegram search and looks, to the
	// person tapping it, exactly like a broken bot.
	if (name) rememberBotUsername(name)
	return name
}

// -------------------------------------------------------------- handlers ---

const SHARE_KEYBOARD: ReplyMarkup = {
	keyboard: [[{ text: "📱 Поделиться контактом", request_contact: true }]],
	resize_keyboard: true,
	one_time_keyboard: true,
}

const HIDE_KEYBOARD: ReplyMarkup = { remove_keyboard: true }

/** ROUND 11. Plain reply buttons, not an inline keyboard, so that the poller
 * can keep `allowed_updates: ["message"]` and no callback plumbing is needed. */
const ALLOW_TEXT = "✅ Разрешить вход"
const DENY_TEXT = "❌ Отклонить"
const LOGIN_KEYBOARD: ReplyMarkup = {
	keyboard: [[{ text: ALLOW_TEXT }, { text: DENY_TEXT }]],
	resize_keyboard: true,
	one_time_keyboard: true,
}

/** Human names for the four client kinds `linkAuth` knows about. */
const CLIENT_NAMES: Record<string, string> = {
	windows: "приложение на Windows",
	android: "приложение на Android",
	extension: "расширение для браузера",
	web: "сайт",
}

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

// ------------------------------------------------------- sign-in by link ---

function rememberLogin(chatId: number, code: string): void {
	chatLogins.set(chatId, { code, at: Date.now() })
	for (const [chat, entry] of chatLogins) {
		if (Date.now() - entry.at > CHAT_TOKEN_TTL_MS) chatLogins.delete(chat)
	}
}

function takeLogin(chatId: number): string | null {
	const entry = chatLogins.get(chatId)
	if (!entry) return null
	// A link lives five minutes server-side; anything older is already dead.
	if (Date.now() - entry.at > CHAT_TOKEN_TTL_MS) {
		chatLogins.delete(chatId)
		return null
	}
	return entry.code
}

async function handleLoginStart(message: TelegramMessage, rawCode: string): Promise<void> {
	const chatId = message.chat.id
	const code = rawCode.trim().toUpperCase()

	if (!loginBridge) {
		await sendTelegramMessage(
			chatId,
			"Подтверждение входа сейчас недоступно в боте.\n\n" +
				"Вернитесь в приложение и подтвердите вход на сайте — там та же кнопка.",
			HIDE_KEYBOARD,
		)
		return
	}

	const pending = await loginBridge.describe(code)
	if (!pending || pending.status !== "pending") {
		chatLogins.delete(chatId)
		await sendTelegramMessage(
			chatId,
			"Эта ссылка для входа неизвестна или уже истекла.\n\n" +
				"Нажмите «Войти через Telegram» в приложении ещё раз — ссылка живёт 5 минут.",
			HIDE_KEYBOARD,
		)
		return
	}

	rememberLogin(chatId, code)

	// Name what is asking. A confirmation prompt that does not say who is asking
	// is not consent, it is a habit - and habits are what phishing relies on.
	const what = CLIENT_NAMES[pending.client] ?? pending.client
	const where = pending.deviceName ? `\nУстройство: <b>${pending.deviceName}</b>` : ""
	const from = pending.ip ? `\nIP: <b>${pending.ip}</b>` : ""

	await sendTelegramMessage(
		chatId,
		`Запрос на вход в <b>GlukVPN</b>.\n\nОткуда: ${what}${where}${from}\n` +
			`Код: <b>${code}</b>\n\n` +
			"Если это не вы — нажмите «Отклонить». Разрешение действует один раз.",
		LOGIN_KEYBOARD,
	)
}

async function handleLoginDecision(message: TelegramMessage, allow: boolean): Promise<void> {
	const chatId = message.chat.id
	const from = message.from
	const code = takeLogin(chatId)

	if (!code || !from || !loginBridge) {
		await sendTelegramMessage(
			chatId,
			"Не вижу активного запроса на вход. Начните заново из приложения.",
			HIDE_KEYBOARD,
		)
		return
	}

	chatLogins.delete(chatId)

	if (!allow) {
		await loginBridge.deny(code)
		await sendTelegramMessage(
			chatId,
			"Вход отклонён. Приложение об этом уже знает.\n\n" +
				"Если запрос был не ваш — стоит сменить пароль на сайте.",
			HIDE_KEYBOARD,
		)
		return
	}

	const outcome = await loginBridge.approve({
		userCode: code,
		telegramId: String(from.id),
	})

	if (outcome.ok) {
		await sendTelegramMessage(
			chatId,
			`✅ Вход разрешён${outcome.username ? `: <b>${outcome.username}</b>` : ""}.\n\n` +
				"Возвращайтесь в приложение — оно уже вошло.",
			HIDE_KEYBOARD,
		)
		return
	}

	const reasons: Record<string, string> = {
		not_linked:
			"Этот Telegram не привязан ни к одному аккаунту GlukVPN.\n\n" +
			"Привяжите его в личном кабинете на vpn.gluk.tech, раздел «Безопасность».",
		disabled: "Аккаунт отключён. Напишите в поддержку.",
		expired: "Ссылка истекла. Нажмите «Войти через Telegram» в приложении ещё раз.",
		already: "Эта ссылка уже использована.",
		unknown: "Ссылка неизвестна или уже истекла.",
	}
	await sendTelegramMessage(
		chatId,
		(outcome.reason ? reasons[outcome.reason] : undefined) ?? reasons.unknown!,
		HIDE_KEYBOARD,
	)
}

/**
 * What to say when a payload minted by the other control plane lands here.
 *
 * Worth a message of its own: "код не найден" was technically true and
 * completely misleading - the code exists, in the other channel's database,
 * and no amount of retrying or hurrying could ever have helped.
 */
function foreignChannelText(minted: ReleaseChannel): string {
	return (
		`Эта ссылка выдана каналом <b>${channelLabel(minted)}</b>, а этот бот ` +
		`отвечает на канале <b>${channelLabel(config.CHANNEL)}</b>.\n\n` +
		"Код хранится в базе того канала, который его выдал, поэтому здесь его " +
		"действительно нет — дело не в сроке действия.\n\n" +
		`Откройте сайт или приложение на канале ${channelLabel(config.CHANNEL)} ` +
		"и повторите. Вход можно подтвердить и на сайте — там канал передаётся " +
		"в самой ссылке."
	)
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

	// ROUND 27: the payload now names the control plane that minted it
	// (`<TOKEN>_beta`), so a code that reaches the wrong bot gets the real
	// reason instead of "not found". An untagged payload counts as local, which
	// keeps every link issued before this change working.
	const payload = parseStartPayload(argument)
	if (payload.channel !== config.CHANNEL) {
		await sendTelegramMessage(chatId, foreignChannelText(payload.channel), HIDE_KEYBOARD)
		return
	}

	// ROUND 11: `/start login-XXXX-XXXX` is a sign-in confirmation, not a
	// sign-up. Checked before the token path so a login code can never be
	// mistaken for a registration token.
	if (payload.value.toLowerCase().startsWith(LOGIN_PREFIX)) {
		await handleLoginStart(message, payload.value.slice(LOGIN_PREFIX.length))
		return
	}

	rememberToken(chatId, payload.value.toUpperCase())
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
	}).catch((error: unknown) => {
		if (error instanceof HttpError && error.code === "registration_disabled") return { ok: false, reason: "registration_disabled" } as const
		throw error
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
		registration_disabled: "Регистрация временно приостановлена. Попробуйте позже.",
		// ROUND 17: this used to talk only about registration, which is wrong for
		// the case the user actually hits - linking Telegram to an account that
		// already exists, from the cabinet.
		//
		// ROUND 27: the channel trap it went on to describe is now prevented
		// instead of explained - only the owning channel polls the bot, and a
		// tagged payload from the other one is answered by `foreignChannelText`.
		// What can still reach this branch is a code typed in by hand, so the
		// channel is still named.
		unknown:
			"Код не найден или уже истёк.\n\n" +
			"Если привязываете Telegram к готовому аккаунту — откройте личный " +
			"кабинет на vpn.gluk.tech, раздел «Безопасность», и нажмите " +
			"«Привязать Telegram» заново: ссылка передаёт код сама.\n\n" +
			`Этот бот отвечает на канале <b>${channelLabel(config.CHANNEL)}</b> — ` +
			"код, выданный другим каналом, здесь не найдётся.",
		email_pending: "Сначала подтвердите почту кодом на сайте, потом возвращайтесь сюда.",
		phone_taken: "На этот номер уже зарегистрирован аккаунт. Воспользуйтесь входом или восстановлением пароля.",
		telegram_taken: "Этот Telegram уже привязан к другому аккаунту.",
	}
	const text =
		(outcome.reason ? reasons[outcome.reason] : undefined) ||
		reasons.unknown ||
		"Код не найден или уже истёк."
	await sendTelegramMessage(chatId, text, HIDE_KEYBOARD)
}

async function handleMessage(message: TelegramMessage): Promise<void> {
	if (message.contact) {
		await handleContact(message)
		return
	}

	const text = (message.text ?? "").trim()
	if (!text) return

	// ROUND 11: the two sign-in buttons. Matched first, and only while this chat
	// actually has a pending request, so the words are inert the rest of the time.
	if (chatLogins.has(message.chat.id) && (text === ALLOW_TEXT || text === DENY_TEXT)) {
		await handleLoginDecision(message, text === ALLOW_TEXT)
		return
	}

	if (text.startsWith("/start")) {
		await handleStart(message, text.slice("/start".length).trim())
		return
	}
	if (text.startsWith("/cancel")) {
		chatTokens.delete(message.chat.id)
		const pendingLogin = chatLogins.get(message.chat.id)
		if (pendingLogin && loginBridge) await loginBridge.deny(pendingLogin.code)
		chatLogins.delete(message.chat.id)
		await sendTelegramMessage(message.chat.id, "Отменил. Ничего не сохранено.", HIDE_KEYBOARD)
		return
	}
	if (text.startsWith("/help")) {
		await sendTelegramMessage(
			message.chat.id,
			"Бот подтверждает аккаунт <b>GlukVPN</b> и вход в него.\n\n" +
				"/start — начать заново\n/cancel — отменить\n\n" +
				"Поддержка: <b>vpn.gluk.tech</b>",
			HIDE_KEYBOARD,
		)
		return
	}

	// A bare code pasted by hand still works - some people will do that.
	if (/^[A-Z0-9]{8,12}(?:_(?:prod|beta))?$/i.test(text)) {
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
 * Start long polling. Safe to call when the token is missing, or when this
 * channel does not own the bot: it simply does nothing, so prod and beta can
 * share one code path and one env template.
 */
export function startTelegramBot(logger: Logger = consoleLogger): void {
	if (!telegramConfigured()) {
		logger.info({}, "telegram_bot_disabled_no_token")
		return
	}
	// ROUND 27: one token, one poller. Both channels used to start the same bot.
	// Telegram answers the loser of that race with 409 and hands each update to
	// whoever happens to win, so a large share of sign-ups and sign-ins were
	// answered by a stack whose database had never seen the code - the whole
	// story behind "Код не найден" and "Эта ссылка ... неизвестна".
	if (!botOwnedHere()) {
		logger.warn(
			{ channel: config.CHANNEL, botChannel: botChannel() },
			"telegram_bot_disabled_foreign_channel",
		)
		return
	}
	if (running) return
	running = true

	void (async () => {
		const username = await resolveBotUsername()
		logger.info({ username, channel: config.CHANNEL }, "telegram_bot_started")

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
