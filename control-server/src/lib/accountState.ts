/**
 * Single source of truth for "this account may not be used".
 *
 * Three statuses refuse service — DISABLED (switched off), BLOCKED (banned for
 * abuse) and DELETED (tombstone of a deleted account) — and every client has
 * to word them differently. Wording belongs to the client, so what the API
 * owes it is a stable machine code; that mapping lives here and nowhere else,
 * so the next status cannot be refused with the wrong text in five places.
 *
 * Unknown statuses fail closed: anything that is not ACTIVE is refused.
 */
import { forbiddenWithCode, type HttpError } from "./errors"

/** Anything carrying a status column: a full `User` row or a partial select. */
export type AccountStatusHolder = { status: string }

export const ACCOUNT_DISABLED_CODE = "account_disabled"
export const ACCOUNT_BLOCKED_CODE = "account_blocked"
export const ACCOUNT_DELETED_CODE = "account_deleted"

/** Machine-readable reason a client can localise. */
export function accountRefusalCode(status: string): string {
	if (status === "BLOCKED") return ACCOUNT_BLOCKED_CODE
	if (status === "DELETED") return ACCOUNT_DELETED_CODE
	return ACCOUNT_DISABLED_CODE
}

/** English fallback text, for logs and for clients without a translation. */
export function accountRefusedMessage(status: string): string {
	if (status === "BLOCKED") return "This account has been blocked. Contact support."
	if (status === "DELETED") return "This account has been deleted."
	return "User is disabled"
}

/** The 403 every status check throws. */
export function accountRefusedError(status: string): HttpError {
	return forbiddenWithCode(accountRefusalCode(status), accountRefusedMessage(status))
}

/** Narrows away null/undefined as well, so callers keep their type info. */
export function isAccountActive<T extends AccountStatusHolder>(
	user: T | null | undefined,
): user is T {
	return !!user && user.status === "ACTIVE"
}

/**
 * Why a live tunnel is being closed. `user_disabled` keeps its historical
 * value because phone, desktop and extension already branch on it; the two
 * other statuses get their own reasons so a banned or deleted account is not
 * reported to its owner as "temporarily switched off".
 */
export function accountSessionCloseReason(status: string): string {
	if (status === "BLOCKED") return "user_blocked"
	if (status === "DELETED") return "user_deleted"
	return "user_disabled"
}
