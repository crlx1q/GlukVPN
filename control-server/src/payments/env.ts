/**
 * Environment access for payment modules.
 *
 * A gateway folder reads its own variables through these helpers instead of
 * importing the central config: `config.ts` validates one fixed schema, and
 * keys belonging to a folder that may be deleted have no business being in
 * it. The value is read on every call, so nothing is cached from a boot that
 * happened before the operator filled the key in.
 */

/** A trimmed variable, or the fallback when it is missing or blank. */
export function envText(name: string, fallback = ""): string {
	const raw = process.env[name]
	return typeof raw === "string" && raw.trim() ? raw.trim() : fallback
}

/** An integer variable, clamped. Anything unparseable is the fallback. */
export function envInt(name: string, fallback: number, min: number, max: number): number {
	const parsed = Number.parseInt(envText(name), 10)
	if (!Number.isFinite(parsed)) return fallback
	return Math.min(max, Math.max(min, parsed))
}

/** Only explicit values count: "false" is false, not a non-empty string. */
export function envFlag(name: string, fallback = false): boolean {
	const raw = envText(name).toLowerCase()
	if (!raw) return fallback
	return raw === "true" || raw === "1" || raw === "yes" || raw === "on"
}
