import type { Device, User, VpnNode } from "@prisma/client"

export type AuthUserContext = {
	user: User
	/** Present only for device-scoped access tokens. */
	device: Device | null
}

export type AuthNodeContext = {
	node: VpnNode
	tokenId: string
}

export type AccessTokenPayload = {
	sub: string
	did?: string
	/** Device credential epoch; absent on legacy tokens (epoch zero). */
	dv?: number
	adm?: boolean
	typ: "access"
}

declare module "fastify" {
	interface FastifyRequest {
		authUser?: AuthUserContext
		authNode?: AuthNodeContext
	}
}
