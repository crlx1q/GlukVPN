/**
 * The account side of the bot: everything a subscriber can see and change
 * from Telegram (#096, #097, #099, #100).
 *
 * Design notes worth keeping in mind when editing this file:
 *
 * - **The server answers, the chat only draws.** Every number here is read
 *   from the same services the apps and the site call - `quotaStatus`,
 *   `resolveEntitlement`, the sessions table. There is no Telegram-specific
 *   copy of the truth, so the bot cannot drift from the app (#099).
 * - **Actions go through the same functions as the REST routes.** Removing a
 *   device calls `revokeDeviceAccess` (which bumps `token_version`, closes its
 *   sessions and asks the nodes to drop the peer) and disconnecting calls
 *   `closeSessionsForUser`. That is what makes an action taken in the chat
 *   visible in every other client seconds later, rather than only in the chat.
 * - **One card, redrawn.** Menus are edited in place instead of appending a new
 *   message per tap, so the conversation stays readable.
 * - **Nothing destructive without a second tap.** Removing a device asks first;
 *   it kicks that device off the VPN and cannot be undone from the chat.
 */
import type { User } from "@prisma/client"
import { config } from "../config"
import { prisma } from "../prisma"
import {
	activeProviderName,
	createOrder,
	listPlans,
	priceLabel,
	reconcilePendingOrders,
	settlementCurrency,
} from "./billing"
import { revokeDeviceAccess } from "./deviceAccess"
import { requestPolicySync } from "./policy"
import { resolvePlanPrice } from "./pricing"
import { type QuotaStatus, quotaStatus } from "./quota"
import { closeSessionsForUser } from "./sessions"
import {
	type InlineButton,
	type ReplyMarkup,
	type TelegramUser,
	editTelegramMessage,
	escapeHtml,
	formatBytes,
	localDate,
	localTime,
	profilePhotoId,
	sendTelegramMessage,
} from "./telegramApi"

/** #100: how long a fetched avatar is trusted before it is fetched again. */
export const PROFILE_TTL_MS = 24 * 60 * 60 * 1000

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type BotView = { text: string; markup: ReplyMarkup }

export function accountMenuEnabled(): boolean {
	return config.TELEGRAM_ACCOUNT_MENU_ENABLED
}

export async function findUserByTelegramId(telegramId: string | number): Promise<User | null> {
	return prisma.user.findUnique({ where: { telegramId: String(telegramId) } })
}

function siteUrl(path = "/app/"): string {
	return `${config.SITE_BASE_URL.replace(/\/+$/, "")}${path}`
}

function errorText(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error ?? "")
	return message.trim() || "Не удалось выполнить действие"
}

function asDate(value: unknown): Date | null {
	if (value instanceof Date) return value
	if (typeof value === "string" || typeof value === "number") {
		const date = new Date(value)
		return Number.isNaN(date.getTime()) ? null : date
	}
	return null
}

// -------------------------------------------------------------- keyboards --

const MENU_BUTTON: InlineButton = { text: "⬅️ Меню", callback_data: "menu" }

function menuMarkup(): ReplyMarkup {
	return {
		inline_keyboard: [
			[
				{ text: "👤 Аккаунт", callback_data: "account" },
				{ text: "📊 Трафик", callback_data: "traffic" },
			],
			[
				{ text: "💻 Устройства", callback_data: "devices" },
				{ text: "🔌 VPN", callback_data: "vpn" },
			],
			[{ text: "💳 Подписка", callback_data: "buy" }],
			[{ text: "❓ Помощь", callback_data: "help" }],
		],
	}
}

function viewMarkup(rows: InlineButton[][]): ReplyMarkup {
	return { inline_keyboard: [...rows, [MENU_BUTTON]] }
}

// ------------------------------------------------------------ page pieces --

function planLine(entitlement: { planName: string; subscribed: boolean; expiresAt: unknown; daysLeft: unknown }): string {
	const name = `<b>${escapeHtml(entitlement.planName)}</b>`
	const expiresAt = asDate(entitlement.expiresAt)
	if (!entitlement.subscribed || !expiresAt) return `Тариф: ${name}`
	const days = typeof entitlement.daysLeft === "number" ? ` (${entitlement.daysLeft} дн.)` : ""
	return `Тариф: ${name} · до ${localDate(expiresAt)}${days}`
}

function trafficLine(status: QuotaStatus): string {
	const used = formatBytes(status.usedBytes)
	if (status.limitBytes === null) return `Трафик: ${used} · без лимита`
	const percent = Math.round(status.usedFraction * 100)
	const tail = status.exceeded ? " — лимит исчерпан" : ""
	return `Трафик: ${used} из ${formatBytes(status.limitBytes)} (${percent}%)${tail}`
}

const PLATFORM_SHORT: Record<string, string> = {
	android: "Android",
	ios: "iOS",
	windows: "Windows",
	macos: "macOS",
	linux: "Linux",
	extension: "браузер",
	web: "сайт",
}

function platformLabel(platform: string | null | undefined): string {
	const key = (platform ?? "").trim().toLowerCase()
	if (!key) return "—"
	return PLATFORM_SHORT[key] ?? escapeHtml(key)
}

type LiveSession = {
	id: string
	deviceId: string
	connectedAt: Date
	bytes: number
	transport: string
	nodeLabel: string
	deviceName: string
}

/**
 * Open tunnels as the nodes report them.
 *
 * Read from `sessions` rather than from anything the phone said: "connected"
 * in the chat has to mean the same thing the server would enforce.
 */
async function liveSessions(userId: string): Promise<LiveSession[]> {
	const rows = await prisma.session.findMany({
		where: { userId, status: { in: ["PENDING", "ACTIVE"] } },
		orderBy: { connectedAt: "desc" },
		take: 5,
		select: {
			id: true,
			nodeId: true,
			deviceId: true,
			connectedAt: true,
			bytesRx: true,
			bytesTx: true,
			transport: true,
		},
	})
	if (rows.length === 0) return []
	const [nodes, devices] = await Promise.all([
		prisma.vpnNode.findMany({
			where: { id: { in: rows.map((row) => row.nodeId) } },
			select: { id: true, name: true, country: true, city: true },
		}),
		prisma.device.findMany({
			where: { id: { in: rows.map((row) => row.deviceId) } },
			select: { id: true, deviceName: true },
		}),
	])
	return rows.map((row) => {
		const node = nodes.find((item) => item.id === row.nodeId)
		const device = devices.find((item) => item.id === row.deviceId)
		return {
			id: row.id,
			deviceId: row.deviceId,
			connectedAt: row.connectedAt,
			bytes: Number(row.bytesRx) + Number(row.bytesTx),
			transport: row.transport,
			// The node's own name ("de-01") is internal; a subscriber gets the
			// place, which is the only part they chose.
			nodeLabel: node ? node.city || node.country || node.name : "—",
			deviceName: device?.deviceName ?? "устройство",
		}
	})
}

async function activeDeviceCount(userId: string): Promise<number> {
	return prisma.device.count({ where: { userId, status: "ACTIVE" } })
}

// ------------------------------------------------------------------ views --

export async function menuView(user: User): Promise<BotView> {
	const status = await quotaStatus(user.id)
	const name = user.telegramFirstName?.trim() || user.username
	return {
		text: [
			`👋 Привет, <b>${escapeHtml(name)}</b>!`,
			"",
			planLine(status.entitlement),
			trafficLine(status),
			"",
			"Выберите раздел ниже.",
		].join("\n"),
		markup: menuMarkup(),
	}
}

/** #096: plan, term, traffic, devices and VPN state on one card. */
export async function accountView(user: User): Promise<BotView> {
	const [status, devices, sessions] = await Promise.all([
		quotaStatus(user.id),
		activeDeviceCount(user.id),
		liveSessions(user.id),
	])
	const entitlement = status.entitlement
	const lines = [
		"👤 <b>Аккаунт</b>",
		`Логин: <b>${escapeHtml(user.username)}</b> · #${escapeHtml(user.publicId)}`,
		planLine(entitlement),
		trafficLine(status),
		`Сброс трафика: ${localDate(status.period.end)}`,
		`Устройства: ${devices} из ${entitlement.maxDevices}`,
		`Одновременные подключения: ${sessions.length} из ${entitlement.maxSessions}`,
	]
	if (entitlement.speedLimitMbps) lines.push(`Скорость: до ${entitlement.speedLimitMbps} Мбит/с`)
	lines.push(
		sessions.length > 0
			? `VPN: подключено — ${escapeHtml(sessions[0]!.nodeLabel)}`
			: "VPN: нет активных подключений",
	)
	if (user.telegramUsername) lines.push(`Telegram: @${escapeHtml(user.telegramUsername)}`)
	return {
		text: lines.join("\n"),
		markup: viewMarkup([
			[
				{ text: "📊 Трафик", callback_data: "traffic" },
				{ text: "💻 Устройства", callback_data: "devices" },
			],
			[
				{ text: "🔌 VPN", callback_data: "vpn" },
				{ text: "💳 Подписка", callback_data: "buy" },
			],
			[{ text: "🔄 Обновить", callback_data: "account" }],
		]),
	}
}

/** #096: the quota window, and where it went. */
export async function trafficView(user: User): Promise<BotView> {
	const status = await quotaStatus(user.id)
	const perDevice = await prisma.trafficUsageBucket.groupBy({
		by: ["deviceId", "deviceName"],
		where: {
			userId: user.id,
			bucketStart: { gte: status.period.start, lt: status.period.end },
		},
		_sum: { uploadBytes: true, downloadBytes: true },
	})
	const rows = perDevice
		.map((row) => ({
			name: row.deviceName,
			bytes: Number(row._sum.uploadBytes ?? BigInt(0)) + Number(row._sum.downloadBytes ?? BigInt(0)),
		}))
		.filter((row) => row.bytes > 0)
		.sort((a, b) => b.bytes - a.bytes)
		.slice(0, 6)
	const lines = [
		"📊 <b>Трафик</b>",
		`Период: ${localDate(status.period.start)} — ${localDate(status.period.end)}`,
		trafficLine(status),
	]
	if (status.remainingBytes !== null) lines.push(`Осталось: ${formatBytes(status.remainingBytes)}`)
	if (status.entitlement.speedLimitMbps) {
		lines.push(`Скорость: до ${status.entitlement.speedLimitMbps} Мбит/с`)
	}
	if (rows.length > 0) {
		lines.push("", "По устройствам:")
		for (const row of rows) lines.push(`• ${escapeHtml(row.name)} — ${formatBytes(row.bytes)}`)
	} else {
		lines.push("", "В этом периоде трафика ещё не было.")
	}
	return {
		text: lines.join("\n"),
		markup: viewMarkup([[{ text: "🔄 Обновить", callback_data: "traffic" }]]),
	}
}

/** #096: devices, with a way to remove one. */
export async function devicesView(user: User): Promise<BotView> {
	const [status, devices, sessions] = await Promise.all([
		quotaStatus(user.id),
		prisma.device.findMany({
			where: { userId: user.id, status: "ACTIVE" },
			orderBy: { lastSeen: "desc" },
			take: 10,
			select: { id: true, deviceName: true, platform: true, lastSeen: true, createdAt: true },
		}),
		liveSessions(user.id),
	])
	const online = new Set(sessions.map((session) => session.deviceId))
	const lines = [`💻 <b>Устройства</b> — ${devices.length} из ${status.entitlement.maxDevices}`]
	if (devices.length === 0) {
		lines.push("", "Пока ни одного. Войдите в приложение — устройство добавится само.")
	} else {
		lines.push("")
		for (const device of devices) {
			const when = online.has(device.id)
				? "сейчас подключено"
				: device.lastSeen
					? `было в сети ${localTime(device.lastSeen)}`
					: `добавлено ${localDate(device.createdAt)}`
			lines.push(
				`${online.has(device.id) ? "🟢" : "⚪️"} <b>${escapeHtml(device.deviceName)}</b> · ${platformLabel(device.platform)} · ${when}`,
			)
		}
		lines.push("", "Кнопка с крестиком отвязывает устройство и сразу отключает его от VPN.")
	}
	const rows: InlineButton[][] = devices.map((device) => [
		{ text: `❌ ${device.deviceName}`.slice(0, 40), callback_data: `dev:ask:${device.id}` },
	])
	rows.push([{ text: "🔄 Обновить", callback_data: "devices" }])
	return { text: lines.join("\n"), markup: viewMarkup(rows) }
}

async function deviceConfirmView(user: User, deviceId: string): Promise<BotView> {
	const device = await prisma.device.findFirst({
		where: { id: deviceId, userId: user.id },
		select: { deviceName: true, platform: true },
	})
	if (!device) return devicesView(user)
	return {
		text: [
			`❌ <b>Отвязать устройство?</b>`,
			"",
			`<b>${escapeHtml(device.deviceName)}</b> · ${platformLabel(device.platform)}`,
			"",
			"Его сессия закроется, вход слетит, и слот освободится. Снова войти можно в любой момент.",
		].join("\n"),
		markup: {
			inline_keyboard: [
				[{ text: "✅ Да, отвязать", callback_data: `dev:rm:${deviceId}` }],
				[{ text: "⬅️ Назад", callback_data: "devices" }],
			],
		},
	}
}

/** #096: VPN state, and the switch to cut it. */
export async function vpnView(user: User): Promise<BotView> {
	const [status, sessions] = await Promise.all([quotaStatus(user.id), liveSessions(user.id)])
	const lines = [
		"🔌 <b>VPN</b>",
		`Подключения: ${sessions.length} из ${status.entitlement.maxSessions}`,
	]
	if (sessions.length === 0) {
		lines.push(
			"",
			"Сейчас подключений нет. Включать VPN нужно в приложении — здесь видно состояние и можно отключить.",
		)
		if (status.exceeded) lines.push("", "⚠️ Лимит трафика исчерпан — подключение не откроется.")
		return {
			text: lines.join("\n"),
			markup: viewMarkup([[{ text: "🔄 Обновить", callback_data: "vpn" }]]),
		}
	}
	lines.push("")
	for (const session of sessions) {
		lines.push(
			`🟢 ${escapeHtml(session.nodeLabel)} · ${escapeHtml(session.deviceName)}`,
			`   с ${localTime(session.connectedAt)} · ${formatBytes(session.bytes)} · ${escapeHtml(session.transport)}`,
		)
	}
	return {
		text: lines.join("\n"),
		markup: viewMarkup([
			[{ text: "⛔ Отключить всё", callback_data: "vpn:stop" }],
			[{ text: "🔄 Обновить", callback_data: "vpn" }],
		]),
	}
}

/** #097: the catalogue, priced in the currency the gateway will actually charge. */
export async function plansView(user: User): Promise<BotView> {
	const [status, plans, pending] = await Promise.all([
		quotaStatus(user.id),
		listPlans(),
		prisma.order.findFirst({
			where: { userId: user.id, status: "PENDING" },
			orderBy: { createdAt: "desc" },
			include: { plan: true },
		}),
	])
	const lines = ["💳 <b>Подписка</b>", planLine(status.entitlement)]
	const rows: InlineButton[][] = []

	if (!activeProviderName()) {
		// Nothing to sell without a gateway; the site may still take a transfer.
		lines.push("", "Оплата в боте сейчас недоступна. Напишите нам или откройте сайт.")
		rows.push([{ text: "🌐 Открыть сайт", url: siteUrl("/pricing/") }])
		return { text: lines.join("\n"), markup: viewMarkup(rows) }
	}

	const settle = settlementCurrency()
	lines.push("", "Выберите тариф — после оплаты подписка включится автоматически.", "")
	for (const plan of plans) {
		const price = resolvePlanPrice(plan, settle)
		const label = priceLabel(price.priceMinor, price.currency)
		const traffic = plan.trafficGb ? `${plan.trafficGb} ГБ` : "без лимита"
		const speed = plan.speedMbps ? `${plan.speedMbps} Мбит/с` : "без ограничений"
		lines.push(
			`${plan.featured ? "⭐️" : "•"} <b>${escapeHtml(plan.name)}</b> · ${plan.days} дн. · ${escapeHtml(label)}`,
			`   ${plan.maxDevices} устр. · ${traffic} · ${speed}`,
		)
		rows.push([
			{ text: `${plan.name} · ${label}`.slice(0, 40), callback_data: `buy:${plan.code}` },
		])
	}
	if (pending) {
		// An attempt that was started and never finished: offer it back instead of
		// making a second order for the same thing.
		lines.push("", `🧾 Неоплаченный заказ: ${escapeHtml(pending.plan.name)} · ${escapeHtml(priceLabel(pending.amountMinor, pending.currency))}`)
		if (pending.paymentUrl) rows.push([{ text: "💳 Доплатить заказ", url: pending.paymentUrl }])
		rows.push([{ text: "🔄 Я оплатил", callback_data: `pay:${pending.id}` }])
	}
	return { text: lines.join("\n"), markup: viewMarkup(rows) }
}

/** #097: one order, one payment link, one "I have paid" button. */
async function checkoutView(user: User, planCode: string): Promise<BotView> {
	try {
		const { order, checkout } = await createOrder({ user, planCode, source: "telegram" })
		const label = priceLabel(order.amountMinor, order.currency)
		const rows: InlineButton[][] = []
		const lines = [
			`🧾 <b>${escapeHtml(order.plan.name)}</b> · ${order.plan.days} дн. · ${escapeHtml(label)}`,
		]
		if (checkout.paymentUrl) {
			rows.push([{ text: `💳 Оплатить ${label}`.slice(0, 40), url: checkout.paymentUrl }])
			lines.push(
				"",
				"Оплата пройдёт на странице платёжного сервиса. Подписка включится сама — обычно за несколько секунд.",
				"Если деньги ушли, а тариф не сменился — нажмите «Я оплатил».",
			)
		} else if (checkout.instructions) {
			lines.push("", escapeHtml(checkout.instructions))
		} else {
			lines.push("", "Заказ создан. Подписка включится после подтверждения оплаты.")
		}
		rows.push([{ text: "🔄 Я оплатил", callback_data: `pay:${order.id}` }])
		rows.push([{ text: "⬅️ Тарифы", callback_data: "buy" }])
		return { text: lines.join("\n"), markup: { inline_keyboard: rows } }
	} catch (error) {
		return {
			text: `Не удалось создать заказ: ${escapeHtml(errorText(error))}`,
			markup: viewMarkup([[{ text: "⬅️ Тарифы", callback_data: "buy" }]]),
		}
	}
}

export function helpView(): BotView {
	return {
		text: [
			"❓ <b>Помощь</b>",
			"",
			"/menu — главное меню",
			"/account — тариф, срок, трафик, устройства",
			"/traffic — расход трафика за период",
			"/devices — устройства и отключение лишних",
			"/vpn — активные подключения",
			"/buy — купить или продлить подписку",
			"",
			"Код из приложения можно прислать просто сообщением — это подтвердит вход или регистрацию.",
			"Включать сам VPN нужно в приложении: Telegram показывает состояние и умеет отключать.",
		].join("\n"),
		markup: viewMarkup([[{ text: "🌐 Личный кабинет", url: siteUrl() }]]),
	}
}

/** Shown when this Telegram account is not linked to any subscriber yet. */
export function notLinkedView(): BotView {
	return {
		text: [
			"Здесь будет ваш аккаунт GlukVPN — как только этот Telegram будет к нему привязан.",
			"",
			"Зарегистрируйтесь в приложении или на сайте — на шаге подтверждения вам дадут код, пришлите его сюда сообщением.",
			"После этого в боте откроются тариф, трафик, устройства и оплата.",
		].join("\n"),
		markup: { inline_keyboard: [[{ text: "🌐 Открыть сайт", url: siteUrl() }]] },
	}
}

/** Resolves a view by name, for both commands and callbacks. */
export async function renderView(name: string, user: User): Promise<BotView> {
	switch (name) {
		case "account":
			return accountView(user)
		case "traffic":
			return trafficView(user)
		case "devices":
			return devicesView(user)
		case "vpn":
			return vpnView(user)
		case "buy":
			return plansView(user)
		case "help":
			return helpView()
		default:
			return menuView(user)
	}
}

// -------------------------------------------------------------- callbacks --

async function draw(params: {
	chatId: string | number
	messageId?: number
	view: BotView
}): Promise<void> {
	if (params.messageId) {
		const edited = await editTelegramMessage({
			chatId: params.chatId,
			messageId: params.messageId,
			text: params.view.text,
			replyMarkup: params.view.markup,
		})
		if (edited) return
	}
	await sendTelegramMessage(params.chatId, params.view.text, params.view.markup)
}

/**
 * Handles one inline-button tap. Returns the toast to show on the button, or
 * undefined for a silent redraw; returns false when the data is not ours.
 */
export async function handleAccountCallback(params: {
	data: string
	user: User
	chatId: string | number
	messageId?: number
	from?: TelegramUser
}): Promise<string | undefined | false> {
	const { data, user, chatId, messageId } = params

	if (["menu", "account", "traffic", "devices", "vpn", "buy", "help"].includes(data)) {
		await draw({ chatId, messageId, view: await renderView(data, user) })
		return undefined
	}

	if (data.startsWith("dev:ask:")) {
		const deviceId = data.slice("dev:ask:".length)
		if (!UUID_RE.test(deviceId)) return "Устройство не найдено"
		await draw({ chatId, messageId, view: await deviceConfirmView(user, deviceId) })
		return undefined
	}

	if (data.startsWith("dev:rm:")) {
		const deviceId = data.slice("dev:rm:".length)
		if (!UUID_RE.test(deviceId)) return "Устройство не найдено"
		try {
			await revokeDeviceAccess(user.id, deviceId)
			// #099: the tokens are already invalid and the sessions are closed;
			// this is what makes the nodes drop the peer without waiting for the
			// next heartbeat, so the other clients see the new state at once.
			await requestPolicySync().catch(() => 0)
		} catch (error) {
			return errorText(error)
		}
		await draw({ chatId, messageId, view: await devicesView(user) })
		return "Устройство отвязано"
	}

	if (data === "vpn:stop") {
		const closed = await closeSessionsForUser(user.id, "telegram_request").catch(() => 0)
		await draw({ chatId, messageId, view: await vpnView(user) })
		return closed > 0 ? `Отключено: ${closed}` : "Активных подключений нет"
	}

	if (data.startsWith("buy:")) {
		const planCode = data.slice("buy:".length).trim().toLowerCase()
		if (!planCode) return "Тариф не найден"
		await draw({ chatId, messageId, view: await checkoutView(user, planCode) })
		return undefined
	}

	if (data.startsWith("pay:")) {
		const orderId = data.slice("pay:".length)
		if (!UUID_RE.test(orderId)) return "Заказ не найден"
		// The webhook is the primary path; this is the same belt the site pulls
		// when the browser comes back from the payment page.
		await reconcilePendingOrders(user).catch(() => [])
		const order = await prisma.order.findFirst({
			where: { id: orderId, userId: user.id },
			include: { plan: true },
		})
		if (!order) return "Заказ не найден"
		if (order.status === "PAID") {
			await draw({ chatId, messageId, view: await accountView(user) })
			return "Оплата получена, тариф активен"
		}
		if (order.status === "PENDING") return "Оплата пока не подтверждена. Попробуйте через минуту"
		await draw({ chatId, messageId, view: await plansView(user) })
		return "Платёж не прошёл — можно попробовать снова"
	}

	if (data === "profile") {
		if (!params.from) return undefined
		await syncTelegramProfile({ user, from: params.from, force: true })
		const fresh = (await findUserByTelegramId(params.from.id)) ?? user
		await draw({ chatId, messageId, view: await accountView(fresh) })
		return "Профиль обновлён"
	}

	return false
}

// ---------------------------------------------------------- profile sync ---

/**
 * #100: keeps the name, @username and avatar of a linked account current.
 *
 * The name and the @handle arrive inside every update for free, so they are
 * stored whenever they changed - no request, no cost. The avatar is the only
 * part that needs a call to Telegram, and that call is made at most once a
 * day per account, and only while the person is already talking to the bot.
 * Nothing is polled in the background: an account that has not written for
 * three weeks costs nothing, and `force` (a bare /start) refreshes on demand -
 * which is exactly what somebody who just changed their picture will do.
 */
export async function syncTelegramProfile(params: {
	user: Pick<
		User,
		"id" | "telegramUsername" | "telegramFirstName" | "telegramLastName" | "telegramProfileSyncedAt"
	>
	from: TelegramUser
	force?: boolean
}): Promise<boolean> {
	const now = new Date()
	const username = params.from.username?.trim() || null
	const firstName = params.from.first_name?.trim() || null
	const lastName = params.from.last_name?.trim() || null
	const textChanged =
		username !== params.user.telegramUsername ||
		firstName !== params.user.telegramFirstName ||
		lastName !== params.user.telegramLastName
	const syncedAt = params.user.telegramProfileSyncedAt
	const fresh = syncedAt !== null && now.getTime() - syncedAt.getTime() < PROFILE_TTL_MS

	if (fresh && !params.force) {
		if (!textChanged) return false
		await prisma.user
			.update({
				where: { id: params.user.id },
				data: {
					telegramUsername: username,
					telegramFirstName: firstName,
					telegramLastName: lastName,
				},
			})
			.catch(() => undefined)
		return true
	}

	// Only a file id is stored, never the image: Telegram serves the picture
	// from that id, so there is nothing to keep in sync or to delete later.
	const photoId = await profilePhotoId(params.from.id)
	await prisma.user
		.update({
			where: { id: params.user.id },
			data: {
				telegramUsername: username,
				telegramFirstName: firstName,
				telegramLastName: lastName,
				telegramPhotoId: photoId,
				telegramProfileSyncedAt: now,
			},
		})
		.catch(() => undefined)
	// The admin panel reads the identity link, so keep the display name there too.
	const displayName = [firstName, lastName].filter(Boolean).join(" ") || username
	await prisma.identityLink
		.updateMany({
			where: { provider: "TELEGRAM", providerUserId: String(params.from.id) },
			data: { providerName: displayName, providerUserId: String(params.from.id) },
		})
		.catch(() => undefined)
	return true
}

// --------------------------------------------------------- outbound notices --

/**
 * #097: the confirmation the buyer sees the moment the gateway settles.
 *
 * Sent from `markOrderPaid`, so it says the same thing the account page will:
 * the plan is already on, nothing else is needed.
 */
export async function notifySubscriptionActivated(params: {
	telegramId: string
	planName: string
	days: number
	amountMinor?: number | null
	currency?: string | null
	expiresAt?: Date | null
}): Promise<boolean> {
	const lines = [
		"✅ <b>Оплата получена</b>",
		`Тариф: <b>${escapeHtml(params.planName)}</b> · ${params.days} дн.`,
	]
	if (typeof params.amountMinor === "number" && params.currency) {
		lines.push(`Сумма: ${escapeHtml(priceLabel(params.amountMinor, params.currency))}`)
	}
	if (params.expiresAt) lines.push(`Действует до: ${localDate(params.expiresAt)}`)
	lines.push("", "Подписка уже активна на всех устройствах — ничего делать не нужно.")
	return sendTelegramMessage(params.telegramId, lines.join("\n"), {
		inline_keyboard: [[{ text: "👤 Аккаунт", callback_data: "account" }]],
	})
}
