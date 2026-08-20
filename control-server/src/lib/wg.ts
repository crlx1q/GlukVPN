import { z } from "zod"

// A WireGuard key is 32 raw bytes, base64-encoded => 43 chars + "=".
const WG_KEY_PATTERN = /^[A-Za-z0-9+/]{43}=$/

export function isValidWireGuardKey(key: unknown): key is string {
	if (typeof key !== "string" || !WG_KEY_PATTERN.test(key)) return false
	return Buffer.from(key, "base64").length === 32
}

export const wireGuardKeySchema = z
	.string()
	.refine(isValidWireGuardKey, "Must be a base64-encoded 32-byte WireGuard key")

/**
 * Guard against a client submitting the node's own public key (or an empty key)
 * as its device key.
 */
export function assertDistinctKeys(clientKey: string, nodeKey: string | null): boolean {
	if (!nodeKey) return true
	return clientKey !== nodeKey
}
