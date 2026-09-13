/**
 * Account deletion, tombstone style.
 *
 * What is deleted and what survives
 * ---------------------------------
 * The `users` row itself is never dropped. It stays as a tombstone carrying
 * five things: the id, the public account number, `username`, `passwordHash`
 * and `status = DELETED` (plus when, why and by whom). Everything else about
 * the person - email, Telegram identity, approximate origin, devices, tunnels,
 * tokens, visited domains, traffic buckets, sign-in links - is erased in the
 * same call.
 *
 * Why the login credentials are kept:
 *
 *   `/api/auth/login` verifies the password *before* it looks at the status.
 *   Without the username and hash the owner of a deleted account would be told
 *   "invalid username or password" and would keep trying; with them the answer
 *   is `account_deleted`. The same property is what stops a stranger from
 *   probing which account names once existed - a wrong password never reaches
 *   the status check.
 *
 * Why the row is kept at all: the public account number must never be handed
 * to somebody else, audit entries have to keep pointing somewhere, and support
 * needs to be able to answer "what happened to 10758930".
 *
 * Financial history (orders, subscriptions, promo redemptions) is deliberately
 * left in place: after the wipe it holds no personal data, and it is the only
 * record of money that changed hands.
 */
import { accountSessionCloseReason } from "../lib/accountState"
import { notFound } from "../lib/errors"
import { prisma } from "../prisma"
import { requestPolicySync } from "./policy"
import { closeSessionsForUser } from "./sessions"

export type AccountDeletionResult = {
	userId: string
	publicId: string
	/** True when the account was already a tombstone: the call changed nothing. */
	alreadyDeleted: boolean
	closedSessions: number
	removedDevices: number
	revokedTokens: number
}

/**
 * Deletes an account and returns what it cost.
 *
 * Idempotent: deleting a tombstone is a no-op, so a double click in the admin
 * panel cannot produce an error or a second audit trail of destruction.
 *
 * @param actorId - the administrator who pressed delete, or null when the
 *   owner deleted their own account.
 */
export async function deleteAccount(params: {
	userId: string
	actorId?: string | null
	reason?: string | null
}): Promise<AccountDeletionResult> {
	const user = await prisma.user.findUnique({ where: { id: params.userId } })
	if (!user) throw notFound("User not found")
	if (user.status === "DELETED") {
		return {
			userId: user.id,
			publicId: user.publicId,
			alreadyDeleted: true,
			closedSessions: 0,
			removedDevices: 0,
			revokedTokens: 0,
		}
	}

	// Tunnels go down first, while the Device rows still exist: closing a
	// session is what queues REMOVE_PEER for the node, and a peer whose row
	// vanished first would stay installed on the gateway.
	const closedSessions = await closeSessionsForUser(
		user.id,
		accountSessionCloseReason("DELETED"),
	)

	// The tombstone is written in one statement, so there is no window in which
	// the account is half-deleted but still usable.
	await prisma.user.update({
		where: { id: user.id },
		data: {
			status: "DELETED",
			deletedAt: new Date(),
			deletedReason: params.reason?.trim() || null,
			deletedBy: params.actorId ?? null,
			// Contact identities: gone, and free for somebody else to register.
			email: null,
			emailVerifiedAt: null,
			telegramId: null,
			telegramUsername: null,
			telegramPhone: null,
			telegramVerifiedAt: null,
			telegramFirstName: null,
			telegramLastName: null,
			telegramPhotoId: null,
			telegramProfileSyncedAt: null,
			// Approximate origin from the last login IP.
			lastCountry: null,
			lastCountryCode: null,
			lastRegion: null,
			geoUpdatedAt: null,
			// Privileges and manual overrides must not survive on a dead row.
			isAdmin: false,
			isTester: false,
			isSupport: false,
			speedLimitMbps: null,
		},
	})

	// Credentials: revoke before deleting so the rotation chain is broken even
	// if the delete below is refused by a foreign key.
	const revoked = await prisma.refreshToken.updateMany({
		where: { userId: user.id },
		data: { revokedAt: new Date(), replacedById: null },
	})
	await prisma.refreshToken.deleteMany({ where: { userId: user.id } })

	// Devices are deleted, exactly as a sign-out does it: sessions, tokens and
	// per-domain statistics cascade off the row. If a foreign key outside this
	// call refuses, the rows are revoked and anonymised instead - the access is
	// dead either way, and the retention sweeper removes them later.
	let removedDevices = 0
	try {
		const wiped = await prisma.device.deleteMany({ where: { userId: user.id } })
		removedDevices = wiped.count
	} catch {
		const devices = await prisma.device.findMany({
			where: { userId: user.id },
			select: { id: true },
		})
		for (const device of devices) {
			await prisma.device.update({
				where: { id: device.id },
				data: {
					status: "REVOKED",
					revokedAt: new Date(),
					tokenVersion: { increment: 1 },
					vlessUuid: null,
					// The device name is what the person called their machine, and
					// the public key identifies it: neither may outlive the account.
					deviceName: "deleted device",
					platform: null,
					publicKey: `deleted:${device.id}`,
				},
			})
		}
		removedDevices = devices.length
	}

	// Everything else that described the person or let them back in.
	await prisma.identityLink.deleteMany({ where: { userId: user.id } })
	await prisma.verificationCode.deleteMany({ where: { userId: user.id } })
	await prisma.linkRequest.deleteMany({ where: { userId: user.id } })
	// Visited domains and per-device traffic buckets: the buckets carry the
	// device name, and neither hangs off Device with a cascade.
	await prisma.trafficDomainStat.deleteMany({ where: { userId: user.id } })
	await prisma.trafficUsageBucket.deleteMany({ where: { userId: user.id } })

	// The policy only ever contains devices of ACTIVE users, so this is what
	// pulls the VLESS credentials off every node.
	await requestPolicySync().catch(() => 0)

	return {
		userId: user.id,
		publicId: user.publicId,
		alreadyDeleted: false,
		closedSessions,
		removedDevices,
		revokedTokens: revoked.count,
	}
}
