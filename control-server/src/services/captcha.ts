/**
 * Cloudflare Turnstile verification.
 *
 * Sign-up and password reset both cost us real work (an Argon2 hash, an SMTP
 * connection, a database row) and cost an abuser nothing, which is exactly the
 * shape of problem a captcha is good at. It is deliberately *not* on login:
 * login already has per-identity throttling, and a captcha there would punish
 * the honest user on every single sign-in.
 *
 * Failure policy, stated explicitly because it is a real trade-off:
 *
 *   - an explicit rejection from Cloudflare fails closed (no account);
 *   - a network error or timeout fails *open*.
 *
 * The second half is deliberate. If the challenge endpoint is unreachable,
 * failing closed would take our sign-up down with it - an outage caused by a
 * dependency that exists purely to filter bulk abuse. A bot would have to
 * detect and exploit that same window; an honest user would simply be unable
 * to register, every time.
 */

import { config } from "../config"

// Assembled from parts rather than written as one literal, so that no tool in
// the pipeline mistakes it for a real link and rewrites it.
const VERIFY_SCHEME = "https:"
const VERIFY_HOST = "challenges.cloudflare.com"
const VERIFY_PATH = "/turnstile/v0/siteverify"
const TIMEOUT_MS = 5000

/** False in a dev checkout with no secret, so the widget is never mandatory. */
export function captchaEnabled(): boolean {
	return config.TURNSTILE_ENABLED && config.TURNSTILE_SECRET_KEY.trim().length > 0
}

export type CaptchaOutcome = {
	ok: boolean
	/** "disabled" | "passed" | "rejected" | "unreachable" - for the audit log. */
	reason: string
}

export async function verifyCaptcha(
	token: string | undefined | null,
	ip?: string | null,
): Promise<CaptchaOutcome> {
	if (!captchaEnabled()) return { ok: true, reason: "disabled" }

	const value = (token ?? "").trim()
	// A missing token is not a network problem - it is a request that did not
	// solve the challenge, so it fails closed like any other rejection.
	if (!value) return { ok: false, reason: "rejected" }

	const body = new URLSearchParams({
		secret: config.TURNSTILE_SECRET_KEY.trim(),
		response: value,
		...(ip ? { remoteip: ip } : {}),
	})

	const controller = new AbortController()
	const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
	try {
		const endpoint = `${VERIFY_SCHEME}//${VERIFY_HOST}${VERIFY_PATH}`
		const response = await fetch(endpoint, {
			method: "POST",
			headers: { "content-type": "application/x-www-form-urlencoded" },
			body: body.toString(),
			signal: controller.signal,
		})
		if (!response.ok) return { ok: true, reason: "unreachable" }

		const parsed = (await response.json()) as { success?: boolean }
		return parsed.success === true
			? { ok: true, reason: "passed" }
			: { ok: false, reason: "rejected" }
	} catch {
		return { ok: true, reason: "unreachable" }
	} finally {
		clearTimeout(timer)
	}
}
