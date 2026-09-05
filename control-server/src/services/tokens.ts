import type { Device, RefreshToken, User } from "@prisma/client"
import type { FastifyInstance } from "fastify"
import { config } from "../config"
import { generateSecret, hashSecret } from "../lib/crypto"
import { forbidden, unauthorized } from "../lib/errors"
import { prisma } from "../prisma"

export type IssuedTokens = {
	accessToken: string
	refreshToken: string
	refreshTokenId: string
	accessTokenExpiresInSec: number
	refreshTokenExpiresAt: Date
	deviceId: string | null
}

/**
 * Issues a short-lived access token plus a rotating refresh token.
 * When `device` is provided the pair is device-scoped: the access token carries
 * the device id and only that device can open VPN sessions with it.
 */
export async function issueTokens(
	app: FastifyInstance,
	user: User,
	device: Device | null,
): Promise<IssuedTokens> {
	const accessToken = app.jwt.sign(
		{
			sub: user.id,
			...(device ? { did: device.id, dv: device.tokenVersion ?? 0 } : {}),
			adm: user.isAdmin,
			typ: "access",
		},
		{ expiresIn: `${config.ACCESS_TOKEN_TTL_SEC}s` },
	)

	const rawRefreshToken = generateSecret(48)
	const refreshTokenExpiresAt = new Date(
		Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000,
	)
	const created = await prisma.refreshToken.create({
		data: {
			userId: user.id,
			deviceId: device?.id ?? null,
			deviceTokenVersion: device?.tokenVersion ?? null,
			// Only the HMAC hash is stored.
			tokenHash: hashSecret(rawRefreshToken),
			expiresAt: refreshTokenExpiresAt,
		},
		select: { id: true },
	})

	return {
		accessToken,
		refreshToken: rawRefreshToken,
		refreshTokenId: created.id,
		accessTokenExpiresInSec: config.ACCESS_TOKEN_TTL_SEC,
		refreshTokenExpiresAt,
		deviceId: device?.id ?? null,
	}
}

const ROTATION_GRACE_MS = 60_000

/**
 * Single-use refresh token rotation with a grace window for concurrent requests.
 * Re-using a token long after rotation is treated as theft: every active refresh
 * token of that user is revoked.
 */
export async function rotateRefreshToken(
	app: FastifyInstance,
	rawRefreshToken: string,
): Promise<IssuedTokens> {
	const existing = await prisma.refreshToken.findUnique({
		where: { tokenHash: hashSecret(rawRefreshToken) },
		include: { user: true, device: true },
	})
	if (!existing) throw unauthorized("Invalid refresh token")

	// Reject already-invalid device credentials before theft escalation: a signed-out
	// device must not be able to revoke every other device by replaying its old token.
	if (existing.expiresAt.getTime() <= Date.now()) throw unauthorized("Refresh token expired")
	if (existing.user.status !== "ACTIVE") throw forbidden("User is disabled")
	if (existing.device && (existing.deviceTokenVersion ?? 0) !== (existing.device.tokenVersion ?? 0)) throw unauthorized("Device credentials revoked")
	if (existing.device && existing.device.status !== "ACTIVE") throw forbidden("Device is revoked")

	if (existing.revokedAt) {
		// The grace window is only for rotation, never for explicit revocation.
		if (!existing.replacedById) throw unauthorized("Refresh token revoked")
		const isWithinGrace = (Date.now() - existing.revokedAt.getTime()) < ROTATION_GRACE_MS
		if (!isWithinGrace) {
			await prisma.refreshToken.updateMany({
				where: { userId: existing.userId, revokedAt: null },
				data: { revokedAt: new Date() },
			})
			throw unauthorized("Refresh token already used")
		}
		// A recently rotated token is usable only while a successor is still valid.
		// Explicit logout/revoke kills the leaf and cannot be bypassed via grace.
		let replacementId: string | null = existing.replacedById
		let activeSuccessor = false
		for (let depth = 0; depth < 16 && replacementId; depth++) {
			const next: RefreshToken | null = await prisma.refreshToken.findUnique({ where: { id: replacementId } })
			if (!next || next.userId !== existing.userId || next.deviceId !== existing.deviceId || next.expiresAt.getTime() <= Date.now()) break
			if (!next.revokedAt) { activeSuccessor = true; break }
			if (!next.replacedById || Date.now() - next.revokedAt.getTime() >= ROTATION_GRACE_MS) break
			replacementId = next.replacedById
		}
		if (!activeSuccessor) throw unauthorized("Refresh token revoked")
	}

	const issued = await issueTokens(app, existing.user, existing.device)
	await prisma.refreshToken.update({
		where: { id: existing.id },
		data: {
			revokedAt: new Date(),
			lastUsedAt: new Date(),
			replacedById: issued.refreshTokenId,
		},
	})
	return issued
}

export async function revokeRefreshTokens(params: {
	userId: string
	deviceId?: string | null
}): Promise<number> {
	const result = await prisma.refreshToken.updateMany({
		where: {
			userId: params.userId,
			...(params.deviceId === undefined ? {} : { deviceId: params.deviceId }),
			revokedAt: null,
		},
		data: { revokedAt: new Date() },
	})
	return result.count
}
