import type { FastifyRequest } from "fastify"
import { hashSecret } from "../lib/crypto"
import { forbidden, unauthorized } from "../lib/errors"
import { prisma } from "../prisma"
import type { AccessTokenPayload, AuthNodeContext, AuthUserContext } from "../types"

function bearerToken(request: FastifyRequest): string | null {
	const header = request.headers.authorization
	if (typeof header !== "string") return null
	const [scheme, value] = header.split(" ")
	if (!scheme || !value || scheme.toLowerCase() !== "bearer") return null
	const trimmed = value.trim()
	return trimmed.length > 0 ? trimmed : null
}

export function clientIp(request: FastifyRequest): string {
	return request.ip ?? "unknown"
}

/**
 * Verifies a user/device access token.
 *
 * The database is consulted on every request on purpose: JWTs are stateless,
 * so revoking a device or disabling a user must be enforced here to take
 * effect immediately instead of after the token TTL.
 */
export async function requireUser(request: FastifyRequest): Promise<void> {
	const token = bearerToken(request)
	if (!token) throw unauthorized("Missing bearer token")

	let payload: AccessTokenPayload
	try {
		payload = request.server.jwt.verify<AccessTokenPayload>(token)
	} catch {
		throw unauthorized("Invalid or expired access token")
	}
	if (payload.typ !== "access" || typeof payload.sub !== "string") {
		throw unauthorized("Invalid token payload")
	}

	const user = await prisma.user.findUnique({ where: { id: payload.sub } })
	if (!user) throw unauthorized("Unknown user")
	if (user.status !== "ACTIVE") throw forbidden("User is disabled")

	let device = null
	if (payload.did) {
		device = await prisma.device.findUnique({ where: { id: payload.did } })
		if (!device || device.userId !== user.id) throw unauthorized("Unknown device")
		if (device.status !== "ACTIVE") throw forbidden("Device is revoked")
	}

	request.authUser = { user, device }
}

/** Requires a device-scoped token (issued by /api/devices/register). */
export async function requireDeviceScope(request: FastifyRequest): Promise<void> {
	await requireUser(request)
	if (!request.authUser?.device) {
		throw forbidden("This endpoint requires a device-scoped access token")
	}
}

export async function requireAdmin(request: FastifyRequest): Promise<void> {
	await requireUser(request)
	if (!request.authUser?.user.isAdmin) throw forbidden("Admin privileges required")
}

/**
 * Verifies a node credential: `Authorization: Bearer <node token>` plus
 * `X-Node-Id`. The raw token is never stored server-side; lookup happens by
 * HMAC hash, so no secret comparison is performed in application code.
 */
export async function requireNode(request: FastifyRequest): Promise<void> {
	const token = bearerToken(request)
	const nodeIdHeader = request.headers["x-node-id"]
	const nodeId = typeof nodeIdHeader === "string" ? nodeIdHeader.trim() : ""
	if (!token || !nodeId) throw unauthorized("Missing node credentials")

	const nodeToken = await prisma.nodeToken.findUnique({
		where: { tokenHash: hashSecret(token) },
		include: { node: true },
	})
	if (!nodeToken || nodeToken.nodeId !== nodeId) throw unauthorized("Unknown node credential")
	if (nodeToken.revokedAt) throw unauthorized("Node credential revoked")
	if (nodeToken.expiresAt.getTime() <= Date.now()) throw unauthorized("Node credential expired")
	if (nodeToken.node.status === "DISABLED") throw forbidden("Node is disabled")

	request.authNode = { node: nodeToken.node, tokenId: nodeToken.id }

	// Best-effort last-used bookkeeping; failures must not reject the request.
	void prisma.nodeToken
		.update({ where: { id: nodeToken.id }, data: { lastUsedAt: new Date() } })
		.catch(() => undefined)
}

export function getAuthUser(request: FastifyRequest): AuthUserContext {
	if (!request.authUser) throw unauthorized("Not authenticated")
	return request.authUser
}

export function getAuthNode(request: FastifyRequest): AuthNodeContext {
	if (!request.authNode) throw unauthorized("Node not authenticated")
	return request.authNode
}
