import type { Device, User } from "@prisma/client"
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
			...(device ? { did: device.id } : {}),
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

/**
 * Single-use refresh token rotation.
 * Re-using an already rotated token is treated as theft: every active refresh
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

	if (existing.revokedAt) {
		await prisma.refreshToken.updateMany({
			where: { userId: existing.userId, revokedAt: null },
			data: { revokedAt: new Date() },
		})
		throw unauthorized("Refresh token already used")
	}
	if (existing.expiresAt.getTime() <= Date.now()) throw unauthorized("Refresh token expired")
	if (existing.user.status !== "ACTIVE") throw forbidden("User is disabled")
	if (existing.device && existing.device.status !== "ACTIVE") {
		throw forbidden("Device is revoked")
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
