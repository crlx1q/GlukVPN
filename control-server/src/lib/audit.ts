import { prisma } from "../prisma"

export type AuditInput = {
	action: string
	userId?: string | null
	deviceId?: string | null
	nodeId?: string | null
	ip?: string | null
	metadata?: Record<string, unknown>
}

// Any key containing one of these substrings is redacted before it can reach
// the audit table or the logs.
const SENSITIVE_KEY_PARTS = [
	"token",
	"secret",
	"password",
	"privatekey",
	"private_key",
	"authorization",
	"pepper",
	"jwt",
]

function isSensitiveKey(key: string): boolean {
	const normalized = key.toLowerCase()
	return SENSITIVE_KEY_PARTS.some((part) => normalized.includes(part))
}

/** Recursively replaces sensitive values with "[redacted]". */
export function scrub(value: unknown, depth = 0): unknown {
	if (depth > 4) return "[truncated]"
	if (Array.isArray(value)) return value.map((item) => scrub(item, depth + 1))
	if (value && typeof value === "object") {
		const result: Record<string, unknown> = {}
		for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
			result[key] = isSensitiveKey(key) ? "[redacted]" : scrub(item, depth + 1)
		}
		return result
	}
	return value
}

/**
 * Writes an audit entry. Never throws: auditing must not break a request.
 */
export async function writeAudit(input: AuditInput): Promise<void> {
	try {
		await prisma.auditLog.create({
			data: {
				action: input.action,
				userId: input.userId ?? null,
				deviceId: input.deviceId ?? null,
				nodeId: input.nodeId ?? null,
				ip: input.ip ?? null,
				metadata: input.metadata
					? (scrub(input.metadata) as object)
					: undefined,
			},
		})
	} catch (error) {
		// eslint-disable-next-line no-console
		console.error(
			`audit_write_failed action=${input.action} error=${
				error instanceof Error ? error.message : "unknown"
			}`,
		)
	}
}
