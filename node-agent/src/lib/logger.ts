/**
 * Minimal structured logger.
 *
 * Anything that looks like a secret is redacted before it can reach the journal,
 * and WireGuard keys are shortened so that full keys never end up in logs.
 */
import { config } from "../config"

type Level = "debug" | "info" | "warn" | "error"

const LEVEL_ORDER: Record<Level, number> = {
	debug: 10,
	info: 20,
	warn: 30,
	error: 40,
}

const SECRET_KEY_PATTERN =
	/(token|secret|password|passwd|privatekey|private_key|authorization|credential)/i

/** Shortens a WireGuard public key for logs: "abcd1234…" */
export function shortKey(key: string | null | undefined): string {
	if (!key) return "-"
	return `${key.slice(0, 8)}\u2026`
}

function redactValue(key: string, value: unknown): unknown {
	if (SECRET_KEY_PATTERN.test(key)) return "[redacted]"
	if (typeof value === "string" && /^[A-Za-z0-9+/]{42}=$/.test(value)) {
		// Any raw WireGuard key: log a prefix only.
		return shortKey(value)
	}
	if (value && typeof value === "object" && !Array.isArray(value)) {
		return redactFields(value as Record<string, unknown>)
	}
	return value
}

function redactFields(fields: Record<string, unknown>): Record<string, unknown> {
	const output: Record<string, unknown> = {}
	for (const [key, value] of Object.entries(fields)) {
		output[key] = redactValue(key, value)
	}
	return output
}

function write(level: Level, message: string, fields?: Record<string, unknown>): void {
	if (LEVEL_ORDER[level] < LEVEL_ORDER[config.LOG_LEVEL]) return
	const payload = {
		time: new Date().toISOString(),
		level,
		node: config.NODE_NAME,
		msg: message,
		...(fields ? redactFields(fields) : {}),
	}
	const line = JSON.stringify(payload)
	if (level === "error" || level === "warn") console.error(line)
	else console.log(line)
}

export const log = {
	debug: (message: string, fields?: Record<string, unknown>) => write("debug", message, fields),
	info: (message: string, fields?: Record<string, unknown>) => write("info", message, fields),
	warn: (message: string, fields?: Record<string, unknown>) => write("warn", message, fields),
	error: (message: string, fields?: Record<string, unknown>) => write("error", message, fields),
}

/** Never leaks a stack trace containing tokens: message only. */
export function errorMessage(error: unknown): string {
	if (error instanceof Error) return error.message
	return typeof error === "string" ? error : "unknown error"
}
