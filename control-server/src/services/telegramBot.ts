/**
 * The GlukVPN Telegram bot. No framework, no webhook.
 *
 * It started as three things and now does five; the first three are unchanged,
 * because they are what sign-up and sign-in depend on:
 *
 *   1. `/start <token>` - the deep link from the sign-up page. The bot answers
 *      with a "Share my contact" button.
 *   2. the shared contact - the bot checks the contact really belongs to the
 *      person sending it, then hands the phone number to the registration
 *      service, which finishes the account.
 *   3. `/start login-<CODE>` - confirming a sign-in started by a client (see
 *      `services/linkAuth.ts`). The bot shows what is asking, and the user
 *      allows or refuses it in the chat.
 *   4. the account menu - tariff, term, traffic, devices, VPN state and buying
 *      a subscription, in the chat (`telegramAccount.ts`).
 *   5. the administration side - registrations, purchases, warnings and the
 *      daily digest, in one allowed group (`telegramAdmin.ts`).
 *
 * Point 3 is worth a word on why it is safe. The chat is already bound to an
 * account: sign-up only completes when this exact Telegram user shares their
 * phone number, so `telegramId` is a proven identity, not a self-claimed one.
 * That makes the bot a better confirmation surface than a browser session -
 * approving requires the person to hold the phone that owns the account, and
 * the code in the deep link authorises nothing on its own.
 *
 * The same fact is what makes points 4 and 5 possible at all: a chat maps to
 * exactly one account, so no menu here ever has to ask who is talking.
 *
 * It also delivers verification codes (password reset over Telegram), which is
 * why `sendTelegramMessage` is re-exported.
 *
 * Long polling, not a webhook: a webhook needs a public HTTPS route, a secret
 * path and an Nginx rule, and it breaks silently whenever the certificate or
 * the domain changes. getUpdates needs nothing but an outbound connection, so
 * it works identically on the server, on a laptop and on beta - and if the
 * process dies, Telegram simply queues the updates until it comes back.
 *
 * Two security rules worth stating out loud:
 *
 *   - `contact.user_id` must equal `message.from.id`. Telegram lets anyone
 *     forward a contact from their address book, so without that check a user
 *     could register an account against someone else's phone number - which
 *     would defeat the entire point of that step.
 *   - group chats are refused (#094). The bot answers in private, plus one
 *     configured administration group, and leaves anything else on sight.
 */

import { config } from "../config"
import { HttpError } from "../lib/errors"
import { attachTelegram, normalizePhone } from "./registration"
import {
	type BotView,
	accountMenuEnabled,
	findUserByTelegramId,
	handleAccountCallback,
	helpView,
	notLinkedView,
	renderView,
	syncTelegramProfile,
} from "./telegramAccount"
import { handleAdminCommand, isAdminGroup } from "./telegramAdmin"
import {
	type Logger,
	type ReplyMarkup,
	type TelegramCallbackQuery,
	type TelegramChat,
	type TelegramChatMemberUpdated,
	type TelegramMessage,
	type TelegramUpdate,
	answerCallbackQuery,
	callTelegram,
	consoleLogger,
	leaveChat,
	resolveBotUsername,
	sendTelegramMessage,
} from "./telegramApi"
import type { ReleaseChannel } from "./telegramLinks"
import {
	LOGIN_PREFIX,
	botChannel,
	botOwnedHere,
	channelLabel,
	parseStartPayload,
	telegramConfigured,
} from "./telegramLinks"

// The link builders live in `telegramLinks.ts`, which also owns the channel
// tag: the registration service needs them too, and importing this file from
// there would be a cycle. The HTTP calls live in `telegramApi.ts` for the same
// reason - the admin and account modules send messages and are imported here.
// Both are re-exported so existing importers keep working untouched.
export { botUsername, telegramLoginLink } from "./telegramLinks"
export { resolveBotUsername, sendTelegramMessage } from "./telegramApi"
export type { ReplyMarkup } from "./telegramApi"

/** Telegram holds the request open; 50s is comfortably inside its limit. */
const POLL_TIMEOUT_SEC = 50

/** How long a `/start <token>` stays valid inside a chat, in ms. */
const CHAT_TOKEN_TTL_MS = 10 * 60 * 1000

/** Chat kinds that are not one person talking to the bot. */
const GROUP_TYPES = new Set(["group", "supergroup", "channel"])

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

let running = false

// -------------------------------------------------------------- keyboards --

const SHARE_KEYBOARD: ReplyMarkup = {
	keyboard: [[{ text: "📱 Поделиться контактом", request_contact: true }]],
	resize_keyboard: true,
	one_time_keyboard: true,
}

const HIDE_KEYBOARD: ReplyMarkup = { remove_keyboard: true }

/** ROUND 11. Plain reply buttons rather than an inline keyboard, so a sign-in
 * confirmation cannot be mistaken for - or replayed from - a menu card. */
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

/** Which menu each private command opens. */
const MENU_COMMANDS: Record<string, string> = {
	"/menu": "menu",
	"/account": "account",
	"/traffic": "traffic",
	"/devices": "devices",
	"/vpn": "vpn",
	"/buy": "buy",
	"/subscription": "buy",
}

async function sendView(chatId: number, view: BotView): Promise<void> {
	await sendTelegramMessage(chatId, view.text, view.markup)
}

// ----------------------------------------------------------- chat memory ---

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
				"Он подтверждает, что аккаунт заводит живой человек, а потом становится вашим личным кабинетом.\n\n" +
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
		// #100: the account exists as of this second, so the name, @username and
		// avatar are stored while the person is right here - not on some later
		// background sweep.
		const account = await findUserByTelegramId(from.id)
		if (account) await syncTelegramProfile({ user: account, from, force: true }).catch(() => false)
		await sendTelegramMessage(
			chatId,
			outcome.kind === "registered"
				? "✅ Готово, аккаунт создан.\n\n" +
					`Логин: <b>${outcome.username}</b>\n\n` +
					"Возвращайтесь на сайт или в приложение и входите с почтой и паролем.\n\n" +
					"А здесь теперь работает /menu — тариф, трафик, устройства и оплата."
				: "✅ Telegram привязан к аккаунту " + `<b>${outcome.username}</b>.\n\n` + "Наберите /menu — в боте есть тариф, трафик, устройства и оплата.",
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

// --------------------------------------------------------------- groups ----

/**
 * #094: the bot is a private-chat bot.
 *
 * "Allow Groups?" in @BotFather is the front door and should stay off; this is
 * the lock behind it, because the setting can be flipped back by anybody with
 * the token and says nothing about groups the bot is already in. Leaving on
 * sight also means a group can never become an unattended surface where one
 * member watches another member's confirmation codes go by.
 */
async function refuseGroup(chat: TelegramChat, logger: Logger): Promise<void> {
	await sendTelegramMessage(
		chat.id,
		"Этот бот работает только в личных сообщениях — там подтверждения и данные аккаунта видны только вам.\n\n" +
			"Напишите мне напрямую: тариф, трафик, устройства и оплата — всё там.",
	)
	await leaveChat(chat.id)
	logger.warn({ chatId: chat.id, type: chat.type, title: chat.title }, "telegram_group_refused")
}

async function handleChatMember(update: TelegramChatMemberUpdated, logger: Logger): Promise<void> {
	const chat = update.chat
	if (!GROUP_TYPES.has(chat.type)) return
	const status = update.new_chat_member.status
	// "left" / "kicked" mean the bot is already out; nothing to do.
	if (status !== "member" && status !== "administrator" && status !== "restricted") return
	if (isAdminGroup(chat.id) || config.TELEGRAM_ALLOW_GROUPS) {
		logger.info({ chatId: chat.id, title: chat.title }, "telegram_group_allowed")
		return
	}
	await refuseGroup(chat, logger)
}

// -------------------------------------------------------------- messages ---

async function handleMessage(message: TelegramMessage, logger: Logger): Promise<void> {
	const chat = message.chat
	const text = (message.text ?? "").trim()

	if (GROUP_TYPES.has(chat.type)) {
		// #095: the one allowed group. Commands are answered, the rest of the
		// conversation is none of the bot's business.
		if (isAdminGroup(chat.id)) {
			if (text.startsWith("/")) await handleAdminCommand(text, chat.id)
			return
		}
		if (config.TELEGRAM_ALLOW_GROUPS) return
		await refuseGroup(chat, logger)
		return
	}

	if (message.contact) {
		await handleContact(message)
		return
	}
	if (!text) return

	// ROUND 11: the two sign-in buttons. Matched first, and only while this chat
	// actually has a pending request, so the words are inert the rest of the time.
	if (chatLogins.has(chat.id) && (text === ALLOW_TEXT || text === DENY_TEXT)) {
		await handleLoginDecision(message, text === ALLOW_TEXT)
		return
	}

	const command = text.startsWith("/")
		? (text.split(/\s+/)[0] ?? "").toLowerCase().replace(/@.*$/, "")
		: ""
	const startArgument = command === "/start" ? text.slice("/start".length).trim() : ""
	const bareStart = command === "/start" && startArgument === ""

	// #100: the only place a profile is refreshed - while the person is already
	// talking to the bot. `syncTelegramProfile` keeps its own 24-hour window,
	// and a bare /start skips it, which is exactly what somebody who has just
	// changed their picture will send. Nothing polls in the background: an
	// account silent for three weeks costs zero requests.
	let account = message.from ? await findUserByTelegramId(message.from.id) : null
	if (account && message.from) {
		const changed = await syncTelegramProfile({
			user: account,
			from: message.from,
			force: bareStart,
		}).catch(() => false)
		if (changed) account = (await findUserByTelegramId(message.from.id)) ?? account
	}
	const menus = accountMenuEnabled()

	if (command === "/start") {
		// A linked subscriber pressing /start wants their account, not the
		// sign-up instructions they finished weeks ago.
		if (bareStart && account && menus) {
			await sendView(chat.id, await renderView("menu", account))
			return
		}
		await handleStart(message, startArgument)
		return
	}

	if (command === "/cancel") {
		chatTokens.delete(chat.id)
		const pendingLogin = chatLogins.get(chat.id)
		if (pendingLogin && loginBridge) await loginBridge.deny(pendingLogin.code)
		chatLogins.delete(chat.id)
		await sendTelegramMessage(chat.id, "Отменил. Ничего не сохранено.", HIDE_KEYBOARD)
		return
	}

	const view = MENU_COMMANDS[command]
	if (view) {
		if (!menus) {
			await sendTelegramMessage(
				chat.id,
				"Управление аккаунтом в боте отключено. Откройте личный кабинет на vpn.gluk.tech.",
				HIDE_KEYBOARD,
			)
			return
		}
		await sendView(chat.id, account ? await renderView(view, account) : notLinkedView())
		return
	}

	if (command === "/help") {
		if (account && menus) {
			await sendView(chat.id, helpView())
			return
		}
		await sendTelegramMessage(
			chat.id,
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

	if (account && menus) {
		await sendView(chat.id, await renderView("menu", account))
		return
	}
	await sendTelegramMessage(
		chat.id,
		"Не понял. Откройте ссылку со страницы регистрации — она передаёт код сама. " +
			"Или отправьте /help.",
	)
}

// ------------------------------------------------------------- callbacks ---

async function handleCallback(query: TelegramCallbackQuery): Promise<void> {
	const chat = query.message?.chat
	const data = (query.data ?? "").trim()
	if (!chat || chat.type !== "private" || !data) {
		await answerCallbackQuery({ id: query.id })
		return
	}
	if (!accountMenuEnabled()) {
		await answerCallbackQuery({ id: query.id, text: "Меню отключено", showAlert: true })
		return
	}
	const account = await findUserByTelegramId(query.from.id)
	if (!account) {
		await answerCallbackQuery({
			id: query.id,
			text: "Этот Telegram не привязан к аккаунту",
			showAlert: true,
		})
		return
	}
	const outcome = await handleAccountCallback({
		data,
		user: account,
		chatId: chat.id,
		messageId: query.message?.message_id,
		from: query.from,
	})
	// A callback must always be answered, or the button spins in the client for
	// a minute and the person taps it again.
	await answerCallbackQuery({
		id: query.id,
		...(typeof outcome === "string" ? { text: outcome } : {}),
	})
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
			const updates = await callTelegram<TelegramUpdate[]>(
				"getUpdates",
				{
					offset,
					timeout: POLL_TIMEOUT_SEC,
					// `callback_query` for the menus, `my_chat_member` so a group the
					// bot is dragged into is left immediately (#094).
					allowed_updates: ["message", "callback_query", "my_chat_member"],
				},
				logger,
			)

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
				try {
					if (update.my_chat_member) {
						await handleChatMember(update.my_chat_member, logger)
						continue
					}
					if (update.callback_query) {
						await handleCallback(update.callback_query)
						continue
					}
					const message = update.message ?? update.edited_message
					if (!message) continue
					await handleMessage(message, logger)
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
