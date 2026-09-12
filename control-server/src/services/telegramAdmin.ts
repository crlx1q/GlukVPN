/**
 * The administration side of the bot: registrations, purchases, warnings and
 * one digest a day (#090-#093, #095).
 *
 * Two rules shape this module.
 *
 * 1. **Notify what is actionable, count what is noise.** A finished sign-up or
 *    a payment is worth a message. An abandoned or refused attempt is a
 *    counter that surfaces in the daily digest instead - one message per
 *    refused attempt is exactly how an alert channel becomes a channel nobody
 *    reads, and by then the real notifications are lost too.
 * 2. **Only fields the server already holds, and only as much of them as is
 *    needed to act.** Platform, sign-up route, region of the login address,
 *    time and @handle are shown in full; the email is masked and the phone is
 *    reduced to its last digits. These messages land in a group chat, and
 *    "a***@gmail.com" is just as useful as the whole address for deciding
 *    whether something looks wrong.
 *
 * Destinations come from `adminChatIds()`: the allowed group plus any personal
 * chats, with the legacy TELEGRAM_ALERT_CHAT_ID always included so a
 * deployment that only ever set that one keeps working untouched.
 */
import { config } from "../config"
import { prisma } from "../prisma"
import { priceLabel } from "./billing"
import {
	escapeHtml,
	formatBytes,
	localDay,
	localHour,
	localTime,
	sendTelegramMessage,
	tzLabel,
} from "./telegramApi"

const DAY_MS = 24 * 60 * 60 * 1000
const STATE_ID = "global"

// ----------------------------------------------------------- destinations --

function splitIds(raw: string): string[] {
	return raw
		.split(/[,;\s]+/)
		.map((id) => id.trim())
		.filter(Boolean)
}

/** The one group the bot is allowed to work in, or "" when none is set. */
export function adminGroupId(): string {
	return config.TELEGRAM_ADMIN_GROUP_ID.trim()
}

/**
 * Every chat that receives administration messages, in order of preference and
 * without duplicates - the same id in two variables must not double every
 * notification.
 */
export function adminChatIds(): string[] {
	const ids = [
		adminGroupId(),
		...splitIds(config.TELEGRAM_ADMIN_CHAT_IDS),
		config.TELEGRAM_ALERT_CHAT_ID.trim(),
	]
	return [...new Set(ids.filter(Boolean))]
}

export function isAdminGroup(chatId: string | number): boolean {
	const group = adminGroupId()
	return group !== "" && String(chatId) === group
}

/** Whether this chat is allowed to see administration output and commands. */
export function isAdminChat(chatId: string | number): boolean {
	return adminChatIds().includes(String(chatId))
}

/** Sends to every administration chat; returns how many accepted it. */
export async function notifyAdmins(text: string): Promise<number> {
	const chats = adminChatIds()
	if (chats.length === 0) return 0
	let delivered = 0
	for (const chat of chats) {
		if (await sendTelegramMessage(chat, text)) delivered += 1
	}
	return delivered
}

/** #095: system warnings (a node fell over, a sweep failed) in the same place. */
export async function notifyAdminWarning(text: string): Promise<number> {
	return notifyAdmins(`⚠️ <b>Предупреждение</b>\n${text}`)
}

// -------------------------------------------------------------- redaction --

/** "a***@gmail.com" - enough to recognise an account, not enough to reuse. */
export function maskEmail(email: string | null | undefined): string {
	const raw = (email ?? "").trim()
	if (!raw) return "—"
	const at = raw.lastIndexOf("@")
	if (at <= 0) return "***"
	return `${raw.slice(0, 1)}***${raw.slice(at)}`
}

/** "···4567" - the tail is what a human matches against; the rest is not needed. */
export function maskPhone(phone: string | null | undefined): string {
	const digits = (phone ?? "").replace(/\D+/g, "")
	if (digits.length < 4) return "—"
	return `···${digits.slice(-4)}`
}

const PLATFORM_LABELS: Record<string, string> = {
	android: "Android",
	ios: "iOS",
	windows: "Windows",
	macos: "macOS",
	linux: "Linux",
	extension: "расширение",
	web: "сайт",
	telegram: "Telegram",
}

const SOURCE_LABELS: Record<string, string> = {
	site: "сайт",
	app: "приложение",
	google: "Google",
	telegram: "Telegram",
	admin: "админ-панель",
	extension: "расширение",
}

const METHOD_LABELS: Record<string, string> = {
	email: "почта + Telegram",
	google: "Google + Telegram",
	telegram: "Telegram",
}

function label(map: Record<string, string>, value: string | null | undefined): string {
	const key = (value ?? "").trim().toLowerCase()
	if (!key) return "—"
	return map[key] ?? escapeHtml(key)
}

// ---------------------------------------------------------------- counters --

/** The single bookkeeping row, created on first use. */
async function loadState(): Promise<{
	lastDigestDay: string | null
	abandonedRegistrations: number
	failedRegistrations: number
}> {
	try {
		const state = await prisma.telegramAdminState.upsert({
			where: { id: STATE_ID },
			update: {},
			create: { id: STATE_ID },
		})
		return {
			lastDigestDay: state.lastDigestDay,
			abandonedRegistrations: state.abandonedRegistrations,
			failedRegistrations: state.failedRegistrations,
		}
	} catch {
		// A digest is never worth failing a request or a monitor tick over.
		return { lastDigestDay: null, abandonedRegistrations: 0, failedRegistrations: 0 }
	}
}

/**
 * #090: sign-ups that expired without being finished.
 *
 * Counted rather than announced one by one - an abandoned sign-up is a funnel
 * number, not an event anybody can act on the minute it happens.
 */
export async function noteAbandonedRegistrations(count: number): Promise<void> {
	if (count <= 0) return
	await prisma.telegramAdminState
		.upsert({
			where: { id: STATE_ID },
			update: { abandonedRegistrations: { increment: count } },
			create: { id: STATE_ID, abandonedRegistrations: count },
		})
		.catch(() => undefined)
}

/**
 * #090: an attempt the server refused (phone or Telegram already in use,
 * sign-up closed). Also counted only: these are mostly people retrying.
 */
export async function noteFailedRegistration(): Promise<void> {
	await prisma.telegramAdminState
		.upsert({
			where: { id: STATE_ID },
			update: { failedRegistrations: { increment: 1 } },
			create: { id: STATE_ID, failedRegistrations: 1 },
		})
		.catch(() => undefined)
}

// ----------------------------------------------------------- registrations --

export type RegistrationEvent = {
	username: string
	publicId?: string | null
	email?: string | null
	/** How the account was created: "email", "google", "telegram". */
	method?: string | null
	/** Client the sign-up started from: "android", "windows", "web", ... */
	platform?: string | null
	/** Entry point: "site", "app", "google", ... */
	source?: string | null
	/** Country / region resolved from the address, never anything finer. */
	region?: string | null
	telegramUsername?: string | null
	telegramPhone?: string | null
	at?: Date
}

/** #090 + #091 as one message. */
export function registrationText(event: RegistrationEvent, totalUsers?: number | null): string {
	const at = event.at ?? new Date()
	const handle = event.telegramUsername?.trim()
	const lines = [
		"🆕 <b>Новая регистрация</b>",
		`Аккаунт: <b>${escapeHtml(event.username)}</b>${
			event.publicId ? ` · #${escapeHtml(event.publicId)}` : ""
		}`,
		`Почта: ${escapeHtml(maskEmail(event.email))}`,
		`Способ: ${label(METHOD_LABELS, event.method)}`,
		`Платформа: ${label(PLATFORM_LABELS, event.platform)}`,
		`Источник: ${label(SOURCE_LABELS, event.source)}`,
		`Регион: ${event.region ? escapeHtml(event.region) : "—"}`,
		`Telegram: ${handle ? `@${escapeHtml(handle)}` : "—"} · телефон ${escapeHtml(maskPhone(event.telegramPhone))}`,
		`Время: ${localTime(at)} (${tzLabel()})`,
	]
	if (typeof totalUsers === "number") lines.push(`Всего аккаунтов: ${totalUsers}`)
	if (config.CHANNEL !== "prod") lines.push(`Канал: ${config.CHANNEL.toUpperCase()}`)
	return lines.join("\n")
}

export async function notifyRegistration(event: RegistrationEvent): Promise<void> {
	if (adminChatIds().length === 0) return
	const totalUsers = await prisma.user.count().catch(() => null)
	await notifyAdmins(registrationText(event, totalUsers))
}

// --------------------------------------------------------------- purchases --

export type PurchaseEvent = {
	username: string
	publicId?: string | null
	planName: string
	planCode: string
	days: number
	amountMinor: number
	currency: string
	/** Gateway adapter that took the money: "tabpay", "stripe", "manual". */
	provider?: string | null
	/** Where the order was created: "telegram", "site", "trial", ... */
	source?: string | null
	promoCode?: string | null
	discountMinor?: number | null
	expiresAt?: Date | null
	/** "webhook" or "admin" - who confirmed the payment. */
	confirmedBy?: string | null
	at?: Date
}

/** #092. */
export function purchaseText(event: PurchaseEvent): string {
	const at = event.at ?? new Date()
	const lines = [
		"💳 <b>Покупка подписки</b>",
		`Аккаунт: <b>${escapeHtml(event.username)}</b>${
			event.publicId ? ` · #${escapeHtml(event.publicId)}` : ""
		}`,
		`Тариф: <b>${escapeHtml(event.planName)}</b> · ${event.days} дн.`,
		`Сумма: ${escapeHtml(priceLabel(event.amountMinor, event.currency))}${
			event.promoCode
				? ` (промокод ${escapeHtml(event.promoCode)}, −${escapeHtml(
						priceLabel(event.discountMinor ?? 0, event.currency),
					)})`
				: ""
		}`,
		`Источник: ${label(SOURCE_LABELS, event.source ?? "site")}${
			event.provider ? ` · ${escapeHtml(event.provider)}` : ""
		}${event.confirmedBy ? ` (${escapeHtml(event.confirmedBy)})` : ""}`,
	]
	if (event.expiresAt) lines.push(`Действует до: ${localTime(event.expiresAt)} (${tzLabel()})`)
	lines.push(`Время: ${localTime(at)} (${tzLabel()})`)
	if (config.CHANNEL !== "prod") lines.push(`Канал: ${config.CHANNEL.toUpperCase()}`)
	return lines.join("\n")
}

export async function notifyPurchase(event: PurchaseEvent): Promise<void> {
	if (adminChatIds().length === 0) return
	await notifyAdmins(purchaseText(event))
}

// ------------------------------------------------------------ daily digest --

export type DigestData = {
	day: string
	totalUsers: number
	newUsers: number
	activeUsers: number
	orders: number
	revenue: Array<{ currency: string; minor: number }>
	plans: Array<{ name: string; count: number }>
	uploadBytes: number
	downloadBytes: number
	sessions: number
	liveSessions: number
	nodes: Array<{ label: string; sessions: number }>
	waitingEmail: number
	waitingTelegram: number
	abandoned: number
	failed: number
}

/**
 * #093: the last 24 hours in numbers.
 *
 * A rolling window rather than "yesterday 00:00-24:00": the digest is sent at
 * a configured hour, and a fixed calendar day would leave the hours between
 * midnight and that hour unreported until the next day.
 */
export async function collectDigest(
	now: Date = new Date(),
	counters: { abandoned: number; failed: number } = { abandoned: 0, failed: 0 },
): Promise<DigestData> {
	const since = new Date(now.getTime() - DAY_MS)
	const [
		totalUsers,
		newUsers,
		traffic,
		sessions,
		liveSessions,
		paid,
		trafficUsers,
		sessionUsers,
		nodeGroups,
		waitingEmail,
		waitingTelegram,
	] = await Promise.all([
		prisma.user.count(),
		prisma.user.count({ where: { createdAt: { gte: since } } }),
		prisma.trafficUsageBucket.aggregate({
			where: { bucketStart: { gte: since } },
			_sum: { uploadBytes: true, downloadBytes: true },
		}),
		prisma.session.count({ where: { connectedAt: { gte: since } } }),
		prisma.session.count({ where: { status: { in: ["PENDING", "ACTIVE"] } } }),
		prisma.order.findMany({
			where: { status: "PAID", paidAt: { gte: since } },
			include: { plan: true },
		}),
		prisma.trafficUsageBucket.findMany({
			where: { bucketStart: { gte: since } },
			distinct: ["userId"],
			select: { userId: true },
		}),
		prisma.session.findMany({
			where: { connectedAt: { gte: since } },
			distinct: ["userId"],
			select: { userId: true },
		}),
		prisma.session.groupBy({
			by: ["nodeId"],
			where: { connectedAt: { gte: since } },
			_count: { _all: true },
		}),
		prisma.pendingRegistration.count({ where: { emailVerifiedAt: null } }),
		prisma.pendingRegistration.count({ where: { telegramVerifiedAt: null } }),
	])

	// "Active" is either: moved bytes, or held a session. Traffic alone would
	// miss somebody who connected and idled; sessions alone would miss traffic
	// reported against a session that started before the window.
	const active = new Set<string>()
	for (const row of trafficUsers) active.add(row.userId)
	for (const row of sessionUsers) active.add(row.userId)

	const revenue = new Map<string, number>()
	const plans = new Map<string, number>()
	for (const order of paid) {
		revenue.set(order.currency, (revenue.get(order.currency) ?? 0) + order.amountMinor)
		plans.set(order.plan.name, (plans.get(order.plan.name) ?? 0) + 1)
	}

	const top = [...nodeGroups]
		.sort((a, b) => b._count._all - a._count._all)
		.slice(0, 3)
	const nodeRows =
		top.length > 0
			? await prisma.vpnNode.findMany({
					where: { id: { in: top.map((row) => row.nodeId) } },
					select: { id: true, name: true, country: true, city: true },
				})
			: []

	return {
		day: localDay(now),
		totalUsers,
		newUsers,
		activeUsers: active.size,
		orders: paid.length,
		revenue: [...revenue.entries()].map(([currency, minor]) => ({ currency, minor })),
		plans: [...plans.entries()]
			.map(([name, count]) => ({ name, count }))
			.sort((a, b) => b.count - a.count),
		uploadBytes: Number(traffic._sum.uploadBytes ?? BigInt(0)),
		downloadBytes: Number(traffic._sum.downloadBytes ?? BigInt(0)),
		sessions,
		liveSessions,
		nodes: top.map((row) => {
			const node = nodeRows.find((item) => item.id === row.nodeId)
			const name = node ? node.city || node.country || node.name : "—"
			return { label: name, sessions: row._count._all }
		}),
		waitingEmail,
		waitingTelegram,
		abandoned: counters.abandoned,
		failed: counters.failed,
	}
}

export function digestText(data: DigestData): string {
	const money =
		data.revenue.length > 0
			? data.revenue.map((row) => priceLabel(row.minor, row.currency)).join(" + ")
			: "0"
	const planList =
		data.plans.length > 0
			? data.plans.map((row) => `${escapeHtml(row.name)} ×${row.count}`).join(", ")
			: "—"
	const nodeList =
		data.nodes.length > 0
			? data.nodes.map((row) => `${escapeHtml(row.label)} (${row.sessions})`).join(", ")
			: "—"
	const total = data.uploadBytes + data.downloadBytes
	return [
		`📊 <b>Сводка за сутки</b> · ${data.day} (${tzLabel()})`,
		`👥 Пользователи: ${data.totalUsers} всего, +${data.newUsers} новых, ${data.activeUsers} активных`,
		`💳 Покупки: ${data.orders} на ${escapeHtml(money)} · ${planList}`,
		`📈 Трафик: ${formatBytes(total)} (↑ ${formatBytes(data.uploadBytes)} / ↓ ${formatBytes(data.downloadBytes)})`,
		`🔌 VPN: ${data.sessions} сессий за сутки, ${data.liveSessions} сейчас онлайн`,
		`🌍 Ноды: ${nodeList}`,
		`📝 Регистрации: ждут почту ${data.waitingEmail}, ждут Telegram ${data.waitingTelegram}, брошено ${data.abandoned}, отказов ${data.failed}`,
	].join("\n")
}

/** Send the digest right now, whatever the schedule says (the /digest command). */
export async function sendDigest(now: Date = new Date()): Promise<boolean> {
	const state = await loadState()
	const data = await collectDigest(now, {
		abandoned: state.abandonedRegistrations,
		failed: state.failedRegistrations,
	})
	return (await notifyAdmins(digestText(data))) > 0
}

/** Whether the scheduled digest for the current local day is still owed. */
export function digestDue(state: { lastDigestDay: string | null }, now: Date): boolean {
	if (localHour(now) < config.TELEGRAM_DIGEST_HOUR) return false
	return state.lastDigestDay !== localDay(now)
}

/**
 * #093: called from the monitor tick. Sends at most one digest per local day.
 *
 * The day is claimed with a conditional UPDATE *before* the numbers are
 * collected, so two processes polling the same minute - prod and beta share
 * nothing, but a rolling deploy overlaps - cannot both send. The counters are
 * zeroed by that same statement: they describe the period just reported.
 */
export async function runDailyDigestTick(now: Date = new Date()): Promise<boolean> {
	if (adminChatIds().length === 0) return false
	const state = await loadState()
	if (!digestDue(state, now)) return false

	const day = localDay(now)
	const claim = await prisma.telegramAdminState
		.updateMany({
			where: {
				id: STATE_ID,
				OR: [{ lastDigestDay: null }, { lastDigestDay: { not: day } }],
			},
			data: {
				lastDigestDay: day,
				lastDigestAt: now,
				abandonedRegistrations: 0,
				failedRegistrations: 0,
			},
		})
		.catch(() => ({ count: 0 }))
	if (claim.count === 0) return false

	const data = await collectDigest(now, {
		abandoned: state.abandonedRegistrations,
		failed: state.failedRegistrations,
	})
	await notifyAdmins(digestText(data))
	return true
}

// ------------------------------------------------------- admin chat commands --

/** Short service status for the administration group (#095). */
async function statusText(now: Date = new Date()): Promise<string> {
	const freshAfter = new Date(now.getTime() - config.NODE_OFFLINE_AFTER_SEC * 1000)
	const [users, liveSessions, nodesTotal, nodesFresh, pendingOrders, settings] = await Promise.all([
		prisma.user.count(),
		prisma.session.count({ where: { status: { in: ["PENDING", "ACTIVE"] } } }),
		prisma.vpnNode.count(),
		prisma.vpnNode.count({ where: { lastHeartbeat: { gte: freshAfter } } }),
		prisma.order.count({ where: { status: "PENDING" } }),
		prisma.serviceSettings.findUnique({ where: { id: STATE_ID } }),
	])
	return [
		`🛠 <b>Состояние</b> · ${config.CHANNEL.toUpperCase()} · ${localTime(now)} (${tzLabel()})`,
		`Пользователи: ${users}`,
		`Сессии онлайн: ${liveSessions}`,
		`Ноды: ${nodesFresh} из ${nodesTotal} на связи`,
		`Ожидают оплаты: ${pendingOrders}`,
		`Регистрация: ${settings?.registrationEnabled === false ? "закрыта" : "открыта"}${
			settings?.maintenance ? " · режим обслуживания" : ""
		}`,
	].join("\n")
}

const ADMIN_HELP = [
	"🛠 <b>Команды администратора</b>",
	"/status — пользователи, сессии, ноды, ожидающие оплаты",
	"/digest — сводка за последние сутки сразу",
	"Регистрации, покупки и предупреждения приходят сюда сами.",
].join("\n")

/**
 * Handles an administration command. Returns false when the text is not one,
 * so the caller can fall through to the normal user handling.
 *
 * The caller is responsible for checking `isAdminChat`: this module decides
 * what the commands do, not who is allowed to type them.
 */
export async function handleAdminCommand(text: string, chatId: string | number): Promise<boolean> {
	const command = text.trim().split(/\s+/)[0]?.toLowerCase().replace(/@.*$/, "") ?? ""
	if (command === "/status") {
		await sendTelegramMessage(chatId, await statusText())
		return true
	}
	if (command === "/digest") {
		const sent = await sendDigest()
		if (!sent) await sendTelegramMessage(chatId, "Не удалось отправить сводку.")
		return true
	}
	if (command === "/admin" || command === "/help") {
		await sendTelegramMessage(chatId, ADMIN_HELP)
		return true
	}
	return false
}
