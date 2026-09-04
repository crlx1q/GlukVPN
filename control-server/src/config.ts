import { readFileSync, realpathSync } from "node:fs"
import path from "node:path"
import * as dotenv from "dotenv"
import { z } from "zod"

// Load .env from the process working directory (or ENV_FILE override).
// On the server this is /opt/vpn-control/.env (chmod 600).
dotenv.config({ path: process.env.ENV_FILE ?? ".env" })

/**
 * Env vars are strings, so `z.coerce.boolean()` would treat "false" as true.
 * Accept only explicit values instead.
 */
const envFlag = (fallback: "true" | "false" = "false") =>
	z
		.enum(["true", "false", "1", "0"])
		.default(fallback)
		.transform((value) => value === "true" || value === "1")

/**
 * Default approximate-origin lookup endpoint. Assembled from parts so the
 * literal is never rewritten by link tooling. `{ip}` is the only placeholder.
 */


const GEOIP_SCHEME = "https"
const GEOIP_HOST = "ipapi.co"
/** `{ip}` is the only placeholder. Assembled from parts on purpose. */
const DEFAULT_GEOIP_URL = `${GEOIP_SCHEME}://${GEOIP_HOST}/{ip}/json/`

const EnvSchema = z.object({
	NODE_ENV: z
		.enum(["development", "test", "production"])
		.default("development"),
	HOST: z.string().min(1).default("127.0.0.1"),
	PORT: z.coerce.number().int().min(1).max(65535).default(8081),
	LOG_LEVEL: z
		.enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
		.default("info"),
	PUBLIC_API_URL: z.string().url().default("http://127.0.0.1:8081"),

	// --------------------------- release channel -----------------------------
	// Two isolated stacks live on one machine: prod (:8081) and beta (:8082).
	// Each has its own database, its own env file and — importantly — its own
	// JWT_SECRET, so a beta token is cryptographically invalid in prod.
	CHANNEL: z.enum(["prod", "beta"]).default("prod"),
	// Filled from package.json when left empty; the deploy worker overrides it.
	APP_VERSION: z.string().default(""),
	GIT_COMMIT: z.string().default(""),
	RELEASED_AT: z.string().default(""),

	DATABASE_URL: z.string().min(1, "DATABASE_URL is required"),

	// Secrets. Length is validated, values are never logged.
	JWT_SECRET: z.string().min(32, "JWT_SECRET must be at least 32 chars"),
	TOKEN_HASH_PEPPER: z
		.string()
		.min(32, "TOKEN_HASH_PEPPER must be at least 32 chars"),

	ACCESS_TOKEN_TTL_SEC: z.coerce.number().int().min(60).max(86400).default(3600),
	REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().min(1).max(365).default(14),

	NODE_TOKEN_TTL_DAYS: z.coerce.number().int().min(1).max(365).default(30),
	NODE_ENROLLMENT_TOKEN_TTL_MIN: z.coerce
		.number()
		.int()
		.min(1)
		.max(1440)
		.default(30),
	NODE_HEARTBEAT_INTERVAL_SEC: z.coerce.number().int().min(5).max(300).default(10),
	NODE_OFFLINE_AFTER_SEC: z.coerce.number().int().min(15).max(900).default(30),

	// ROUND 24: the sing-box VLESS gateway handed to desktop clients, printed
	// by node-agent/deploy/install-singbox.sh. An empty VLESS_UUID means "no
	// gateway", and every client keeps using WireGuard, so filling these in is
	// what actually switches the fleet over.
	//
	// ROUND 26: these are now the *fallback* only. Each node reports its own
	// gateway (host / port / SNI / flow) in the heartbeat and each device owns
	// a personal `vless_uuid`, so a fleet with two nodes no longer shares one
	// credential. VLESS_UUID keeps working for devices that predate the column
	// and is provisioned on every node as the legacy "gluk" user while
	// VLESS_LEGACY_USER_ENABLED is true.
	VLESS_UUID: z.string().default(""),
	VLESS_PORT: z.coerce.number().int().min(1).max(65535).default(443),
	// Defaults to the node's own hostname, which is the name its certificate is
	// issued for. Override only when the TLS name differs from the hostname.
	VLESS_HOST: z.string().default(""),
	VLESS_SNI: z.string().default(""),
	VLESS_FLOW: z.string().default("xtls-rprx-vision"),
	VLESS_LEGACY_USER_ENABLED: envFlag("true"),

	// ------------------------- traffic attribution ---------------------------
	// The node agent reads sing-box's sniffer (SNI / HTTP host / QUIC) and sends
	// per-device domain totals. Only the host name and byte counters are kept -
	// never a URL, never a payload - and rows older than the retention are
	// purged by the monitor. Off = the agent still sends bytes, domains are
	// dropped on arrival.
	DOMAIN_STATS_ENABLED: envFlag("true"),
	DOMAIN_STATS_RETENTION_DAYS: z.coerce.number().int().min(1).max(365).default(30),

	// ------------------------------- Google ----------------------------------
	// "Continue with Google" on the website. The site takes the client id from
	// /api/auth/config, so this is the only place it lives. Empty = the button
	// is hidden. Client ID only - Google Identity Services returns a signed ID
	// token to the browser, and this server verifies it against Google's JWKS,
	// so no client secret is ever needed.
	GOOGLE_CLIENT_ID: z.string().default(""),
	// A brand-new Google account still has to pass the Telegram contact step
	// (one human = one account). Set to false to create the account instantly.
	GOOGLE_REQUIRE_TELEGRAM: envFlag("true"),

	// ------------------------------ billing ----------------------------------
	// Payment gateway adapter: "" (billing hidden), "manual" (orders are
	// created, an admin marks them paid), "stripe" (Checkout + webhook).
	BILLING_PROVIDER: z.enum(["", "manual", "stripe"]).default(""),
	BILLING_CURRENCY: z.string().min(3).max(3).default("KZT"),
	// Where the gateway sends the browser afterwards. Defaults derive from
	// SITE_BASE_URL when empty.
	BILLING_SUCCESS_URL: z.string().default(""),
	BILLING_CANCEL_URL: z.string().default(""),
	// Shown to the user after a "manual" order is created. {orderId} and
	// {amount} are substituted.
	BILLING_MANUAL_INSTRUCTIONS: z
		.string()
		.default(
			"Заказ {orderId} на {amount} создан. Напишите в поддержку @glukvpn, укажите номер заказа — после оплаты подписка активируется вручную.",
		),
	// !! SECRETS !! Stripe only.
	STRIPE_SECRET_KEY: z.string().default(""),
	STRIPE_WEBHOOK_SECRET: z.string().default(""),

	MAX_DEVICES_PER_USER: z.coerce.number().int().min(1).max(100).default(3),
	MAX_CONCURRENT_SESSIONS: z.coerce.number().int().min(1).max(50).default(1),
	LOGIN_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(100).default(5),
	LOGIN_LOCKOUT_MINUTES: z.coerce.number().int().min(1).max(1440).default(15),
	RATE_LIMIT_MAX: z.coerce.number().int().min(10).max(10000).default(120),
	RATE_LIMIT_WINDOW: z.string().min(1).default("1 minute"),

	// ------------------------------ identity ---------------------------------
	// Email is a second login identity and the first step of sign-up. Delivery
	// is live: services/mailer.ts speaks SMTP straight to Zoho over implicit TLS
	// on 465. The defaults describe the real mailbox so a fresh .env works out
	// of the box; SMTP_PASSWORD is the one value that must come from the file,
	// because a password with a default is a password in the git history.
	SMTP_HOST: z.string().default("smtp.zoho.com"),
	SMTP_PORT: z.coerce.number().int().min(1).max(65535).default(465),
	SMTP_USER: z.string().default("noreply@gluk.tech"),
	SMTP_PASSWORD: z.string().default(""),
	SMTP_FROM: z.string().default("GlukVPN <noreply@gluk.tech>"),
	SMTP_SECURE: envFlag("true"),
	// Five minutes for every code, everywhere.
	//
	// Long enough to switch to a mail app and back, short enough that an
	// intercepted code is worthless by the time anyone tries it - and short
	// enough that pending codes and sign-in links do not accumulate in memory
	// or in the table waiting for a sweeper to notice them.
	VERIFICATION_CODE_TTL_MIN: z.coerce.number().int().min(1).max(120).default(5),
	VERIFICATION_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(20).default(5),
	// Sign-up is self-service now: email + 6-digit code + Telegram contact.
	SELF_REGISTRATION_ENABLED: envFlag("true"),

	// ------------------------------ Telegram ---------------------------------
	// The bot is the second half of sign-up: it collects a phone number through
	// Telegram's own "share contact" button, which is what actually makes one
	// human one account. An empty token means the bot never starts and the
	// sign-up routes say so plainly, rather than leaving the user on a step
	// that can never complete.
	TELEGRAM_BOT_TOKEN: z.string().default(""),
	// Without the leading @. Left empty, it is resolved once through getMe.
	TELEGRAM_BOT_USERNAME: z.string().default(""),
	// Run the long-polling loop inside the API process. Turn it off to run
	// `npm run bot` as its own unit, so a deploy restart does not drop the bot.
	TELEGRAM_BOT_IN_PROCESS: envFlag("true"),

	// ------------------------------- captcha ---------------------------------
	// Cloudflare Turnstile guards sign-up and password reset: both are cheap for
	// us and expensive to abuse in bulk, which is exactly the shape of problem a
	// captcha solves. With no secret configured verification is skipped, so a
	// dev checkout is never blocked by a widget it cannot render.
	TURNSTILE_SECRET_KEY: z.string().default(""),
	TURNSTILE_ENABLED: envFlag("true"),

	// Where the browser is sent for link sign-in and sign-up confirmation.
	SITE_BASE_URL: z.string().default("https://vpn.gluk.tech"),

	// -------------------------- approximate origin ---------------------------
	// Country/region of the login IP, used to place the map marker. Coarse by
	// design: no GPS, no coordinates, nothing more precise than a region name.
	GEOIP_ENABLED: envFlag("false"),
	GEOIP_URL_TEMPLATE: z.string().default(DEFAULT_GEOIP_URL),
	GEOIP_TIMEOUT_MS: z.coerce.number().int().min(200).max(10000).default(2500),

	CORS_ALLOWED_ORIGINS: z.string().default(""),
	TRUST_PROXY: z.string().default("127.0.0.1"),

	SEED_ADMIN_USERNAME: z.string().min(3).default("admin"),
	SEED_ADMIN_PASSWORD: z.string().optional(),
	SEED_TEST_USERNAME: z.string().min(3).default("testuser"),
	SEED_TEST_PASSWORD: z.string().optional(),
})

export type Config = z.infer<typeof EnvSchema> & {
	corsOrigins: string[]
	/** True once SMTP is configured. Until then codes are issued but not sent. */
	emailEnabled: boolean
	/** True when GOOGLE_CLIENT_ID is set: the site shows "Continue with Google". */
	googleEnabled: boolean
	/** True when a billing provider is configured. */
	billingEnabled: boolean
	/**
	 * Which deployed release is answering, e.g. "20260821-174500".
	 *
	 * APP_VERSION comes from package.json, so promoting beta to prod copies the
	 * code without changing the number - which is why prod looked unchanged
	 * after a promote. This value is the release directory the process actually
	 * runs from, so it changes on every deploy and every promote.
	 */
	release: string
}

/** Version from package.json. Works from both dist/ and src/ (same parent). */
function packageVersion(): string {
	try {
		const pkg = require("../package.json") as { version?: string }
		return pkg.version ?? "0.0.0"
	} catch {
		return "0.0.0"
	}
}

/**
 * Resolve the running release id, in order of trustworthiness:
 *
 *   1. RELEASE_ID from the environment (the deploy scripts set it);
 *   2. release.json written next to the app root by the deploy scripts;
 *   3. the release directory the symlink resolves to - `current` is a symlink
 *      into releases/<id>, and realpath is what makes the id visible.
 *
 * Never throws: an unknown release must not stop the API from starting.
 */
function releaseId(): string {
	const explicit = (process.env.RELEASE_ID ?? "").trim()
	if (explicit) return explicit.slice(0, 64)

	const appRoot = path.join(__dirname, "..")
	try {
		const raw = readFileSync(path.join(appRoot, "release.json"), "utf8")
		const parsed = JSON.parse(raw) as { release?: unknown; id?: unknown }
		const fromFile = String(parsed.release ?? parsed.id ?? "").trim()
		if (fromFile) return fromFile.slice(0, 64)
	} catch {
		// No release.json: a dev checkout, or a build that predates this field.
	}

	try {
		// /opt/vpn-control/current/dist -> /opt/vpn-control/releases/20260821-174500
		const real = realpathSync(appRoot)
		const base = path.basename(real)
		if (/^\d{8}-\d{6}$/.test(base)) return base
		const parent = path.basename(path.dirname(real))
		if (/^\d{8}-\d{6}$/.test(parent)) return parent
		return base || "local"
	} catch {
		return "local"
	}
}

function loadConfig(): Config {
	const parsed = EnvSchema.safeParse(process.env)
	if (!parsed.success) {
		// Print only key names and reasons — never the values.
		const issues = parsed.error.issues
			.map((issue) => `  - ${issue.path.join(".")}: ${issue.message}`)
			.join("\n")
		throw new Error(`Invalid environment configuration:\n${issues}`)
	}
	const env = parsed.data
	return {
		...env,
		APP_VERSION: env.APP_VERSION.trim() || packageVersion(),
		release: releaseId(),
		// A host and a From line are not enough to send anything: without
		// credentials Zoho refuses at AUTH, and a flow that issues codes nobody
		// can receive looks exactly like a broken login.
		emailEnabled:
			env.SMTP_HOST.trim().length > 0 &&
			env.SMTP_USER.trim().length > 0 &&
			env.SMTP_PASSWORD.length > 0,
		googleEnabled: env.GOOGLE_CLIENT_ID.trim().length > 0,
		billingEnabled:
			env.BILLING_PROVIDER === "manual" ||
			(env.BILLING_PROVIDER === "stripe" && env.STRIPE_SECRET_KEY.trim().length > 0),
		corsOrigins: env.CORS_ALLOWED_ORIGINS.split(",")
			.map((origin) => origin.trim())
			.filter((origin) => origin.length > 0),
	}
}

export const config: Config = loadConfig()
