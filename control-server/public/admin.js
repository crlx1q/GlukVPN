/* GlukVPN admin panel: plain JS, no build step, no external requests.
   Tokens live in memory only, so closing the tab ends the admin session.

   The Channels tab drives the two-channel deployment flow. It never sends a
   command, a path or a script name: it POSTs to three fixed routes, and the
   server turns each into one hard-coded script run by the deploy worker. */
"use strict"

const state = {
	accessToken: null,
	refreshToken: null,
	username: null,
	publicId: null,
	tab: "overview",
	timer: null,
	jobTimer: null,
	busy: false,
	userQuery: "",
	searchTimer: null,
	canDeploy: false,
	channel: "current",
	serviceSettings: null,
	serviceBusy: false,
	// Акция и промокоды в том виде, в каком их сейчас показывает вкладка Billing.
	trial: null,
	trialBusy: false,
	promos: [],
	// Client Bug Logs filter: "" = every platform.
	errorPlatform: "",
	// Чей блок подписки раскрыт прямо сейчас. Пока он открыт, таблица
	// пользователей не перерисовывается: иначе опрос раз в 10 секунд
	// стирал форму выдачи прямо во время заполнения.
	subPanelUserId: null,
}

const el = (id) => document.getElementById(id)

function toast(message, isError) {
	const node = el("toast")
	node.textContent = message
	node.className = isError ? "error-toast" : "ok-toast"
	node.hidden = false
	setTimeout(() => {
		node.hidden = true
	}, 4500)
}

async function request(path, options = {}, isRetry = false) {
	const headers = { Accept: "application/json" }
	if (options.body) headers["Content-Type"] = "application/json"
	if (state.accessToken) headers.Authorization = `Bearer ${state.accessToken}`

	const response = await fetch(path, {
		method: options.method || "GET",
		headers,
		body: options.body ? JSON.stringify(options.body) : undefined,
	})

	// Access tokens are short-lived: rotate once, then give up.
	if (response.status === 401 && state.refreshToken && !isRetry) {
		const refreshed = await refreshTokens()
		if (refreshed) return request(path, options, true)
	}

	let payload = {}
	try {
		payload = await response.json()
	} catch {
		payload = {}
	}
	if (!response.ok) {
		let message = `HTTP ${response.status}`
		if (payload && payload.error) {
			if (typeof payload.error === "string") {
				message = payload.message || payload.error
			} else if (payload.error.message) {
				message = payload.error.message
			}
		} else if (payload && payload.message) {
			message = payload.message
		}

		// Field-level validation errors are worth showing verbatim.
		if (payload && payload.error && payload.error.details) {
			const details = payload.error.details
			const extra = Object.keys(details)
				.map((key) => `${key}: ${[].concat(details[key]).join(", ")}`)
				.join("; ")
			if (extra) message += ` (${extra})`
		}

		const error = new Error(message)
		error.status = response.status
		error.code = payload && payload.error && payload.error.code
		throw error
	}
	return payload
}

async function refreshTokens() {
	try {
		const response = await fetch("/api/auth/refresh", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ refreshToken: state.refreshToken }),
		})
		if (!response.ok) throw new Error("refresh failed")
		const data = await response.json()
		state.accessToken = data.accessToken
		state.refreshToken = data.refreshToken
		return true
	} catch {
		signOut("Session expired, please sign in again.")
		return false
	}
}

/* ---------------- formatting helpers ---------------- */

function bytes(value) {
	const n = Number(value || 0)
	if (n < 1024) return `${n} B`
	if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
	if (n < 1024 * 1024 * 1024) return `${(n / 1048576).toFixed(1)} MB`
	return `${(n / 1073741824).toFixed(2)} GB`
}

function percent(value) {
	return value === null || value === undefined ? "\u2014" : `${Math.round(Number(value))}%`
}

function uptime(seconds) {
	if (!seconds) return "\u2014"
	const d = Math.floor(seconds / 86400)
	const h = Math.floor((seconds % 86400) / 3600)
	const m = Math.floor((seconds % 3600) / 60)
	if (d > 0) return `${d}d ${h}h`
	if (h > 0) return `${h}h ${m}m`
	return `${m}m`
}

function ago(iso) {
	if (!iso) return "never"
	const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000)
	if (diff < 0) return "just now"
	if (diff < 60) return `${diff}s ago`
	if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
	if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
	return `${Math.floor(diff / 86400)}d ago`
}

function clock(iso) {
	return iso ? new Date(iso).toLocaleTimeString() : "\u2014"
}

function statusPill(text) {
	const span = document.createElement("span")
	span.className = `pill ${String(text || "").toLowerCase()}`
	span.textContent = text
	return span
}

function idChip(publicId) {
	const span = document.createElement("span")
	span.className = "idchip"
	span.textContent = publicId || "\u2014"
	span.title = "Immutable account ID \u2014 search and ban by this"
	return span
}

/** Owner cell: nickname on top, the permanent ID underneath. */
function ownerCell(user) {
	const wrap = document.createElement("div")
	if (!user) {
		wrap.textContent = "\u2014"
		return wrap
	}
	const name = document.createElement("span")
	name.textContent = user.username || "\u2014"
	const sub = document.createElement("span")
	sub.className = "sub-line"
	sub.textContent = user.publicId ? `ID ${user.publicId}` : ""
	wrap.append(name, sub)
	return wrap
}

function loadBar(loadPercent) {
	const wrap = document.createElement("div")
	wrap.className = "loadbar"
	const fill = document.createElement("i")
	// CSSOM assignment, not a style attribute: the CSP has no 'unsafe-inline'.
	fill.style.width = `${Math.max(0, Math.min(100, Number(loadPercent || 0)))}%`
	wrap.appendChild(fill)
	const label = document.createElement("span")
	label.className = "sub-line"
	label.textContent = `${Math.round(Number(loadPercent || 0))}%`
	const holder = document.createElement("div")
	holder.append(wrap, label)
	return holder
}

function cell(row, content) {
	const td = document.createElement("td")
	if (content instanceof Node) td.appendChild(content)
	else td.textContent = content === null || content === undefined ? "\u2014" : String(content)
	row.appendChild(td)
	return td
}

function kv(label, value, mono) {
	const row = document.createElement("div")
	row.className = "kv"
	const left = document.createElement("span")
	left.textContent = label
	const right = document.createElement("span")
	if (mono) right.className = "mono"
	right.textContent = value === null || value === undefined || value === "" ? "\u2014" : String(value)
	row.append(left, right)
	return row
}

function actionButton(label, className, handler) {
	const button = document.createElement("button")
	button.type = "button"
	button.className = className
	button.textContent = label
	button.addEventListener("click", async () => {
		button.disabled = true
		try {
			await handler()
			await loadAll()
		} catch (error) {
			toast(error.message, true)
		} finally {
			button.disabled = false
		}
	})
	return button
}

/* ---------------- channel badge (pre-login) ---------------- */

async function loadChannelBadge() {
	try {
		const response = await fetch("/api/version", { headers: { Accept: "application/json" } })
		if (!response.ok) throw new Error("version unavailable")
		const data = await response.json()
		const isBeta = data.channel === "beta"
		state.channel = String(data.channel || "current").toLowerCase()
		const badge = el("channel-badge")
		badge.textContent = `${String(data.channel || "?").toUpperCase()} ${data.version || ""}`.trim()
		badge.title = data.release ? `release ${data.release}` : ""
		badge.classList.toggle("is-beta", isBeta)
		el("login-channel").textContent = isBeta
			? "You are on the BETA control plane. Test accounts and test nodes only."
			: "Production control plane."
	} catch {
		el("channel-badge").textContent = "offline"
	}
}

/* ---------------- rendering ---------------- */

function channelScopeLabel() {
	if (state.channel === "beta") return "BETA only"
	if (state.channel === "prod" || state.channel === "production") return "PRODUCTION only"
	return "this control plane only"
}

function setServiceBusy(isBusy) {
	state.serviceBusy = isBusy
	el("service-controls").setAttribute("aria-busy", String(isBusy))
	el("registration-enabled").disabled = isBusy || !state.serviceSettings
	el("emergency-maintenance").disabled = isBusy || !state.serviceSettings
}

function renderServiceSettings(settings) {
	state.serviceSettings = settings
	el("registration-enabled").checked = Boolean(settings.registrationEnabled)
	el("emergency-maintenance").checked = Boolean(settings.maintenance)
	el("service-scope").textContent = `${channelScopeLabel()}. These switches do not change the other channel.`
	el("service-updated").textContent = settings.updatedAt ? `updated ${ago(settings.updatedAt)} · v${settings.version}` : `version ${settings.version}`
	el("service-error").hidden = true
	setServiceBusy(false)
}

async function loadServiceSettings() {
	try {
		renderServiceSettings(await request("/api/admin/service-settings"))
		return true
	} catch (error) {
		state.serviceSettings = null
		setServiceBusy(true)
		const box = el("service-error")
		box.textContent = error.status === 404
			? "Service controls are not available on this control server yet."
			: `Could not load service controls: ${error.message}`
		box.hidden = false
		return false
	}
}

async function mutateServiceSettings(changes) {
	if (!state.serviceSettings || state.serviceBusy) return
	const previousVersion = state.serviceSettings.version
	setServiceBusy(true)
	try {
		const result = await request("/api/admin/service-settings", {
			method: "POST",
			body: { ...changes, expectedVersion: previousVersion },
		})
		renderServiceSettings(result)
		const queued = Number(result.policySyncQueued || 0)
		const closed = Number(result.closedSessions || 0)
		const action = Object.hasOwn(changes, "maintenance")
			? `Maintenance ${changes.maintenance ? "enabled" : "disabled"}`
			: `Registration ${changes.registrationEnabled ? "enabled" : "disabled"}`
		const effects = []
		if (changes.maintenance) effects.push(`${closed} active session${closed === 1 ? "" : "s"} closed`)
		if (queued > 0) effects.push(`policy update queued for ${queued} node${queued === 1 ? "" : "s"}; nodes apply it on next poll`)
		toast(`${action} on ${channelScopeLabel()}${effects.length ? `. ${effects.join("; ")}.` : "."}`)
	} catch (error) {
		const conflict = error.status === 409 && error.code === "settings_conflict"
		const reloaded = await loadServiceSettings()
		const box = el("service-error")
		box.textContent = conflict
			? "Settings changed in another admin session. Current values were reloaded."
			: reloaded
				? "The change was not confirmed. Current server values were reloaded."
				: "The change result is unknown and the current server values could not be reloaded. Refresh before trying again."
		box.hidden = false
		toast(box.textContent, true)
	} finally {
		setServiceBusy(!state.serviceSettings)
	}
}

function policyStatus(node) {
	const policy = node.policy || {}
	const desired = policy.desiredVersion ?? node.desiredVersion
	const applied = policy.appliedVersion ?? node.appliedVersion
	const inSync = policy.inSync ?? (desired !== undefined && desired === applied)
	const wrap = document.createElement("div")
	wrap.className = `policy-state ${inSync ? "is-synced" : "is-queued"}`
	const versions = document.createElement("strong")
	versions.textContent = desired === null || desired === undefined ? "No policy" : `desired v${desired} · applied ${applied === null || applied === undefined ? "—" : `v${applied}`}`
	const note = document.createElement("span")
	note.textContent = inSync ? "Applied" : "Queued — nodes apply on next poll"
	wrap.append(versions, note)
	return wrap
}

/**
 * The same disclosure the clients show: collapsed by default, one line per
 * restriction, each with the rules behind it and a comment saying why.
 *
 * Fifteen columns of node metadata leave no room for a wall of chips, and the
 * chips used to repeat themselves whenever two router rules enforced one
 * restriction (the two BitTorrent port rules produced "Known P2P ports
 * blocked" twice). Grouping now happens on the server, in publicRestrictions.
 */
function restrictionBadges(restrictions) {
	const items = Array.isArray(restrictions) ? restrictions : []
	if (items.length === 0) {
		const none = document.createElement("span")
		none.className = "muted small"
		none.textContent = "None"
		return none
	}
	const drop = document.createElement("details")
	drop.className = "restriction-drop"
	const summary = document.createElement("summary")
	const count = document.createElement("strong")
	count.textContent = `${items.length} blocked`
	const hint = document.createElement("span")
	hint.textContent = items.map((r) => r.label || r.code || r.kind || "rule").join(" · ")
	summary.append(count, hint)
	const list = document.createElement("div")
	list.className = "restriction-list"
	for (const restriction of items) {
		const row = document.createElement("div")
		row.className = `restriction-row is-${restriction.source === "builtin" ? "builtin" : "policy"}`
		const badge = document.createElement("span")
		badge.className = "restriction-badge"
		badge.textContent = restriction.label || restriction.code || restriction.kind || "Restriction"
		const rules = document.createElement("code")
		rules.textContent = Array.isArray(restriction.rules) && restriction.rules.length
			? restriction.rules.join(" · ")
			: [restriction.kind, restriction.value, restriction.network].filter(Boolean).join(" · ")
		const note = document.createElement("p")
		// Admin-authored text: textContent keeps it literal, never HTML.
		note.textContent = restriction.detail || ""
		row.append(badge, rules, note)
		list.appendChild(row)
	}
	drop.append(summary, list)
	return drop
}

function renderCards(overview) {
	const items = [
		["Nodes online", `${overview.nodes.online} / ${overview.nodes.total}`],
		["Live sessions", overview.sessions.live],
		["Users active", `${overview.users.active} / ${overview.users.total}`],
		["Devices active", `${overview.devices.active} / ${overview.devices.total}`],
		["Traffic rx", bytes(overview.traffic.bytesRx)],
		["Traffic tx", bytes(overview.traffic.bytesTx)],
	]
	const container = el("cards")
	container.replaceChildren()
	for (const [label, value] of items) {
		const card = document.createElement("div")
		card.className = "metric"
		const small = document.createElement("span")
		small.textContent = label
		const strong = document.createElement("strong")
		strong.textContent = String(value)
		card.append(small, strong)
		container.appendChild(card)
	}
}

function channelCard(channel, compact) {
	const card = document.createElement("article")
	card.className = `chan-card is-${channel.channel}`
	if (!channel.reachable) card.classList.add("is-down")

	const head = document.createElement("div")
	head.className = "chan-head"
	const dot = document.createElement("span")
	dot.className = `dot ${channel.reachable ? "up" : "down"}`
	const title = document.createElement("span")
	title.className = "chan-title"
	title.textContent = channel.channel === "beta" ? "BETA" : "PRODUCTION"
	const version = document.createElement("span")
	version.className = "chan-version"
	version.textContent = channel.reachable ? channel.version || "?" : "off"
	head.append(dot, title, version)
	card.appendChild(head)

	card.appendChild(kv("API", channel.api, true))
	if (!compact) {
		card.appendChild(kv("Admin", channel.admin, true))
		card.appendChild(kv("Commit", channel.commit ? channel.commit.slice(0, 7) : null, true))
		// The release id is what actually changes after a promote - the version
		// number comes from package.json and normally does not.
		card.appendChild(kv("Release", channel.release, true))
		card.appendChild(kv("Migration", channel.migration, true))
		card.appendChild(kv("Released", channel.releasedAt ? new Date(channel.releasedAt).toLocaleString() : null))
	}
	card.appendChild(kv("Database", channel.database || "unknown"))
	return card
}

function renderChecklist(checks) {
	const list = el("checklist")
	list.replaceChildren()
	for (const check of checks) {
		const item = document.createElement("li")
		item.className = `check ${check.ok ? "ok" : "bad"}`
		const icon = document.createElement("span")
		icon.className = "check-icon"
		icon.textContent = check.ok ? "\u2713" : "!"
		const label = document.createElement("span")
		label.textContent = check.label
		const detail = document.createElement("span")
		detail.className = "check-detail"
		detail.textContent = check.detail || ""
		item.append(icon, label, detail)
		list.appendChild(item)
	}
}

function jobCard(job, expanded) {
	const card = document.createElement("div")
	card.className = "job"

	const head = document.createElement("div")
	head.className = "job-head"
	const action = document.createElement("span")
	action.className = "job-action"
	action.textContent = job.action.replaceAll("_", " ").toLowerCase()
	const meta = document.createElement("span")
	meta.className = "job-meta"
	const who = job.requestedBy ? `${job.requestedBy.username} (ID ${job.requestedBy.publicId})` : "system"
	meta.textContent = `${who} \u00b7 ${new Date(job.createdAt).toLocaleString()}`
	head.append(action, statusPill(job.status), meta)
	card.appendChild(head)

	if (job.releaseId) card.appendChild(kv("Release", job.releaseId, true))
	if (job.previousReleaseId) card.appendChild(kv("Previous release", job.previousReleaseId, true))
	if (job.backupPath) card.appendChild(kv("Prod backup", job.backupPath, true))
	if (job.exitCode !== null && job.exitCode !== undefined) {
		card.appendChild(kv("Exit code", job.exitCode))
	}
	if (job.finishedAt) card.appendChild(kv("Finished", new Date(job.finishedAt).toLocaleString()))

	if (job.log) {
		const details = document.createElement("details")
		details.open = Boolean(expanded)
		const summary = document.createElement("summary")
		summary.textContent = "Show log"
		const pre = document.createElement("pre")
		pre.className = "job-log"
		pre.textContent = job.log
		details.append(summary, pre)
		card.appendChild(details)
	}
	return card
}

function renderDeploy(status) {
	state.canDeploy = Boolean(status.canDeploy)

	const cards = el("channel-cards")
	cards.replaceChildren(
		channelCard(status.channels.prod, false),
		channelCard(status.channels.beta, false),
	)
	const overview = el("overview-channels")
	overview.replaceChildren(
		channelCard(status.channels.prod, true),
		channelCard(status.channels.beta, true),
	)
	el("overview-updated").textContent = `updated ${clock(status.serverTime)}`
	el("deploy-updated").textContent = `updated ${clock(status.serverTime)}`

	renderChecklist(status.checks)

	const active = status.activeJob
	const betaUp = status.channels.beta.reachable
	el("deploy-beta-btn").disabled = !state.canDeploy || Boolean(active)
	el("promote-btn").disabled = !state.canDeploy || Boolean(active) || !betaUp
	el("rollback-btn").disabled = !state.canDeploy || Boolean(active)

	// Beta lifecycle: only offer the action that makes sense in the current state.
	el("beta-start-btn").disabled = !state.canDeploy || Boolean(active) || betaUp
	el("beta-restart-btn").disabled = !state.canDeploy || Boolean(active) || !betaUp
	el("beta-stop-btn").disabled = !state.canDeploy || Boolean(active) || !betaUp

	const betaState = el("beta-state")
	if (betaState) {
		const intended = status.beta ? status.beta.intendedState : null
		if (betaUp) {
			betaState.textContent = "beta is running"
		} else if (intended === "stopped") {
			// Stop Beta disables the units, so this survives a reboot.
			betaState.textContent = "beta is switched off"
		} else {
			betaState.textContent = "beta is not answering"
		}
	}

	const box = el("active-job-box")
	if (active) {
		box.replaceChildren()
		const head = document.createElement("div")
		head.className = "block-head"
		const title = document.createElement("h3")
		title.textContent = "Deployment in progress"
		head.appendChild(title)
		box.append(head, jobCard(active, true))
		box.hidden = false
		startJobPolling()
	} else {
		box.hidden = true
		stopJobPolling()
	}

	const list = el("jobs-list")
	list.replaceChildren()
	if (status.jobs.length === 0) {
		const empty = document.createElement("p")
		empty.className = "muted small"
		empty.textContent = "No deployments yet."
		list.appendChild(empty)
	}
	for (const job of status.jobs) list.appendChild(jobCard(job, false))

	if (!state.canDeploy) {
		const note = document.createElement("p")
		note.className = "muted small"
		note.textContent =
			"Deployments are driven from the production panel. Beta cannot promote itself."
		list.prepend(note)
	}
}

function renderNodes(nodes) {
	const body = el("nodes-body")
	body.replaceChildren()
	for (const node of nodes) {
		const row = document.createElement("tr")
		cell(row, node.name)
		cell(row, `${node.country} (${node.countryCode})`)
		cell(row, statusPill(node.status))
		cell(row, policyStatus(node))
		cell(row, restrictionBadges(node.restrictions))
		cell(row, node.endpoint)
		cell(row, loadBar(node.loadPercent))
		cell(row, percent(node.cpuPercent))
		cell(row, percent(node.ramPercent))
		cell(row, uptime(node.uptimeSeconds))
		cell(row, `${node.activePeers} / ${node.capacity}`)
		cell(row, node.liveSessions)
		cell(row, `${bytes(node.bytesRx)} / ${bytes(node.bytesTx)}`)
		cell(row, ago(node.lastHeartbeat))

		const actions = document.createElement("td")
		actions.className = "actions"
		if (node.storedStatus !== "DISABLED") {
			actions.appendChild(
				actionButton(node.maintenance ? "End maintenance" : "Maintenance", node.maintenance ? "small ghost" : "small warn", async () => {
					if (!node.maintenance && !confirm(`Put ${node.name} into maintenance? Active sessions on this node will close.`)) return null
					const result = await request(`/api/admin/nodes/${node.id}/maintenance`, {
						method: "POST",
						body: { enabled: !node.maintenance },
					})
					const queued = Number(result.policySyncQueued || 0)
					const closed = Number(result.closedSessions || 0)
					toast(node.maintenance
						? `Maintenance ended for ${node.name}. Policy update queued${queued ? ` for ${queued} node${queued === 1 ? "" : "s"}` : ""}; nodes apply it on next poll.`
						: `${node.name} entered maintenance. ${closed} active session${closed === 1 ? "" : "s"} closed. Policy update queued${queued ? ` for ${queued} node${queued === 1 ? "" : "s"}` : ""}; nodes apply it on next poll.`)
					return result
				}),
			)
		}
		if (node.storedStatus === "DISABLED") {
			actions.appendChild(
				actionButton("Enable", "small ghost", () =>
					request(`/api/admin/nodes/${node.id}/enable`, { method: "POST" }),
				),
			)
			actions.appendChild(
				actionButton("Delete", "small danger", () => {
					if (!confirm(`Delete node ${node.name} from the registry?`)) return null
					return request(`/api/admin/nodes/${node.id}`, { method: "DELETE" })
				}),
			)
		} else {
			actions.appendChild(
				actionButton("Disable", "small danger", () => {
					if (!confirm(`Disable ${node.name}? Active tunnels will be closed.`)) return null
					return request(`/api/admin/nodes/${node.id}/disable`, { method: "POST" })
				}),
			)
		}
		row.appendChild(actions)
		body.appendChild(row)
	}
	if (nodes.length === 0) {
		const row = document.createElement("tr")
		const td = cell(row, "No nodes registered yet. Issue an enrollment token and run the agent.")
		td.colSpan = 15
		td.className = "muted"
		body.appendChild(row)
	}
}

/* ---------------- subscription grants (users tab) ---------------- */

/** Выдавать план надо прямо из таблицы, без консоли и SQL. β Pro не
 *  показывается в каталоге, но руками его выдавать нужно. */
const GRANT_PLANS = [
	{ value: "basic", label: "Basic", badge: "basic" },
	{ value: "pro", label: "Pro", badge: "pro" },
	{ value: "beta_pro", label: "\u03b2 Pro", badge: "beta" },
]

/** Месяц / 3 / 6 / год — в днях, как ждёт POST /users/:id/subscription. */
const GRANT_TERMS = [
	{ value: 30, label: "1 мес" },
	{ value: 90, label: "3 мес" },
	{ value: 180, label: "6 мес" },
	{ value: 365, label: "12 мес" },
]

const BADGE_LABELS = { free: "Free", basic: "Basic", pro: "Pro", beta: "\u03b2 Pro" }

/**
 * Значок тарифа: тот же смысл и цвет, что на сайте, ПК, телефоне и в
 * расширении. Free — не подписка, а её отсутствие, поэтому серый значок и
 * никакого срока.
 */
const BADGE_SPOTS = [
	["15.25", "6.37"],
	["15.25", "17.63"],
	["5.5", "12"],
]

/**
 * Глиф бейджика: узел в центре и нити к соседним узлам — Free одинокая точка,
 * Basic одна нить, Pro три уравновешенных узла, β Pro та же сеть за пунктирным
 * контуром. Координаты те же, что в site/assets/js/auth.js, extension/ui/popup.js
 * и flutter-client/lib/widgets/plan_badge.dart.
 */
function planBadgeSvg(kind) {
	const ns = "http://www.w3.org/2000/svg"
	const svg = document.createElementNS(ns, "svg")
	svg.setAttribute("viewBox", "0 0 24 24")
	svg.setAttribute("aria-hidden", "true")
	const add = (tag, attrs) => {
		const node = document.createElementNS(ns, tag)
		for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value)
		svg.appendChild(node)
	}
	const count = kind === "free" ? 0 : kind === "basic" ? 1 : 3
	const halo = kind === "basic" ? "2.05" : "1.9"
	const dot = kind === "basic" ? "1" : "0.95"
	const spots = BADGE_SPOTS.slice(0, count)
	if (kind === "beta") {
		add("circle", { cx: "12", cy: "12", r: "9.3", fill: "none", stroke: "currentColor", "stroke-width": "1", "stroke-dasharray": "1.4 2", opacity: "0.5" })
	}
	for (const [x, y] of spots) {
		add("line", { x1: "12", y1: "12", x2: x, y2: y, stroke: "currentColor", "stroke-width": "1.3", "stroke-linecap": "round", opacity: "0.85" })
	}
	for (const [x, y] of spots) add("circle", { cx: x, cy: y, r: halo, fill: "currentColor", "fill-opacity": "0.18" })
	for (const [x, y] of spots) add("circle", { cx: x, cy: y, r: dot, fill: "currentColor" })
	add("circle", { cx: "12", cy: "12", r: "2.6", fill: "none", stroke: "currentColor", "stroke-width": "1.3" })
	add("circle", { cx: "12", cy: "12", r: "1.15", fill: "currentColor" })
	return svg
}

function planBadge(badge, label) {
	const kind = BADGE_LABELS[badge] ? badge : "free"
	const span = document.createElement("span")
	span.className = `plan-badge plan-badge--${kind}`
	span.appendChild(planBadgeSvg(kind))
	span.appendChild(document.createTextNode(label || BADGE_LABELS[kind]))
	return span
}

function dateLabel(iso) {
	return iso ? new Date(iso).toLocaleDateString() : "\u2014"
}

function gbLabel(bytes) {
	if (bytes === null || bytes === undefined) return "без лимита"
	return `${Math.round(Number(bytes) / 1024 ** 3)} ГБ / 30 дней`
}

/** Ячейка «Подписка»: что действует сейчас, без «Free активна до 2028». */
function subscriptionCell(user) {
	const ent = user.entitlement || {}
	const wrap = document.createElement("div")
	wrap.className = "sub-cell"
	wrap.appendChild(planBadge(ent.badge, ent.planName))
	const line = document.createElement("span")
	line.className = "sub-line"
	line.textContent = ent.subscribed
		? `до ${dateLabel(ent.expiresAt)} · ${ent.daysLeft} дн.`
		: "подписки нет"
	wrap.appendChild(line)
	return wrap
}

/** Ряд кнопок-переключателей вместо <select>: все варианты видны сразу. */
function chipRow(options, selected, onPick) {
	const row = document.createElement("div")
	row.className = "chip-row"
	const buttons = []
	const pick = (value) => {
		for (const button of buttons) {
			button.setAttribute("aria-pressed", String(button.dataset.value === String(value)))
		}
		onPick(value)
	}
	for (const option of options) {
		const button = document.createElement("button")
		button.type = "button"
		button.className = "chip"
		button.dataset.value = String(option.value)
		button.textContent = option.label
		button.addEventListener("click", () => pick(option.value))
		buttons.push(button)
		row.appendChild(button)
	}
	pick(selected)
	return row
}

function subField(label, control) {
	const wrap = document.createElement("div")
	wrap.className = "sub-field"
	const caption = document.createElement("span")
	caption.textContent = label
	wrap.append(caption, control)
	return wrap
}

/**
 * Панель подписки.
 *
 * Раскрывается отдельной строкой под пользователем — в потоке таблицы, ничего
 * не висит поверх — и сначала отвечает на вопрос «что сейчас». Дальше ровно
 * два действия: выдать / заменить / продлить подписку либо отключить её
 * полностью, после чего аккаунт становится Free, то есть без подписки вообще.
 */
function subscriptionPanel(user, close) {
	const ent = user.entitlement || {}
	const wrap = document.createElement("div")
	wrap.className = "sub-panel"

	const head = document.createElement("div")
	head.className = "sub-panel__head"
	const title = document.createElement("div")
	title.className = "sub-panel__title"
	title.appendChild(planBadge(ent.badge, ent.planName))
	const who = document.createElement("span")
	who.className = "sub-line"
	who.textContent = `${user.username} · ID ${user.publicId}`
	title.appendChild(who)
	const hide = document.createElement("button")
	hide.type = "button"
	hide.className = "small ghost"
	hide.textContent = "Свернуть"
	hide.addEventListener("click", close)
	head.append(title, hide)

	const facts = document.createElement("div")
	facts.className = "sub-panel__facts"
	facts.append(
		kv("Статус", ent.subscribed ? "подписка активна" : "подписки нет (Free)"),
		kv("Действует до", ent.subscribed ? dateLabel(ent.expiresAt) : "\u2014"),
		kv("Осталось", ent.subscribed ? `${ent.daysLeft} дн.` : "\u2014"),
		kv("Трафик", gbLabel(ent.trafficLimitBytes)),
		kv("Устройства / сессии", `${ent.maxDevices ?? "?"} / ${ent.maxSessions ?? "?"}`),
	)

	let plan =
		ent.subscribed && GRANT_PLANS.some((item) => item.value === ent.plan) ? ent.plan : "basic"
	let days = 30
	let mode = ent.subscribed ? "extend" : "replace"

	const form = document.createElement("div")
	form.className = "sub-panel__form"
	form.appendChild(
		subField(
			"Тариф",
			chipRow(GRANT_PLANS, plan, (value) => {
				plan = value
			}),
		),
	)
	form.appendChild(
		subField(
			"Срок",
			chipRow(GRANT_TERMS, days, (value) => {
				days = Number(value)
			}),
		),
	)
	if (ent.subscribed) {
		// Продлить = добавить срок к остатку; заменить = начать новый с сегодня.
		form.appendChild(
			subField(
				"Как применить",
				chipRow(
					[
						{ value: "extend", label: "Продлить" },
						{ value: "replace", label: "Заменить" },
					],
					mode,
					(value) => {
						mode = value
					},
				),
			),
		)
	}

	const actions = document.createElement("div")
	actions.className = "sub-panel__actions"
	actions.appendChild(
		actionButton(ent.subscribed ? "Применить" : "Выдать подписку", "small", () => {
			const planLabel = (GRANT_PLANS.find((item) => item.value === plan) || {}).label || plan
			const termLabel =
				(GRANT_TERMS.find((item) => String(item.value) === String(days)) || {}).label ||
				`${days} дн.`
			const verb = mode === "extend" ? "продлить на" : "выдать"
			if (
				!window.confirm(
					`${user.username} (ID ${user.publicId}): ${verb} ${planLabel} ${termLabel}?`,
				)
			)
				return null
			return request(`/api/admin/users/${user.id}/subscription`, {
				method: "POST",
				body: { planCode: plan, days, mode },
			}).then((result) => {
				toast(`${result.planName || planLabel} \u2192 ${dateLabel(result.expiresAt)}`)
				close()
			})
		}),
	)
	if (ent.subscribed) {
		actions.appendChild(
			actionButton("Отключить подписку", "small danger", () => {
				if (
					!window.confirm(
						`Отключить подписку у ${user.username} (ID ${user.publicId})? Аккаунт станет Free (без подписки), туннели закроются.`,
					)
				)
					return null
				return request(`/api/admin/users/${user.id}/subscription`, { method: "DELETE" }).then(
					() => {
						toast("Подписка отключена \u2014 аккаунт без подписки (Free)")
						close()
					},
				)
			}),
		)
	}

	const note = document.createElement("p")
	note.className = "sub-panel__note"
	note.textContent =
		"Free выдать нельзя: это не тариф, а отсутствие подписки. Лимит трафика, число устройств и сессий задаёт сервер по тарифу — клиент их не выбирает."

	wrap.append(head, facts, form, actions, note)
	return wrap
}

/** Кнопка в строке пользователя: раскрывает панель подписки под этой строкой. */
function subscriptionToggle(user, row) {
	const button = document.createElement("button")
	button.type = "button"
	button.className = "small ghost"
	button.textContent = "Подписка"
	button.setAttribute("aria-expanded", "false")
	let panel = null
	const close = () => {
		if (panel) panel.remove()
		panel = null
		// Закрыли — автообновление снова разрешено.
		if (state.subPanelUserId === user.id) state.subPanelUserId = null
		button.setAttribute("aria-expanded", "false")
	}
	button.addEventListener("click", () => {
		if (panel) {
			close()
			return
		}
		panel = document.createElement("tr")
		panel.className = "sub-row"
		const holder = document.createElement("td")
		holder.colSpan = 8
		holder.appendChild(subscriptionPanel(user, close))
		panel.appendChild(holder)
		row.after(panel)
		// С этого момента блок ведёт себя как виджет: таблица замирает, а
		// если админ всё же нажмёт «Refresh» вручную — блок откроется заново.
		state.subPanelUserId = user.id
		button.setAttribute("aria-expanded", "true")
	})
	return button
}

function renderUsers(users) {
	const body = el("users-body")
	body.replaceChildren()
	for (const user of users) {
		const row = document.createElement("tr")
		cell(row, idChip(user.publicId))
		cell(row, user.username)
		cell(row, statusPill(user.status))
		cell(row, user.isAdmin ? "yes" : "no")
		cell(row, `${user.devices} / ${user.maxDevices}`)
		cell(row, `${user.liveSessions} / ${user.maxSessions}`)
		cell(row, subscriptionCell(user))

		const actions = document.createElement("td")
		actions.className = "actions"
		if (user.status === "ACTIVE") {
			actions.appendChild(
				actionButton("Disable", "small danger", () => {
					if (
						!confirm(
							`Disable ${user.username} (ID ${user.publicId})? Tunnels and tokens are revoked.`,
						)
					)
						return null
					return request(`/api/admin/users/${user.id}/disable`, { method: "POST" })
				}),
			)
		} else {
			actions.appendChild(
				actionButton("Enable", "small ghost", () =>
					request(`/api/admin/users/${user.id}/enable`, { method: "POST" }),
				),
			)
		}
		const subToggle = subscriptionToggle(user, row)
		actions.appendChild(subToggle)
		row.appendChild(actions)
		body.appendChild(row)
		// Раскрытый блок переживает любую перерисовку списка: после неё он
		// открывается заново у того же пользователя, а не исчезает бесследно.
		if (state.subPanelUserId === user.id) subToggle.click()
	}
	if (users.length === 0) {
		const row = document.createElement("tr")
		const td = cell(row, state.userQuery ? "No user matches that ID or nickname." : "No users yet.")
		td.colSpan = 8
		td.className = "muted"
		body.appendChild(row)
	}
}

function renderDevices(devices) {
	const body = el("devices-body")
	body.replaceChildren()
	for (const device of devices) {
		const row = document.createElement("tr")
		cell(row, device.deviceName)
		cell(row, ownerCell(device.user))
		cell(row, device.platform)
		cell(row, device.node ? device.node.name : "\u2014")
		cell(row, statusPill(device.status))
		cell(row, ago(device.lastSeen))

		const actions = document.createElement("td")
		actions.className = "actions"
		if (device.status === "ACTIVE") {
			actions.appendChild(
				actionButton("Revoke", "small danger", () => {
					if (!confirm(`Revoke ${device.deviceName}? Its WireGuard peer is removed.`)) return null
					return request(`/api/admin/devices/${device.id}/revoke`, { method: "POST" })
				}),
			)
		}
		row.appendChild(actions)
		body.appendChild(row)
	}
}

function renderSessions(sessions) {
	const body = el("sessions-body")
	body.replaceChildren()
	for (const session of sessions) {
		const row = document.createElement("tr")
		cell(row, ownerCell(session.user))
		cell(row, session.device ? session.device.deviceName : "\u2014")
		cell(row, session.node ? session.node.name : "\u2014")
		cell(row, session.assignedVpnIp)
		cell(row, statusPill(session.status))
		cell(row, ago(session.connectedAt))
		cell(row, ago(session.lastHandshakeAt))
		cell(row, `${bytes(session.bytesRx)} / ${bytes(session.bytesTx)}`)

		const actions = document.createElement("td")
		actions.className = "actions"
		if (session.status === "ACTIVE" || session.status === "PENDING") {
			actions.appendChild(
				actionButton("Close", "small danger", () =>
					request(`/api/admin/sessions/${session.id}/close`, { method: "POST" }),
				),
			)
		} else {
			actions.textContent = session.closeReason || "\u2014"
		}
		row.appendChild(actions)
		body.appendChild(row)
	}
}

function renderAudit(logs) {
	const body = el("audit-body")
	body.replaceChildren()
	for (const log of logs) {
		const row = document.createElement("tr")
		cell(row, new Date(log.createdAt).toLocaleString())
		cell(row, log.action)
		cell(row, ownerCell(log.username ? { username: log.username, publicId: log.userPublicId } : null))
		cell(row, log.ip)
		cell(row, log.metadata ? JSON.stringify(log.metadata) : "\u2014")
		body.appendChild(row)
	}
}

/* ---------------- client bug logs ---------------- */

/* Every client posts its uncaught errors to /api/telemetry/error and they
   surface here. The table is built to answer one question fast: which platform
   is breaking, on which version, and where in the app.

   Credentials are stripped server-side before a row is written, so the trace
   below can be shown verbatim without leaking a token to whoever is on
   support. */

const PLATFORM_LABELS = {
	windows: "Windows",
	android: "Android",
	extension: "Extension",
	web: "Web",
}

function platformBadge(platform) {
	const key = String(platform || "").toLowerCase()
	const span = document.createElement("span")
	span.className = `plat plat-${key}`
	span.textContent = PLATFORM_LABELS[key] || platform || "?"
	return span
}

/** Error name over its message: the name groups, the message explains. */
function errorCell(error) {
	const wrap = document.createElement("div")
	const name = document.createElement("span")
	name.className = "err-name"
	name.textContent = error.errorName || "Error"
	const message = document.createElement("span")
	message.className = "err-message"
	message.textContent = error.errorMessage || ""
	wrap.append(name, message)
	return wrap
}

function contextCell(error) {
	const span = document.createElement("span")
	if (!error.context) {
		span.className = "muted small"
		span.textContent = "unknown"
		return span
	}
	span.className = "err-context"
	span.textContent = error.context
	// The cell is clipped, the tooltip is not.
	span.title = error.context
	return span
}

/**
 * The stack trace behind a disclosure button.
 *
 * A <details> element rather than a modal: nothing to dismiss, nothing lost on
 * refresh, and two traces can stay open side by side while comparing a Windows
 * crash with the Android one that looks just like it.
 */
function stackCell(error) {
	if (!error.stackTrace) {
		const none = document.createElement("span")
		none.className = "muted small"
		none.textContent = "no trace"
		return none
	}

	const details = document.createElement("details")
	details.className = "stack"
	const summary = document.createElement("summary")
	summary.textContent = "Show stack trace"
	const pre = document.createElement("pre")
	pre.textContent = error.stackTrace
	details.append(summary, pre)

	const bits = []
	if (error.deviceId) bits.push(`device ${error.deviceId}`)
	if (error.ip) bits.push(`ip ${error.ip}`)
	if (bits.length > 0) {
		const meta = document.createElement("span")
		meta.className = "stack-meta"
		meta.textContent = bits.join(" \u00b7 ")
		details.appendChild(meta)
	}
	return details
}

function renderClientErrors(payload) {
	const body = el("errors-body")
	const errors = (payload && payload.errors) || []
	body.replaceChildren()

	const counts = (payload && payload.counts) || {}
	const parts = Object.keys(counts)
		.sort()
		.map((key) => `${PLATFORM_LABELS[key] || key} ${counts[key]}`)
	el("errors-summary").textContent =
		parts.length > 0
			? `${payload.total} stored \u00b7 ${parts.join(" \u00b7 ")}`
			: "nothing reported yet"

	if (errors.length === 0) {
		const row = document.createElement("tr")
		const td = cell(row, "No client errors in this window \u2014 quiet is good.")
		td.colSpan = 7
		td.className = "muted small"
		body.appendChild(row)
		return
	}

	for (const error of errors) {
		const row = document.createElement("tr")
		const time = cell(row, new Date(error.createdAt).toLocaleString())
		time.title = ago(error.createdAt)
		cell(row, platformBadge(error.platform))
		cell(row, error.appVersion)
		cell(row, errorCell(error))
		cell(row, contextCell(error))
		cell(row, ownerCell(error.user))
		cell(row, stackCell(error))
		body.appendChild(row)
	}
}

/** Tolerates a 404 like the egress block does: an older control server on the
    other channel simply has no telemetry route yet. */
async function loadClientErrors() {
	try {
		const filter = state.errorPlatform
			? `&platform=${encodeURIComponent(state.errorPlatform)}`
			: ""
		renderClientErrors(await request(`/api/admin/client-errors?limit=100${filter}`))
	} catch (error) {
		if (error.status === 404) return
		throw error
	}
}

/* ---------------- oracle cloud egress budget ---------------- */

/** Oracle bills egress in decimal terabytes, so 1 TB is 1e12 bytes here too. */
const EGRESS_BYTES_PER_TB = 1e12

/**
 * Alert band for the gauge: green below the first threshold, then yellow,
 * orange and red as each next configured threshold is crossed. With the
 * default OCI_EGRESS_ALERT_TB="7,8,9,9.5" that is <7 / 7-8 / 8-9 / >9 TB.
 */
function egressLevel(usedBytes, thresholds) {
	const usedTb = Number(usedBytes || 0) / EGRESS_BYTES_PER_TB
	const crossed = (thresholds || []).filter((tb) => usedTb >= tb).length
	if (crossed <= 0) return "ok"
	if (crossed === 1) return "warn"
	if (crossed === 2) return "high"
	return "crit"
}

/** The server already rounds to one decimal; never print a padded "12.0%". */
function egressPercent(value) {
	const number = Number(value || 0)
	return `${Number.isInteger(number) ? number : number.toFixed(1)}%`
}

function egressDate(iso) {
	if (!iso) return "—"
	const date = new Date(iso)
	return Number.isNaN(date.getTime()) ? "—" : date.toLocaleDateString()
}

function egressMoney(amount, currency) {
	const code = String(currency || "USD").toUpperCase()
	const value = Number(amount || 0).toFixed(2)
	if (code === "USD") return `$${value}`
	if (code === "EUR") return `€${value}`
	return `${value} ${code}`
}

function egressMetric(label, value, level) {
	const box = document.createElement("div")
	box.className = level ? `egress-metric is-${level}` : "egress-metric"
	const caption = document.createElement("span")
	caption.textContent = label
	const amount = document.createElement("strong")
	amount.textContent = value
	box.append(caption, amount)
	return box
}

function egressRow(label, value, tone, hint) {
	const row = document.createElement("div")
	row.className = tone ? `egress-row is-${tone}` : "egress-row"
	const caption = document.createElement("span")
	caption.className = "egress-label"
	caption.textContent = label
	const text = document.createElement("strong")
	text.textContent = value
	row.append(caption, text)
	if (hint) {
		const note = document.createElement("span")
		note.className = "muted small"
		note.textContent = hint
		row.appendChild(note)
	}
	return row
}

/** "31.08.2026 → 30.09.2026 · 26 days left" */
function egressCycle(view) {
	if (!view.cycleStart || !view.cycleEnd) return "not configured"
	const left = Math.max(0, Math.ceil((new Date(view.cycleEnd).getTime() - Date.now()) / 86400000))
	return `${egressDate(view.cycleStart)} → ${egressDate(view.cycleEnd)} · ${left} days left`
}

/** Always Free means a zero bill, so show the real charge, not a promise. */
function egressCostRow(charges) {
	if (!charges) {
		return egressRow(
			"Cost status",
			"Charges: no data",
			null,
			"The Usage API check is disabled or has not run yet.",
		)
	}
	if (Number(charges.amount) > 0) {
		return egressRow(
			"Cost status",
			`Charges: ${egressMoney(charges.amount, charges.currency)}`,
			"bad",
			"Zero was expected: paid resources appeared in the tenancy.",
		)
	}
	return egressRow(
		"Cost status",
		`Charges: ${egressMoney(0, charges.currency)} · Zero Cost OK`,
		"ok",
		"Always Free: no paid charges in this cycle.",
	)
}

function renderEgressBudget(view) {
	const body = el("egress-body")
	body.textContent = ""
	el("egress-updated").textContent = view.lastPolledAt ? ago(view.lastPolledAt) : "—"

	const wrap = document.createElement("div")
	wrap.className = "egress"

	// Without OCI credentials every number here would be an invented zero.
	if (!view.configured) {
		const note = document.createElement("div")
		note.className = "notice"
		const title = document.createElement("strong")
		title.textContent = "Oracle egress tracking is not configured"
		const text = document.createElement("p")
		text.className = "muted small"
		text.textContent = `Set OCI_* and OCI_BILLING_CYCLE_START in the control server .env to see usage against the ${view.budgetLabel} budget and the charges.`
		note.append(title, text)
		wrap.appendChild(note)
		body.appendChild(wrap)
		return
	}

	const level = egressLevel(view.usedBytes, view.thresholdsTb)
	const usedTb = Number(view.usedBytes || 0) / EGRESS_BYTES_PER_TB

	const metrics = document.createElement("div")
	metrics.className = "egress-metrics"
	metrics.append(
		egressMetric("Used", `${view.usedLabel} (${egressPercent(view.usedPercent)})`, level),
		egressMetric("Remaining", view.remainingLabel),
		egressMetric("Always Free budget", view.budgetLabel),
	)
	wrap.appendChild(metrics)

	const gauge = document.createElement("div")
	gauge.className = `egress-gauge is-${level}`
	gauge.setAttribute("role", "progressbar")
	gauge.setAttribute("aria-valuemin", "0")
	gauge.setAttribute("aria-valuemax", "100")
	gauge.setAttribute("aria-valuenow", String(Math.round(Number(view.usedPercent || 0))))
	gauge.setAttribute("aria-label", `Used ${view.usedLabel} of ${view.budgetLabel}`)
	const fill = document.createElement("i")
	// The CSP has no unsafe-inline, so sizes go through the CSSOM, like loadBar.
	fill.style.width = `${Math.max(0, Math.min(100, Number(view.usedPercent || 0)))}%`
	gauge.appendChild(fill)
	// Marks sit at the real position of every Telegram threshold on the scale.
	for (const tb of view.thresholdsTb || []) {
		const at = (tb * EGRESS_BYTES_PER_TB) / (view.budgetBytes || EGRESS_BYTES_PER_TB)
		if (!(at > 0) || at >= 1) continue
		const tick = document.createElement("b")
		if ((view.alertedTb || []).includes(tb)) tick.className = "is-sent"
		tick.style.left = `${at * 100}%`
		tick.title = `${tb} TB threshold`
		gauge.appendChild(tick)
	}
	wrap.appendChild(gauge)

	const legend = document.createElement("div")
	legend.className = "egress-legend"
	const used = document.createElement("span")
	used.textContent = `Used: ${view.usedLabel} / ${view.budgetLabel} (${egressPercent(view.usedPercent)})`
	const remaining = document.createElement("span")
	remaining.className = "muted"
	remaining.textContent = `Remaining: ${view.remainingLabel}`
	legend.append(used, remaining)
	wrap.appendChild(legend)

	wrap.appendChild(egressRow("Billing cycle", egressCycle(view)))
	wrap.appendChild(egressCostRow(view.charges))

	const alerts = document.createElement("div")
	alerts.className = "egress-alerts"
	const alertsLabel = document.createElement("span")
	alertsLabel.className = "egress-label"
	alertsLabel.textContent = "Telegram alerts"
	alerts.appendChild(alertsLabel)
	for (const tb of view.thresholdsTb || []) {
		const sent = (view.alertedTb || []).includes(tb)
		// Crossed but never announced means the bot could not deliver the alert.
		const missed = !sent && usedTb >= tb
		const pill = document.createElement("span")
		pill.className = `thr ${sent ? "is-sent" : missed ? "is-missed" : "is-armed"}`
		pill.title = sent
			? "Alert sent"
			: missed
				? "Threshold crossed, but no alert was sent"
				: "Waiting for the threshold"
		const dot = document.createElement("i")
		const text = document.createElement("span")
		text.textContent = `${tb} TB`
		pill.append(dot, text)
		alerts.appendChild(pill)
	}
	if (!(view.thresholdsTb || []).length) {
		const none = document.createElement("span")
		none.className = "muted small"
		none.textContent = "no thresholds set (OCI_EGRESS_ALERT_TB)"
		alerts.appendChild(none)
	}
	wrap.appendChild(alerts)

	if (view.lastError) {
		const error = document.createElement("p")
		error.className = "egress-error"
		error.textContent = `The last Oracle poll failed: ${view.lastError}`
		wrap.appendChild(error)
	}

	body.appendChild(wrap)
}

/* ---------------- data loading ---------------- */

/** Oracle figures are optional data: a 404 must not blank the dashboard. */
async function loadEgressBudget() {
	try {
		renderEgressBudget(await request("/api/admin/traffic-budget"))
	} catch (error) {
		if (error.status !== 404) throw error
		const body = el("egress-body")
		body.textContent = ""
		const note = document.createElement("p")
		note.className = "muted small"
		note.textContent = "This control server does not serve /api/admin/traffic-budget yet."
		body.appendChild(note)
		el("egress-updated").textContent = "—"
	}
}

/* ---------------- billing: trial offer + promo codes ---------------- */
/* Длина акции, окно регистрации, тариф, цена и сам выключатель лежат в базе,
   поэтому отключить рубль или отдать неделю Pro — это клик здесь, а не деплой.
   Промокоды тоже заводятся и снимаются тут: контроль над скидками должен быть в
   панели, а не в SQL-консоли. */

const MONEY_SYMBOL = { RUB: "\u20bd", KZT: "\u20b8", USD: "$", EUR: "\u20ac" }

function minorMoney(minor, currency) {
	const amount = Number(minor || 0) / 100
	const text = Number.isInteger(amount) ? String(amount) : amount.toFixed(2)
	const symbol = MONEY_SYMBOL[String(currency || "").toUpperCase()] || currency || ""
	return symbol ? `${text} ${symbol}` : text
}

const TRIAL_FIELDS = ["trial-enabled", "trial-telegram", "trial-plan", "trial-days", "trial-window", "trial-price", "trial-save"]

function setTrialBusy(isBusy) {
	state.trialBusy = isBusy
	el("trial-block").setAttribute("aria-busy", String(isBusy))
	for (const id of TRIAL_FIELDS) el(id).disabled = isBusy || !state.trial
}

function trialError(text) {
	const box = el("trial-error")
	box.textContent = text
	box.hidden = !text
}

function renderTrial(view) {
	state.trial = view
	const trial = view.trial || {}
	const plan = view.plan || {}
	const stats = view.stats || {}
	el("trial-enabled").checked = Boolean(trial.enabled)
	el("trial-telegram").checked = Boolean(trial.requireTelegram)
	el("trial-plan").value = trial.planCode === "pro" ? "pro" : "basic"
	el("trial-days").value = String(Number(trial.days || 7))
	el("trial-window").value = String(Number(trial.eligibilityDays || 14))
	el("trial-price").value = (Number(trial.priceKopecks || 100) / 100).toFixed(2)
	el("trial-scope").textContent = view.billingEnabled
		? `Gateway ${view.provider || "\u2014"} \u00b7 sells ${plan.code || "\u2014"} \u00b7 ${minorMoney(plan.priceMinor, plan.currency)} for ${Number(plan.days || 0)} days`
		: "Billing is switched off for this channel, so nothing is sold until a gateway is configured."
	el("trial-stats").textContent = `Claimed ${Number(stats.orders || 0)} \u00b7 paid ${Number(stats.paid || 0)}`
	el("trial-updated").textContent = trial.updatedAt ? `updated ${ago(trial.updatedAt)}` : ""
	trialError("")
	setTrialBusy(false)
}

async function loadTrial() {
	try {
		renderTrial(await request("/api/admin/billing/trial"))
		return true
	} catch (error) {
		state.trial = null
		setTrialBusy(true)
		trialError(
			error.status === 404
				? "This control server does not expose the trial offer yet."
				: `Could not load the trial offer: ${error.message}`,
		)
		return false
	}
}

/** Ranges are checked here as well, so a typo gets a plain sentence instead of
    a 400 from the API. */
async function saveTrial() {
	if (!state.trial || state.trialBusy) return
	const days = Number(el("trial-days").value)
	const eligibility = Number(el("trial-window").value)
	const price = Math.round(Number(el("trial-price").value) * 100)
	if (!Number.isInteger(days) || days < 1 || days > 90) {
		trialError("Days of access: a whole number from 1 to 90.")
		return
	}
	if (!Number.isInteger(eligibility) || eligibility < 1 || eligibility > 365) {
		trialError("Sign-up window: a whole number of days from 1 to 365.")
		return
	}
	if (!Number.isFinite(price) || price < 100) {
		trialError("The gateway refuses anything below one rouble.")
		return
	}
	const body = {
		enabled: el("trial-enabled").checked,
		requireTelegram: el("trial-telegram").checked,
		planCode: el("trial-plan").value === "pro" ? "pro" : "basic",
		days,
		eligibilityDays: eligibility,
		priceKopecks: price,
	}
	setTrialBusy(true)
	try {
		await request("/api/admin/billing/trial", { method: "POST", body })
		await loadTrial()
		toast(
			body.enabled
				? `Trial offer: ${days} days of ${body.planCode} for ${minorMoney(price, "RUB")}, new accounts within ${eligibility} days`
				: "Trial offer switched off: the banner disappears and claims are refused.",
		)
	} catch (error) {
		await loadTrial()
		trialError(`The offer was not saved: ${error.message}`)
		toast(error.message, true)
	} finally {
		setTrialBusy(!state.trial)
	}
}

function promoBoxError(text) {
	const box = el("promo-error")
	box.textContent = text
	box.hidden = !text
}

function promoWindow(promo) {
	if (!promo.startsAt && !promo.endsAt) return "always"
	const from = promo.startsAt ? dateLabel(promo.startsAt) : "now"
	const to = promo.endsAt ? dateLabel(promo.endsAt) : "\u221e"
	return `${from} \u2192 ${to}`
}

function promoCodeCell(promo) {
	const box = document.createElement("div")
	box.className = "promo-code"
	const code = document.createElement("strong")
	code.textContent = promo.code
	box.appendChild(code)
	if (promo.description) {
		const note = document.createElement("span")
		note.className = "sub-line"
		note.textContent = promo.description
		box.appendChild(note)
	}
	return box
}

function renderPromos(promos) {
	state.promos = promos
	const body = el("promos-body")
	body.replaceChildren()
	if (!promos.length) {
		const row = document.createElement("tr")
		const td = cell(row, "No promo codes yet.")
		td.colSpan = 7
		td.className = "muted"
		body.appendChild(row)
		promoBoxError("")
		return
	}
	for (const promo of promos) {
		const row = document.createElement("tr")
		// Выключенный код остаётся в списке: его включают чаще, чем удаляют.
		if (!promo.active) row.className = "is-off"
		cell(row, promoCodeCell(promo))
		cell(row, `\u2212${promo.percentOff}%`)
		cell(row, promo.planCodes && promo.planCodes.length ? promo.planCodes.join(", ") : "every paid plan")
		cell(row, promo.maxRedemptions ? `${promo.redeemedCount} / ${promo.maxRedemptions}` : String(promo.redeemedCount))
		cell(row, promo.perUserLimit > 0 ? `${promo.perUserLimit}\u00d7` : "unlimited")
		cell(row, promoWindow(promo))
		const actions = document.createElement("div")
		actions.className = "promo-actions"
		actions.append(
			actionButton(promo.active ? "Switch off" : "Switch on", "ghost small", () =>
				request(`/api/admin/billing/promos/${promo.id}`, {
					method: "POST",
					body: { active: !promo.active },
				}),
			),
			actionButton("Delete", "ghost small danger", () => {
				// Заказы хранят свою копию кода и скидки, так что историю это не ломает.
				if (!confirm(`Delete ${promo.code}? Paid orders keep their own copy of the code.`)) return Promise.resolve()
				return request(`/api/admin/billing/promos/${promo.id}`, { method: "DELETE" })
			}),
		)
		cell(row, actions)
		body.appendChild(row)
	}
	promoBoxError("")
}

async function loadPromos() {
	try {
		const data = await request("/api/admin/billing/promos")
		renderPromos(data.promos || [])
		return true
	} catch (error) {
		state.promos = []
		el("promos-body").replaceChildren()
		promoBoxError(
			error.status === 404
				? "This control server does not expose promo codes yet."
				: `Could not load promo codes: ${error.message}`,
		)
		return false
	}
}

/** Empty plans mean every paid plan; an empty cap means no cap. New codes are
    one per account, which is what a public discount usually needs. */
async function createPromo() {
	const code = el("promo-code").value.trim().toUpperCase()
	const percentOff = Number(el("promo-percent").value)
	const plans = el("promo-plans")
		.value.split(",")
		.map((item) => item.trim().toLowerCase())
		.filter(Boolean)
	const rawCap = el("promo-limit").value.trim()
	if (code.length < 2) {
		promoBoxError("A code needs at least two characters.")
		return
	}
	if (!Number.isInteger(percentOff) || percentOff < 1 || percentOff > 100) {
		promoBoxError("The discount is a whole percentage from 1 to 100.")
		return
	}
	const body = { code, percentOff, perUserLimit: 1 }
	if (plans.length) body.planCodes = plans
	if (rawCap) body.maxRedemptions = Number(rawCap)
	try {
		await request("/api/admin/billing/promos", { method: "POST", body })
		el("promo-code").value = ""
		el("promo-percent").value = ""
		el("promo-plans").value = ""
		el("promo-limit").value = ""
		el("promo-form").hidden = true
		promoBoxError("")
		toast(`Promo ${code} created: \u2212${percentOff}%`)
		await loadPromos()
	} catch (error) {
		promoBoxError(`The code was not created: ${error.message}`)
		toast(error.message, true)
	}
}

async function loadDeploy() {
	try {
		const status = await request("/api/admin/deploy/status")
		renderDeploy(status)
	} catch (error) {
		// An older control server without the deploy routes must not break the rest.
		if (error.status !== 404) throw error
	}
}

async function loadAll() {
	if (!state.accessToken || state.busy) return
	state.busy = true
	try {
		const liveOnly = el("live-only").checked ? "?live=true" : ""
		const query = state.userQuery ? `?q=${encodeURIComponent(state.userQuery)}` : ""
		const [overview, nodes, users, devices, sessions, audit] = await Promise.all([
			request("/api/admin/overview"),
			request("/api/admin/nodes"),
			request(`/api/admin/users${query}`),
			request("/api/admin/devices"),
			request(`/api/admin/sessions${liveOnly}`),
			request("/api/admin/audit?limit=40"),
		])
		renderCards(overview)
		renderNodes(nodes.nodes)
		renderUsers(users.users)
		renderDevices(devices.devices)
		renderSessions(sessions.sessions)
		renderAudit(audit.logs)
		// Optional/rolling-deploy data loaders isolate their own availability errors.
		await Promise.all([
			loadServiceSettings(),
			loadEgressBudget(),
			loadDeploy(),
			loadClientErrors(),
			loadTrial(),
			loadPromos(),
		])
	} catch (error) {
		if (error.status === 401 || error.status === 403) signOut(error.message)
		else toast(error.message, true)
	} finally {
		state.busy = false
	}
}

async function loadUsersOnly() {
	if (!state.accessToken) return
	try {
		const query = state.userQuery ? `?q=${encodeURIComponent(state.userQuery)}` : ""
		const users = await request(`/api/admin/users${query}`)
		renderUsers(users.users)
	} catch (error) {
		toast(error.message, true)
	}
}

function startAutoRefresh() {
	stopAutoRefresh()
	if (!el("auto-refresh").checked) return
	state.timer = setInterval(() => {
		// Открытая панель подписки — это форма, которую заполняют руками.
		// Перерисовывать таблицу под руками нельзя.
		if (state.subPanelUserId) return
		void loadAll()
	}, 10000)
}

function stopAutoRefresh() {
	if (state.timer) clearInterval(state.timer)
	state.timer = null
}

/** While a deploy job runs, follow its log more closely than the 10 s cycle. */
function startJobPolling() {
	if (state.jobTimer) return
	state.jobTimer = setInterval(() => {
		void loadDeploy()
	}, 3000)
}

function stopJobPolling() {
	if (state.jobTimer) clearInterval(state.jobTimer)
	state.jobTimer = null
}

function selectTab(tab) {
	state.tab = tab
	for (const button of document.querySelectorAll(".tab")) {
		button.classList.toggle("is-active", button.dataset.tab === tab)
	}
	for (const view of document.querySelectorAll(".tabview")) {
		view.hidden = view.dataset.view !== tab
	}
}

function showDashboard() {
	el("login-view").hidden = true
	el("tabs").hidden = false
	el("dashboard-view").hidden = false
	el("session-box").hidden = false
	el("who").textContent = `${state.username} \u00b7 ID ${state.publicId || "\u2014"}`
	selectTab(state.tab)
}

function signOut(message) {
	stopAutoRefresh()
	stopJobPolling()
	state.accessToken = null
	state.refreshToken = null
	state.username = null
	state.publicId = null
	state.serviceSettings = null
	setServiceBusy(true)
	el("tabs").hidden = true
	el("dashboard-view").hidden = true
	el("session-box").hidden = true
	el("login-view").hidden = false
	if (message) toast(message, true)
}

/* ---------------- deploy actions ---------------- */

async function runDeployAction(button, path, confirmText) {
	if (!confirm(confirmText)) return
	button.disabled = true
	try {
		const result = await request(path, { method: "POST", body: {} })
		toast(result.note || "Deployment queued")
		await loadDeploy()
	} catch (error) {
		toast(error.message, true)
	} finally {
		button.disabled = false
	}
}

/* ---------------- events ---------------- */

el("login-form").addEventListener("submit", async (event) => {
	event.preventDefault()
	const errorBox = el("login-error")
	errorBox.hidden = true
	try {
		const data = await request("/api/auth/login", {
			method: "POST",
			body: { username: el("username").value, password: el("password").value },
		})
		if (!data.user.isAdmin) throw new Error("This account is not an administrator")
		state.accessToken = data.accessToken
		state.refreshToken = data.refreshToken
		state.username = data.user.username
		state.publicId = data.user.publicId || null
		el("password").value = ""
		showDashboard()
		await loadAll()
		startAutoRefresh()
	} catch (error) {
		errorBox.textContent = error.message
		errorBox.hidden = false
	}
})

el("logout-btn").addEventListener("click", async () => {
	try {
		await request("/api/auth/logout", { method: "POST", body: {} })
	} catch {
		/* the local session is dropped regardless */
	}
	signOut("Signed out")
})

el("refresh-btn").addEventListener("click", () => {
	void loadAll()
})
el("auto-refresh").addEventListener("change", startAutoRefresh)
el("live-only").addEventListener("change", () => {
	void loadAll()
})

el("registration-enabled").addEventListener("change", (event) => {
	void mutateServiceSettings({ registrationEnabled: event.currentTarget.checked })
})

el("emergency-maintenance").addEventListener("change", (event) => {
	if (!event.currentTarget.checked) {
		void mutateServiceSettings({ maintenance: false })
		return
	}
	// Do not show the destructive state as active before the server confirms it.
	event.currentTarget.checked = false
	el("maintenance-scope").textContent = `Scope: ${channelScopeLabel()}. The other channel is not affected.`
	el("maintenance-dialog").showModal()
})

el("maintenance-dialog").addEventListener("close", (event) => {
	if (event.currentTarget.returnValue === "confirm") {
		void mutateServiceSettings({ maintenance: true })
	} else if (state.serviceSettings) {
		renderServiceSettings(state.serviceSettings)
	}
})

el("error-platform").addEventListener("change", (event) => {
	state.errorPlatform = event.target.value
	void loadClientErrors().catch((error) => toast(error.message, true))
})

/**
 * Clears the stored reports for the current filter.
 *
 * Collection is *not* switched off: the server deletes only what already
 * existed when the request was made, so anything reported from now on shows
 * up in the same list. That is the whole point - wipe the noise from the old
 * build, then watch what the new one sends.
 */
/**
 * Убирает мёртвые строки устройств: отозванные надгробия и те, через которые
 * ни разу не шёл туннель. Активные устройства не трогаются, так что после
 * чистки счётчики в панели показывают реальность, а не «58 / 5».
 */
const devicesPurgeButton = el("devices-purge")
if (devicesPurgeButton) {
	devicesPurgeButton.addEventListener("click", async () => {
		const confirmed = window.confirm(
			"Purge revoked and never-used device records? Active devices stay untouched.",
		)
		if (!confirmed) return
		devicesPurgeButton.disabled = true
		try {
			const result = await request("/api/admin/devices/stale?days=0", { method: "DELETE" })
			toast(`Removed ${result.removed} device record${result.removed === 1 ? "" : "s"}`)
			await loadAll()
		} catch (error) {
			toast(error.message, true)
		} finally {
			devicesPurgeButton.disabled = false
		}
	})
}

el("errors-clear").addEventListener("click", async () => {
	const scope = state.errorPlatform
		? PLATFORM_LABELS[state.errorPlatform] || state.errorPlatform
		: "all platforms"
	const confirmed = window.confirm(
		`Clear the client error log for ${scope}? Reporting stays on, so new errors keep arriving.`,
	)
	if (!confirmed) return
	const button = el("errors-clear")
	button.disabled = true
	try {
		const filter = state.errorPlatform
			? `?platform=${encodeURIComponent(state.errorPlatform)}`
			: ""
		const result = await request(`/api/admin/client-errors${filter}`, { method: "DELETE" })
		toast(`Cleared ${result.removed} report${result.removed === 1 ? "" : "s"}`)
		await loadClientErrors()
	} catch (error) {
		toast(error.message, true)
	} finally {
		button.disabled = false
	}
})

for (const button of document.querySelectorAll(".tab")) {
	button.addEventListener("click", () => selectTab(button.dataset.tab))
}

el("user-search").addEventListener("input", (event) => {
	state.userQuery = event.target.value.trim()
	if (state.searchTimer) clearTimeout(state.searchTimer)
	state.searchTimer = setTimeout(() => {
		void loadUsersOnly()
	}, 350)
})

el("deploy-beta-btn").addEventListener("click", (event) => {
	void runDeployAction(
		event.currentTarget,
		"/api/admin/deploy/beta",
		"Rebuild BETA from the current source tree? Production is not touched.",
	)
})

el("beta-start-btn").addEventListener("click", (event) => {
	void runDeployAction(
		event.currentTarget,
		"/api/admin/deploy/beta/start",
		"Start BETA (wg1 on udp/51821, beta API, beta node agent)? Production is not touched.",
	)
})

el("beta-restart-btn").addEventListener("click", (event) => {
	void runDeployAction(
		event.currentTarget,
		"/api/admin/deploy/beta/restart",
		"Restart BETA? Beta tunnels drop for a few seconds. Production is not touched.",
	)
})

el("beta-stop-btn").addEventListener("click", (event) => {
	void runDeployAction(
		event.currentTarget,
		"/api/admin/deploy/beta/stop",
		"Stop BETA completely? Beta sessions are closed and wg1 goes down until you start it again. Production keeps running on wg0.",
	)
})

el("promote-btn").addEventListener("click", (event) => {
	void runDeployAction(
		event.currentTarget,
		"/api/admin/deploy/promote",
		"Promote the BETA release into PRODUCTION?\n\n" +
			"\u2022 the prod database is dumped with pg_dump first\n" +
			"\u2022 only code moves, prod rows stay as they are\n" +
			"\u2022 the switch is a symlink flip, prod restarts once",
	)
})

el("rollback-btn").addEventListener("click", (event) => {
	void runDeployAction(
		event.currentTarget,
		"/api/admin/deploy/rollback",
		"Point PRODUCTION back at the previous release?\n\n" +
			"Code only \u2014 rows written after the promote are kept.",
	)
})

el("enroll-btn").addEventListener("click", async () => {
	try {
		const data = await request("/api/admin/nodes/enrollment-token", {
			method: "POST",
			body: { note: "admin panel" },
		})
		const box = el("enroll-box")
		box.replaceChildren()
		const title = document.createElement("strong")
		title.textContent = "One-time enrollment token (shown once):"
		const code = document.createElement("code")
		code.textContent = data.enrollmentToken
		const hint = document.createElement("p")
		hint.className = "muted small"
		hint.textContent = `Valid until ${new Date(data.expiresAt).toLocaleString()}. Put it in NODE_ENROLLMENT_TOKEN on the node, then start the agent.`
		box.append(title, code, hint)
		box.hidden = false
	} catch (error) {
		toast(error.message, true)
	}
})

el("create-user-btn").addEventListener("click", () => {
	el("create-user-form").hidden = false
})
el("cancel-user-btn").addEventListener("click", () => {
	el("create-user-form").hidden = true
})
el("create-user-form").addEventListener("submit", async (event) => {
	event.preventDefault()
	try {
		const created = await request("/api/admin/users", {
			method: "POST",
			body: {
				username: el("new-username").value,
				password: el("new-password").value,
			},
		})
		el("new-username").value = ""
		el("new-password").value = ""
		el("create-user-form").hidden = true
		toast(`User created with ID ${created.user.publicId}`)
		await loadAll()
	} catch (error) {
		toast(error.message, true)
	}
})

el("trial-save").addEventListener("click", () => {
	void saveTrial()
})

el("promo-new-btn").addEventListener("click", () => {
	el("promo-form").hidden = false
	el("promo-code").focus()
})
el("promo-cancel-btn").addEventListener("click", () => {
	el("promo-form").hidden = true
})
el("promo-form").addEventListener("submit", (event) => {
	event.preventDefault()
	void createPromo()
})

void loadChannelBadge()
