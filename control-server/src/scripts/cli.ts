/**
 * Admin CLI for the control plane. Runs on the control server itself and talks
 * to PostgreSQL directly (it is not exposed over HTTP).
 *
 * Usage:  npm run cli -- <command> [args] [--flags]
 *         npm run cli:dev -- <command>            (ts-node/tsx, no build needed)
 *
 * There is deliberately no command that executes shell commands, reads private
 * keys or prints password hashes.
 */
import { config } from "../config"
import { generatePassword, generateSecret, hashPassword, hashSecret } from "../lib/crypto"
import { bytesToNumber, disconnectPrisma, prisma } from "../prisma"
import { runMonitorTick } from "../services/monitor"
import { effectiveNodeStatus, nodeEndpoint, nodeLoadPercent } from "../services/nodes"
import {
	closeSession,
	closeSessionsForDevice,
	closeSessionsForNode,
	closeSessionsForUser,
	ensureIpPool,
} from "../services/sessions"
import { revokeRefreshTokens } from "../services/tokens"

type Args = { positional: string[]; flags: Record<string, string | boolean> }

function parseArgs(argv: string[]): Args {
	const positional: string[] = []
	const flags: Record<string, string | boolean> = {}
	for (let i = 0; i < argv.length; i += 1) {
		const token = argv[i]
		if (!token) continue
		if (token.startsWith("--")) {
			const name = token.slice(2)
			const next = argv[i + 1]
			if (next && !next.startsWith("--")) {
				flags[name] = next
				i += 1
			} else {
				flags[name] = true
			}
		} else {
			positional.push(token)
		}
	}
	return { positional, flags }
}

function table(rows: Array<Record<string, string | number | null>>): void {
	if (rows.length === 0) {
		console.log("(no rows)")
		return
	}
	const columns = Object.keys(rows[0]!)
	const widths = columns.map((column) =>
		Math.max(
			column.length,
			...rows.map((row) => String(row[column] ?? "-").length),
		),
	)
	const line = (cells: string[]) =>
		cells.map((cell, index) => cell.padEnd(widths[index]!)).join("  ")
	console.log(line(columns))
	console.log(line(widths.map((width) => "-".repeat(width))))
	for (const row of rows) {
		console.log(line(columns.map((column) => String(row[column] ?? "-"))))
	}
}

function bytes(value: number): string {
	if (value < 1024) return `${value}B`
	if (value < 1048576) return `${(value / 1024).toFixed(1)}KB`
	if (value < 1073741824) return `${(value / 1048576).toFixed(1)}MB`
	return `${(value / 1073741824).toFixed(2)}GB`
}

/**
 * A user can be referenced by nickname or by the immutable public ID.
 * Nicknames change freely; the ID never does, so bans and support lookups
 * should use it. Digits are treated as an ID first, then as a nickname.
 */
async function findUser(ref: string) {
	const value = ref.trim()
	if (!value) throw new Error("expected a nickname or an ID (e.g. 00000001)")
	if (/^\d+$/.test(value)) {
		const byId = await prisma.user.findUnique({
			where: { publicId: value.padStart(8, "0") },
		})
		if (byId) return byId
	}
	const user = await prisma.user.findUnique({ where: { username: value } })
	if (!user) throw new Error(`User "${value}" not found (tried ID and nickname)`)
	return user
}

async function findNode(name: string) {
	const node = await prisma.vpnNode.findUnique({ where: { name } })
	if (!node) throw new Error(`Node "${name}" not found`)
	return node
}

const HELP = `GlukVPN control CLI

Users        <username> may also be the immutable ID, e.g. 00000001
  users:list [--q <id|nickname>]
  users:create <username> [--password <pw>] [--admin] [--days 365]
  users:disable <username>            closes tunnels + revokes refresh tokens
  users:enable  <username>
  users:rename  <username> <newNickname>   nickname changes, ID never does
  users:passwd  <username> [--password <pw>]
  users:extend  <username> [--days 365]

Devices
  devices:list [--user <username>]
  devices:revoke <deviceId>

Nodes
  nodes:list
  nodes:token [--note "de-01 reinstall"]   one-time enrollment token
  nodes:disable <name>                     closes tunnels, refuses new ones
  nodes:enable  <name>
  nodes:delete  <name>                     registry row only (node must be idle)
  nodes:revoke-tokens <name>               forces re-enrollment

Sessions
  sessions:list [--live]
  sessions:close <sessionId>

Deployments (read-only here; the worker runs the scripts)
  deploy:status                            this channel + last promote
  deploy:jobs [--limit 10]                 deployment history with exit codes

Other
  audit:tail [--limit 30]
  monitor:tick                             run one liveness/housekeeping pass
`

async function main(): Promise<void> {
	const { positional, flags } = parseArgs(process.argv.slice(2))
	const command = positional[0] ?? "help"

	switch (command) {
		case "help":
		case "--help":
		case "-h": {
			console.log(HELP)
			return
		}

		/* ---------------- users ---------------- */
		case "users:list": {
			// Search by nickname or by ID:  users:list --q 00000001
			const query = typeof flags.q === "string" ? flags.q.trim() : ""
			const nameMatch = { username: { contains: query, mode: "insensitive" as const } }
			const where =
				query.length === 0
					? {}
					: /^\d+$/.test(query)
						? { OR: [nameMatch, { publicId: { contains: query } }] }
						: { OR: [nameMatch] }
			const users = await prisma.user.findMany({
				where,
				orderBy: { createdAt: "asc" },
				include: {
					subscriptions: { orderBy: { expiresAt: "desc" }, take: 1 },
					_count: { select: { devices: true } },
				},
			})
			const rows = []
			for (const user of users) {
				const live = await prisma.session.count({
					where: { userId: user.id, status: { in: ["PENDING", "ACTIVE"] } },
				})
				rows.push({
					id: user.publicId,
					username: user.username,
					status: user.status,
					admin: user.isAdmin ? "yes" : "no",
					devices: `${user._count.devices}/${user.maxDevices}`,
					live,
					subscription: user.subscriptions[0]
						? `${user.subscriptions[0].status} until ${user.subscriptions[0].expiresAt.toISOString().slice(0, 10)}`
						: "none",
					uuid: user.id,
				})
			}
			table(rows)
			return
		}

		case "users:create": {
			const username = positional[1]
			if (!username) throw new Error("usage: users:create <username> [--password <pw>]")
			const existing = await prisma.user.findUnique({ where: { username } })
			if (existing) throw new Error(`User "${username}" already exists`)

			const password =
				typeof flags.password === "string" ? flags.password : generatePassword()
			if (password.length < 8) throw new Error("Password must be at least 8 characters")
			const days = Number(flags.days ?? 365)

			const user = await prisma.user.create({
				data: {
					username,
					passwordHash: await hashPassword(password),
					isAdmin: flags.admin === true,
					maxDevices: config.MAX_DEVICES_PER_USER,
					maxSessions: config.MAX_CONCURRENT_SESSIONS,
					subscriptions: {
						create: {
							plan: "test",
							status: "ACTIVE",
							expiresAt: new Date(Date.now() + days * 86400_000),
						},
					},
				},
			})
			console.log(`user created: ${user.username} (admin: ${user.isAdmin})`)
			// Printed once; only the Argon2id hash is stored.
			console.log(`password: ${password}`)
			return
		}

		case "users:disable": {
			const user = await findUser(positional[1] ?? "")
			const closed = await closeSessionsForUser(user.id, "user_disabled")
			await prisma.user.update({ where: { id: user.id }, data: { status: "DISABLED" } })
			const revoked = await revokeRefreshTokens({ userId: user.id })
			console.log(
				`${user.username} disabled. sessions closed: ${closed}, refresh tokens revoked: ${revoked}`,
			)
			return
		}

		case "users:enable": {
			const user = await findUser(positional[1] ?? "")
			await prisma.user.update({ where: { id: user.id }, data: { status: "ACTIVE" } })
			console.log(`${user.username} enabled`)
			return
		}

		case "users:rename": {
			const user = await findUser(positional[1] ?? "")
			const next = (positional[2] ?? "").trim()
			if (next.length < 3 || next.length > 32) {
				throw new Error("usage: users:rename <id|nickname> <newNickname>   (3-32 chars)")
			}
			if (next === user.username) {
				console.log(`${user.username} already uses that nickname`)
				return
			}
			const taken = await prisma.user.findUnique({ where: { username: next } })
			if (taken) throw new Error(`Nickname "${next}" is already taken`)
			await prisma.user.update({ where: { id: user.id }, data: { username: next } })
			// The ID column is protected by a database trigger, so it cannot follow.
			console.log(`ID ${user.publicId}: ${user.username} -> ${next}`)
			return
		}

		case "users:passwd": {
			const user = await findUser(positional[1] ?? "")
			const password =
				typeof flags.password === "string" ? flags.password : generatePassword()
			if (password.length < 8) throw new Error("Password must be at least 8 characters")
			await prisma.user.update({
				where: { id: user.id },
				data: { passwordHash: await hashPassword(password) },
			})
			// All existing logins are invalidated so a leaked password cannot be reused.
			const revoked = await revokeRefreshTokens({ userId: user.id })
			console.log(`password updated for ${user.username} (refresh tokens revoked: ${revoked})`)
			console.log(`password: ${password}`)
			return
		}

		case "users:extend": {
			const user = await findUser(positional[1] ?? "")
			const days = Number(flags.days ?? 365)
			const existing = await prisma.subscription.findFirst({
				where: { userId: user.id },
				orderBy: { expiresAt: "desc" },
			})
			const expiresAt = new Date(Date.now() + days * 86400_000)
			if (existing) {
				await prisma.subscription.update({
					where: { id: existing.id },
					data: { status: "ACTIVE", expiresAt },
				})
			} else {
				await prisma.subscription.create({
					data: { userId: user.id, plan: "test", status: "ACTIVE", expiresAt },
				})
			}
			console.log(`subscription for ${user.username} active until ${expiresAt.toISOString()}`)
			return
		}

		/* ---------------- deployments ---------------- */
		// Read-only on purpose: queuing a deployment from a shell would bypass the
		// admin audit trail, so that stays in the panel (POST /api/admin/deploy/*).
		case "deploy:status": {
			const active = await prisma.deployJob.findFirst({
				where: { status: { in: ["QUEUED", "RUNNING"] } },
				orderBy: { createdAt: "desc" },
			})
			const lastPromote = await prisma.deployJob.findFirst({
				where: { action: "PROMOTE_BETA_TO_PROD", status: "SUCCEEDED" },
				orderBy: { createdAt: "desc" },
			})
			console.log(`channel:      ${config.CHANNEL}`)
			console.log(`version:      ${config.APP_VERSION}`)
			console.log(`commit:       ${config.GIT_COMMIT || "-"}`)
			console.log(`released at:  ${config.RELEASED_AT || "-"}`)
			console.log(
				`active job:   ${active ? `${active.action} ${active.status} (${active.id})` : "none"}`,
			)
			if (lastPromote) {
				console.log(
					`last promote: ${lastPromote.releaseId ?? "-"} at ${
						lastPromote.finishedAt?.toISOString() ?? "-"
					}`,
				)
				if (lastPromote.previousReleaseId) {
					console.log(`rollback to:  ${lastPromote.previousReleaseId}`)
				}
				if (lastPromote.backupPath) console.log(`prod backup:  ${lastPromote.backupPath}`)
			} else {
				console.log("last promote: never")
			}
			return
		}

		case "deploy:jobs": {
			const limit = Math.min(Math.max(Number(flags.limit ?? 10), 1), 50)
			const jobs = await prisma.deployJob.findMany({
				orderBy: { createdAt: "desc" },
				take: limit,
				include: { requestedBy: { select: { username: true, publicId: true } } },
			})
			table(
				jobs.map((job) => ({
					created: job.createdAt.toISOString().slice(0, 19).replace("T", " "),
					action: job.action,
					status: job.status,
					release: job.releaseId ?? "-",
					previous: job.previousReleaseId ?? "-",
					exit: job.exitCode ?? "-",
					by: job.requestedBy
						? `${job.requestedBy.username} (${job.requestedBy.publicId})`
						: "-",
					id: job.id,
				})),
			)
			console.log(
				"\nfull logs: admin panel -> Channels, or journalctl -u glukvpn-deploy-worker",
			)
			return
		}

		/* ---------------- devices ---------------- */
		case "devices:list": {
			const username = typeof flags.user === "string" ? flags.user : null
			const where = username ? { user: { username } } : {}
			const devices = await prisma.device.findMany({
				where,
				include: { user: { select: { username: true } } },
				orderBy: { createdAt: "desc" },
			})
			table(
				devices.map((device) => ({
					id: device.id,
					name: device.deviceName,
					user: device.user.username,
					platform: device.platform ?? "-",
					status: device.status,
					lastSeen: device.lastSeen ? device.lastSeen.toISOString() : "never",
				})),
			)
			return
		}

		case "devices:revoke": {
			const deviceId = positional[1]
			if (!deviceId) throw new Error("usage: devices:revoke <deviceId>")
			const device = await prisma.device.findUnique({ where: { id: deviceId } })
			if (!device) throw new Error("Device not found")
			const closed = await closeSessionsForDevice(device.id, "admin_revoked")
			await prisma.device.update({
				where: { id: device.id },
				data: { status: "REVOKED", revokedAt: new Date() },
			})
			const revoked = await revokeRefreshTokens({
				userId: device.userId,
				deviceId: device.id,
			})
			console.log(
				`device ${device.deviceName} revoked. sessions closed: ${closed}, tokens revoked: ${revoked}`,
			)
			return
		}

		/* ---------------- nodes ---------------- */
		case "nodes:list": {
			const nodes = await prisma.vpnNode.findMany({ orderBy: { name: "asc" } })
			const rows = []
			for (const node of nodes) {
				const live = await prisma.session.count({
					where: { nodeId: node.id, status: { in: ["PENDING", "ACTIVE"] } },
				})
				const traffic = await prisma.session.aggregate({
					where: { nodeId: node.id },
					_sum: { bytesRx: true, bytesTx: true },
				})
				rows.push({
					name: node.name,
					country: node.countryCode,
					status: effectiveNodeStatus(node),
					stored: node.status,
					endpoint: nodeEndpoint(node),
					load: `${nodeLoadPercent(node)}%`,
					peers: `${node.activePeers}/${node.capacity}`,
					sessions: live,
					rx: bytes(bytesToNumber(traffic._sum.bytesRx)),
					tx: bytes(bytesToNumber(traffic._sum.bytesTx)),
					heartbeat: node.lastHeartbeat ? node.lastHeartbeat.toISOString() : "never",
				})
			}
			table(rows)
			return
		}

		case "nodes:token": {
			const rawToken = generateSecret(32)
			const expiresAt = new Date(
				Date.now() + config.NODE_ENROLLMENT_TOKEN_TTL_MIN * 60 * 1000,
			)
			await prisma.nodeEnrollmentToken.create({
				data: {
					tokenHash: hashSecret(rawToken),
					note: typeof flags.note === "string" ? flags.note : "cli",
					expiresAt,
				},
			})
			console.log("one-time node enrollment token (store it on the node, not here):")
			console.log(rawToken)
			console.log(`valid until: ${expiresAt.toISOString()}`)
			return
		}

		case "nodes:disable": {
			const node = await findNode(positional[1] ?? "")
			const closed = await closeSessionsForNode(node.id, "node_disabled")
			await prisma.vpnNode.update({ where: { id: node.id }, data: { status: "DISABLED" } })
			console.log(`node ${node.name} disabled. sessions closed: ${closed}`)
			return
		}

		case "nodes:enable": {
			const node = await findNode(positional[1] ?? "")
			await prisma.vpnNode.update({
				where: { id: node.id },
				data: { status: node.lastHeartbeat ? "OFFLINE" : "PENDING" },
			})
			await ensureIpPool(node)
			console.log(`node ${node.name} enabled (waiting for heartbeat)`)
			return
		}

		case "nodes:delete": {
			const node = await findNode(positional[1] ?? "")
			const live = await prisma.session.count({
				where: { nodeId: node.id, status: { in: ["PENDING", "ACTIVE"] } },
			})
			if (live > 0) {
				throw new Error(
					`node ${node.name} still has ${live} live session(s); run nodes:disable first`,
				)
			}
			await prisma.vpnNode.delete({ where: { id: node.id } })
			console.log(`node ${node.name} deleted from the registry`)
			return
		}

		case "nodes:revoke-tokens": {
			const node = await findNode(positional[1] ?? "")
			const result = await prisma.nodeToken.updateMany({
				where: { nodeId: node.id, revokedAt: null },
				data: { revokedAt: new Date() },
			})
			console.log(
				`revoked ${result.count} token(s) for ${node.name}. The agent must enroll again.`,
			)
			return
		}

		/* ---------------- sessions ---------------- */
		case "sessions:list": {
			const sessions = await prisma.session.findMany({
				where: flags.live === true ? { status: { in: ["PENDING", "ACTIVE"] } } : undefined,
				include: {
					user: { select: { username: true } },
					device: { select: { deviceName: true } },
					node: { select: { name: true } },
				},
				orderBy: { connectedAt: "desc" },
				take: 50,
			})
			table(
				sessions.map((session) => ({
					id: session.id,
					user: session.user.username,
					device: session.device.deviceName,
					node: session.node.name,
					ip: session.assignedVpnIp,
					status: session.status,
					rx: bytes(bytesToNumber(session.bytesRx)),
					tx: bytes(bytesToNumber(session.bytesTx)),
					connected: session.connectedAt.toISOString(),
					closed: session.disconnectedAt ? session.disconnectedAt.toISOString() : "-",
					reason: session.closeReason ?? "-",
				})),
			)
			return
		}

		case "sessions:close": {
			const sessionId = positional[1]
			if (!sessionId) throw new Error("usage: sessions:close <sessionId>")
			const closed = await closeSession({ sessionId, reason: "admin_closed" })
			if (!closed) throw new Error("Session not found")
			console.log(`session ${sessionId} closed; REMOVE_PEER queued for the node`)
			return
		}

		/* ---------------- misc ---------------- */
		case "audit:tail": {
			const limit = Number(flags.limit ?? 30)
			const logs = await prisma.auditLog.findMany({
				orderBy: { createdAt: "desc" },
				take: Math.min(Math.max(limit, 1), 200),
				include: { user: { select: { username: true } } },
			})
			table(
				logs.map((log) => ({
					time: log.createdAt.toISOString(),
					action: log.action,
					user: log.user?.username ?? "-",
					ip: log.ip ?? "-",
					metadata: log.metadata ? JSON.stringify(log.metadata) : "-",
				})),
			)
			return
		}

		case "monitor:tick": {
			const result = await runMonitorTick()
			console.log(JSON.stringify(result, null, 2))
			return
		}

		default:
			console.error(`Unknown command: ${command}\n`)
			console.log(HELP)
			process.exitCode = 1
	}
}

main()
	.then(async () => {
		await disconnectPrisma()
	})
	.catch(async (error) => {
		console.error(`error: ${error instanceof Error ? error.message : "unknown error"}`)
		await disconnectPrisma()
		process.exit(1)
	})
