/**
 * Idempotent seed for the test environment.
 *
 * Creates: one admin account, one test user with an active subscription and a
 * one-time node enrollment token. No production secrets are stored here and no
 * password is written to the database in clear text.
 *
 * Passwords come from the environment (SEED_ADMIN_PASSWORD / SEED_TEST_PASSWORD).
 * If they are empty, strong random passwords are generated and printed once.
 */
import { config } from "../config"
import { generatePassword, generateSecret, hashPassword, hashSecret } from "../lib/crypto"
import { disconnectPrisma, prisma } from "../prisma"
import { ensureIpPool } from "../services/sessions"

type SeededUser = {
	username: string
	password: string | null
	created: boolean
	isAdmin: boolean
}

async function upsertUser(options: {
	username: string
	password: string
	isAdmin: boolean
	subscriptionDays: number
}): Promise<SeededUser> {
	const existing = await prisma.user.findUnique({
		where: { username: options.username },
		include: { subscriptions: true },
	})

	if (existing) {
		// Never silently reset an existing password.
		if (existing.subscriptions.length === 0) {
			await prisma.subscription.create({
				data: {
					userId: existing.id,
					plan: "test",
					status: "ACTIVE",
					expiresAt: new Date(Date.now() + options.subscriptionDays * 86400_000),
				},
			})
		}
		return {
			username: existing.username,
			password: null,
			created: false,
			isAdmin: existing.isAdmin,
		}
	}

	await prisma.user.create({
		data: {
			username: options.username,
			passwordHash: await hashPassword(options.password),
			isAdmin: options.isAdmin,
			maxDevices: config.MAX_DEVICES_PER_USER,
			maxSessions: config.MAX_CONCURRENT_SESSIONS,
			subscriptions: {
				create: {
					plan: "test",
					status: "ACTIVE",
					expiresAt: new Date(Date.now() + options.subscriptionDays * 86400_000),
				},
			},
		},
	})

	return {
		username: options.username,
		password: options.password,
		created: true,
		isAdmin: options.isAdmin,
	}
}

async function main(): Promise<void> {
	const adminPassword = config.SEED_ADMIN_PASSWORD || generatePassword()
	const testPassword = config.SEED_TEST_PASSWORD || generatePassword()

	const admin = await upsertUser({
		username: config.SEED_ADMIN_USERNAME,
		password: adminPassword,
		isAdmin: true,
		subscriptionDays: 365,
	})
	const testUser = await upsertUser({
		username: config.SEED_TEST_USERNAME,
		password: testPassword,
		isAdmin: false,
		subscriptionDays: 365,
	})

	// Optional placeholder row for the first node. It stays PENDING (and is
	// therefore not connectable) until the agent registers and sends heartbeats,
	// so the app never advertises a node that does not exist yet.
	const nodeName = process.env.SEED_NODE_NAME || "de-01"
	const nodeCountry = process.env.SEED_NODE_COUNTRY || "Germany"
	const nodeCountryCode = (process.env.SEED_NODE_COUNTRY_CODE || "DE").toUpperCase()
	const nodePublicIp = process.env.SEED_NODE_PUBLIC_IP || ""
	let nodeInfo = "skipped (set SEED_NODE_PUBLIC_IP to pre-create a placeholder row)"

	if (nodePublicIp) {
		const existingNode = await prisma.vpnNode.findUnique({ where: { name: nodeName } })
		if (existingNode) {
			nodeInfo = `${nodeName} already exists (status ${existingNode.status})`
		} else {
			const node = await prisma.vpnNode.create({
				data: {
					name: nodeName,
					country: nodeCountry,
					countryCode: nodeCountryCode,
					hostname: process.env.SEED_NODE_HOSTNAME || nodePublicIp,
					publicIp: nodePublicIp,
					// The real key arrives with the agent's registration.
					wireguardPublicKey: null,
					status: "PENDING",
				},
			})
			await ensureIpPool(node)
			nodeInfo = `${nodeName} created with status PENDING`
		}
	}

	// One-time enrollment token so the node agent can authenticate itself once.
	const enrollmentToken = generateSecret(32)
	const enrollmentExpiresAt = new Date(
		Date.now() + config.NODE_ENROLLMENT_TOKEN_TTL_MIN * 60 * 1000,
	)
	await prisma.nodeEnrollmentToken.create({
		data: {
			tokenHash: hashSecret(enrollmentToken),
			note: `seed:${nodeName}`,
			expiresAt: enrollmentExpiresAt,
		},
	})

	const lines = [
		"",
		"==================== GlukVPN seed ====================",
		`admin user : ${admin.username} ${admin.created ? "(created)" : "(already existed, password unchanged)"}`,
		admin.created ? `admin pass : ${admin.password}` : "admin pass : <unchanged>",
		`test user  : ${testUser.username} ${testUser.created ? "(created)" : "(already existed, password unchanged)"}`,
		testUser.created ? `test pass  : ${testUser.password}` : "test pass  : <unchanged>",
		`node row   : ${nodeInfo}`,
		"",
		"Node enrollment token (valid until " + enrollmentExpiresAt.toISOString() + "):",
		enrollmentToken,
		"",
		"Put it into /etc/vpn-node-agent/agent.env as NODE_ENROLLMENT_TOKEN and run:",
		"  sudo -u vpnagent node dist/scripts/enroll.js",
		"",
		"These values are shown once and are NOT stored anywhere in clear text.",
		"======================================================",
		"",
	]
	console.log(lines.join("\n"))
}

main()
	.then(async () => {
		await disconnectPrisma()
		process.exit(0)
	})
	.catch(async (error) => {
		console.error(`seed_failed: ${error instanceof Error ? error.message : "unknown error"}`)
		await disconnectPrisma()
		process.exit(1)
	})
