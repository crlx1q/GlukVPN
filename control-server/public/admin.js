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
		const badge = el("channel-badge")
		badge.textContent = `${String(data.channel || "?").toUpperCase()} ${data.version || ""}`.trim()
		badge.classList.toggle("is-beta", isBeta)
		el("login-channel").textContent = isBeta
			? "You are on the BETA control plane. Test accounts and test nodes only."
			: "Production control plane."
	} catch {
		el("channel-badge").textContent = "offline"
	}
}

/* ---------------- rendering ---------------- */

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
		td.colSpan = 13
		td.className = "muted"
		body.appendChild(row)
	}
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
		cell(
			row,
			user.subscription
				? `${user.subscription.status} \u2192 ${new Date(user.subscription.expiresAt).toLocaleDateString()}`
				: "none",
		)

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
		row.appendChild(actions)
		body.appendChild(row)
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

/* ---------------- data loading ---------------- */

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
		await loadDeploy()
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

void loadChannelBadge()
