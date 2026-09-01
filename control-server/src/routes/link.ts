import type { User } from "@prisma/client"
import type { FastifyInstance } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { writeAudit } from "../lib/audit"
import { badRequest, forbidden, notFound } from "../lib/errors"
import { clientIp, getAuthUser, requireUser } from "../middleware/auth"
import { prisma } from "../prisma"
import type { LinkTokenPayload } from "../services/linkAuth"
import {
	approveLink,
	denyLink,
	describeLink,
	normalizeCode,
	pollLink,
	startLink,
} from "../services/linkAuth"
import { setTelegramLoginBridge, telegramLoginLink } from "../services/telegramBot"
import { issueTokens } from "../services/tokens"

/**
 * Sign in by link: one flow for the desktop client, the extension and anything
 * else that cannot safely own a password field.
 *
 * Why this exists: "Sign in on the website" used to just open vpn.gluk.tech and
 * hope. The extension papered over it with its own storage bridge, and the
 * desktop client had no path at all - so the same account had three different
 * ways in, two of them improvised. This is the standard device-authorization
 * grant, and it is now the only mechanism all three clients use.
 *
 * The trust boundary that makes it safe: `userCode` travels in a URL and
 * identifies nothing but a request. Turning it into credentials requires a
 * signed-in session on the website, and collecting those credentials requires
 * `pollSecret`, which never leaves the process that started the flow.
 */

const StartBody = z.object({
	client: z.enum(["windows", "android", "extension", "web"]),
	// Shown to the user on the confirmation page: "ALISHER-PC", "Pixel 7", ...
	deviceName: z.string().trim().max(64).optional(),
})

const PollBody = z.object({
	requestId: z.string().trim().min(8).max(64),
	pollSecret: z.string().trim().min(20).max(128),
})

const CodeParams = z.object({
	code: z.string().trim().min(4).max(24),
})

/** Where the browser is sent. Kept out of `config` so no migration is needed. */
function siteBaseUrl(): string {
	const raw = process.env.SITE_BASE_URL ?? "https://vpn.gluk.tech"
	return raw.replace(/\/+$/, "")
}

/**
 * Builds the credentials that `approveLink` hands to the waiting client.
 *
 * ROUND 11: there are now two approvers - the website and the Telegram bot -
 * and a session minted by one has to be byte-for-byte the same shape as a
 * session minted by the other. One function is what guarantees that; two
 * copies would be a drift waiting to happen.
 *
 * Account-scoped, exactly like `/api/auth/login`: the client upgrades to
 * device-scoped tokens itself with `/api/devices/register`, so the device row
 * is created by the machine that will actually use it.
 */
async function mintLinkTokens(
	app: FastifyInstance,
	user: User,
): Promise<LinkTokenPayload> {
	const tokens = await issueTokens(app, user, null)
	const subscription = await prisma.subscription.findFirst({
		where: { userId: user.id },
		orderBy: { expiresAt: "desc" },
	})
	return {
		tokenType: "Bearer",
		accessToken: tokens.accessToken,
		expiresIn: tokens.accessTokenExpiresInSec,
		refreshToken: tokens.refreshToken,
		refreshTokenExpiresAt: tokens.refreshTokenExpiresAt.toISOString(),
		user: {
			id: user.id,
			publicId: user.publicId,
			username: user.username,
			email: user.email,
			emailVerified: user.emailVerifiedAt !== null,
			isAdmin: user.isAdmin,
			status: user.status,
			maxDevices: user.maxDevices,
			maxConcurrentSessions: user.maxSessions,
			origin: {
				country: user.lastCountry,
				countryCode: user.lastCountryCode,
				region: user.lastRegion,
			},
		},
		subscription: subscription
			? {
					status: subscription.status,
					expiresAt: subscription.expiresAt.toISOString(),
				}
			: null,
	}
}

export async function linkAuthRoutes(app: FastifyInstance): Promise<void> {
	// ROUND 11: let the Telegram bot approve a sign-in.
	//
	// Installed here because approving mints tokens and `issueTokens` needs
	// `app.jwt`, which only this scope has. The bot module holds nothing but the
	// callbacks, so running it standalone simply leaves the feature off instead
	// of half-working.
	//
	// The identity check is `telegramId`, not the code: a chat is only bound to
	// an account after that exact Telegram user shared their phone number at
	// sign-up. Somebody who intercepts a deep link therefore still cannot
	// approve it - they would have to be the linked account.
	setTelegramLoginBridge({
		describe: (userCode: string) => {
			const record = describeLink(userCode)
			if (!record) return null
			return {
				client: record.client,
				deviceName: record.deviceName,
				ip: record.ip,
				status: record.status,
			}
		},
		approve: async ({ userCode, telegramId }) => {
			const user = await prisma.user.findFirst({ where: { telegramId } })
			if (!user) return { ok: false, reason: "not_linked" }
			if (user.status !== "ACTIVE") return { ok: false, reason: "disabled" }

			const outcome = approveLink({
				userCode,
				userId: user.id,
				tokens: await mintLinkTokens(app, user),
			})
			if (!outcome.ok) return { ok: false, reason: outcome.reason }

			await writeAudit({
				action: "auth.link.approved",
				userId: user.id,
				ip: null,
				metadata: {
					via: "telegram",
					client: outcome.record.client,
					deviceName: outcome.record.deviceName,
				},
			})
			return { ok: true, username: user.username }
		},
		deny: (userCode: string) => ({ ok: denyLink(userCode).ok }),
	})

	// ------------------------------- client side ----------------------------

	app.post(
		"/api/auth/link/start",
		// A flow start is cheap but must not be a spam vector: the code space is
		// 30^8, and a tight limit keeps it that way in practice.
		{ config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = StartBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("client is required")

			const started = startLink({
				client: parsed.data.client,
				deviceName: parsed.data.deviceName ?? null,
				ip: clientIp(request),
				userAgent: request.headers["user-agent"] ?? null,
			})

			return reply.send({
				requestId: started.requestId,
				userCode: started.userCode,
				pollSecret: started.pollSecret,
				// The client only ever has to open this. The code is in the query so
				// the site can confirm without the user typing anything.
				//
				// `api` names the instance that owns this request. prod (:8081) and
				// beta (:8082) are separate processes with separate memory, so a
				// request started here can only be approved here - and the site
				// defaults to whichever channel its config says. Without this the
				// browser cheerfully asked the wrong server and the user got
				// "this sign-in link is unknown or has expired" for a link that was
				// seconds old. It is a channel name, not a URL: the site maps it
				// through its own allowlist so the parameter cannot point the page
				// at someone else's API.
				verifyUrl: `${siteBaseUrl()}/link?code=${encodeURIComponent(started.userCode)}&api=${config.CHANNEL}`,
				verifyUrlBase: `${siteBaseUrl()}/link`,
				// ROUND 11: the preferred route when the bot is configured. The
				// chat already proved this person's phone number at sign-up, so
				// confirming there is both stronger and one tap shorter than
				// sending them through a web login. Empty when there is no bot,
				// and the clients fall back to verifyUrl.
				telegramUrl: telegramLoginLink(started.userCode),
				apiChannel: config.CHANNEL,
				expiresAt: started.expiresAt.toISOString(),
				intervalSec: started.intervalSec,
			})
		},
	)

	app.post(
		"/api/auth/link/poll",
		// Polling is the hot path: every waiting client hits it every two seconds.
		{ config: { rateLimit: { max: 120, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = PollBody.safeParse(request.body)
			if (!parsed.success) throw badRequest("requestId and pollSecret are required")

			const outcome = pollLink(parsed.data)
			if (outcome.status === "approved") {
				return reply.send({ status: "approved", ...outcome.tokens })
			}
			// Everything else is a plain status. Deliberately 200: this is a state
			// query, not a failure, and clients should not treat it as an error.
			return reply.send(outcome)
		},
	)

	// -------------------------------- site side -----------------------------

	// What the confirmation page renders. Requires a signed-in user, so an
	// attacker holding only a code learns nothing.
	app.get(
		"/api/auth/link/:code",
		{ preHandler: requireUser, config: { rateLimit: { max: 60, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = CodeParams.safeParse(request.params)
			if (!parsed.success) throw badRequest("Invalid code")

			const record = describeLink(parsed.data.code)
			if (!record) throw notFound("This sign-in link is unknown or has expired")
			return reply.send({ request: record })
		},
	)

	app.post(
		"/api/auth/link/:code/approve",
		{ preHandler: requireUser, config: { rateLimit: { max: 20, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = CodeParams.safeParse(request.params)
			if (!parsed.success) throw badRequest("Invalid code")
			const { user } = getAuthUser(request)
			const ip = clientIp(request)

			if (user.status !== "ACTIVE") throw forbidden("User is disabled")

			const code = normalizeCode(parsed.data.code)
			const pending = describeLink(code)
			if (!pending) throw notFound("This sign-in link is unknown or has expired")

			const outcome = approveLink({
				userCode: code,
				userId: user.id,
				tokens: await mintLinkTokens(app, user),
			})

			if (!outcome.ok) {
				if (outcome.reason === "expired") {
					throw badRequest("This sign-in link has expired. Start again in the app.")
				}
				if (outcome.reason === "already") {
					throw badRequest("This sign-in link has already been used")
				}
				throw notFound("This sign-in link is unknown or has expired")
			}

			await writeAudit({
				action: "auth.link.approved",
				userId: user.id,
				ip,
				metadata: { client: pending.client, deviceName: pending.deviceName },
			})

			return reply.send({ ok: true, request: outcome.record })
		},
	)

	app.post(
		"/api/auth/link/:code/deny",
		{ preHandler: requireUser, config: { rateLimit: { max: 20, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = CodeParams.safeParse(request.params)
			if (!parsed.success) throw badRequest("Invalid code")
			const { user } = getAuthUser(request)

			const outcome = denyLink(parsed.data.code)
			if (!outcome.ok) throw notFound("This sign-in link is unknown or has expired")

			await writeAudit({
				action: "auth.link.denied",
				userId: user.id,
				ip: clientIp(request),
				metadata: { client: outcome.record.client },
			})
			return reply.send({ ok: true, request: outcome.record })
		},
	)
}
