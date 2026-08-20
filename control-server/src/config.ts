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

	ACCESS_TOKEN_TTL_SEC: z.coerce.number().int().min(60).max(86400).default(900),
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

	MAX_DEVICES_PER_USER: z.coerce.number().int().min(1).max(100).default(3),
	MAX_CONCURRENT_SESSIONS: z.coerce.number().int().min(1).max(50).default(1),
	LOGIN_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(100).default(5),
	LOGIN_LOCKOUT_MINUTES: z.coerce.number().int().min(1).max(1440).default(15),
	RATE_LIMIT_MAX: z.coerce.number().int().min(10).max(10000).default(120),
	RATE_LIMIT_WINDOW: z.string().min(1).default("1 minute"),

	// ------------------------------ identity ---------------------------------
	// Email is an optional second login identity. Delivery is not wired up yet:
	// codes are created and verified, but only mailed once SMTP is filled in.
	// Zoho Mail is the intended provider (smtp.zoho.eu:587, STARTTLS).
	SMTP_HOST: z.string().default(""),
	SMTP_PORT: z.coerce.number().int().min(1).max(65535).default(587),
	SMTP_USER: z.string().default(""),
	SMTP_PASSWORD: z.string().default(""),
	SMTP_FROM: z.string().default(""),
	SMTP_SECURE: envFlag("false"),
	VERIFICATION_CODE_TTL_MIN: z.coerce.number().int().min(1).max(120).default(15),
	VERIFICATION_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(20).default(5),
	// Self-service signup stays off until email verification is live.
	SELF_REGISTRATION_ENABLED: envFlag("false"),

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
		emailEnabled:
			env.SMTP_HOST.trim().length > 0 && env.SMTP_FROM.trim().length > 0,
		corsOrigins: env.CORS_ALLOWED_ORIGINS.split(",")
			.map((origin) => origin.trim())
			.filter((origin) => origin.length > 0),
	}
}

export const config: Config = loadConfig()
