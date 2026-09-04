import type { FastifyInstance, FastifyRequest } from "fastify"
import { z } from "zod"
import { config } from "../config"
import { badRequest } from "../lib/errors"
import { clientIp } from "../middleware/auth"
import { recordClientError } from "../services/telemetry"
import type { AccessTokenPayload } from "../types"

/**
 * Crash reporting intake.
 *
 * Unauthenticated by design. A client that cannot sign in, cannot refresh its
 * token or crashes on the login screen is exactly the client whose error we
 * most want to see, and requiring a token would filter those out. What keeps
 * it safe is everything around it: a tight rate limit, a schema, a scrubber
 * that strips credentials, hard length caps and a per-address ceiling.
 */

const ErrorBody = z.object({
	platform: z.enum(["windows", "android", "extension", "web"]),
	appVersion: z.string().min(1).max(200),
	errorName: z.string().min(1).max(400),
	errorMessage: z.string().min(1).max(4000),
	stackTrace: z.string().max(20000).nullish(),
	context: z.string().max(2000).nullish(),
	// Only used when the report arrives without a token; a device-scoped token
	// always wins, because the body is client-controlled and the token is not.
	deviceId: z.string().max(200).nullish(),
})

/**
 * Best-effort identity. A valid access token names the account and device; an
 * expired or missing one simply means the report is anonymous. The database is
 * never touched here - telemetry must stay cheap enough to accept a flood.
 */
function identify(request: FastifyRequest): {
	userId: string | null
	deviceId: string | null
} {
	const header = request.headers.authorization
	if (typeof header !== "string") return { userId: null, deviceId: null }
	const [scheme, value] = header.split(" ")
	if (!scheme || !value || scheme.toLowerCase() !== "bearer") {
		return { userId: null, deviceId: null }
	}
	try {
		const payload = request.server.jwt.verify<AccessTokenPayload>(value.trim())
		if (payload.typ !== "access" || typeof payload.sub !== "string") {
			return { userId: null, deviceId: null }
		}
		return { userId: payload.sub, deviceId: payload.did ?? null }
	} catch {
		return { userId: null, deviceId: null }
	}
}

export async function telemetryRoutes(app: FastifyInstance): Promise<void> {
	app.post(
		"/api/telemetry/error",
		// A crashing app retries; a crash loop must not become a write loop.
		{ config: { rateLimit: { max: 30, timeWindow: "1 minute" } } },
		async (request, reply) => {
			const parsed = ErrorBody.safeParse(request.body ?? {})
			if (!parsed.success) {
				throw badRequest(
					"Invalid error report",
					parsed.error.issues.map((issue) => ({
						field: issue.path.join("."),
						message: issue.message,
					})),
				)
			}

			// The kill switch. Answering 202 rather than an error keeps a client
			// from retrying a report nobody wants to store.
			if (!config.CLIENT_TELEMETRY_ENABLED) {
				return reply.code(202).send({ ok: true, stored: false, disabled: true })
			}

			const identity = identify(request)
			const outcome = await recordClientError({
				platform: parsed.data.platform,
				appVersion: parsed.data.appVersion,
				errorName: parsed.data.errorName,
				errorMessage: parsed.data.errorMessage,
				stackTrace: parsed.data.stackTrace ?? null,
				context: parsed.data.context ?? null,
				deviceId: identity.deviceId ?? parsed.data.deviceId ?? null,
				userId: identity.userId,
				ip: clientIp(request),
			})

			// 202: accepted for processing. The client has nothing to do with the
			// answer either way, and must never treat it as a failure worth
			// reporting - that is how telemetry loops are born.
			return reply.code(202).send({
				ok: true,
				stored: outcome.stored,
				throttled: outcome.throttled,
			})
		},
	)
}
