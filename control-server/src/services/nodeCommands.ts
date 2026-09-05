import type { CommandType, NodeCommand, Prisma } from "@prisma/client"
import { prisma } from "../prisma"

/**
 * Command queue for node agents (pull model).
 *
 * The control server never opens a connection to a node: the agent polls over
 * HTTPS and executes only a fixed set of typed commands (ADD_PEER,
 * REMOVE_PEER, SYNC_PEERS). There is intentionally no generic "run shell
 * command" command type.
 */
export async function enqueueCommand(params: {
	nodeId: string
	type: CommandType
	payload: Prisma.InputJsonValue
	sessionId?: string | null
}): Promise<NodeCommand> {
	return prisma.nodeCommand.create({
		data: {
			nodeId: params.nodeId,
			type: params.type,
			payload: params.payload,
			sessionId: params.sessionId ?? null,
		},
	})
}

/** Marks the oldest pending commands as delivered and returns them. */
export async function claimPendingCommands(nodeId: string, limit = 10): Promise<NodeCommand[]> {
	const take = Math.min(Math.max(Math.trunc(limit), 1), 50)
	return prisma.$transaction(async (tx) => {
		await tx.nodeCommand.updateMany({
			where: { nodeId, type: "ADD_PEER", status: "PENDING", OR: [
				{ sessionId: null }, { session: { is: { status: { notIn: ["PENDING", "ACTIVE"] } } } },
			] },
			data: { status: "FAILED", completedAt: new Date(), result: { reason: "session_closed_before_delivery" } },
		})
		// Lock claims atomically: a stale candidate list must not resurrect a cancelled ADD.
		const pending = await tx.$queryRaw<Array<{ id: string }>>`
			SELECT id FROM node_commands WHERE node_id = ${nodeId}::uuid AND status = 'PENDING'
			ORDER BY created_at ASC, id ASC LIMIT ${take} FOR UPDATE SKIP LOCKED
		`
		if (!pending.length) return []
		const ids = pending.map((command) => command.id)
		await tx.nodeCommand.updateMany({
			where: { id: { in: ids }, status: "PENDING" },
			data: { status: "DELIVERED", deliveredAt: new Date(), attempts: { increment: 1 } },
		})
		return tx.nodeCommand.findMany({ where: { id: { in: ids }, status: "DELIVERED" }, orderBy: [{ createdAt: "asc" }, { id: "asc" }] })
	})
}

/** Acknowledgement from the agent. Scoped by nodeId so a node can only ack its own commands. */
export async function completeCommand(params: {
	commandId: string
	nodeId: string
	ok: boolean
	result?: Prisma.InputJsonValue
}): Promise<NodeCommand | null> {
	const command = await prisma.nodeCommand.findFirst({
		where: { id: params.commandId, nodeId: params.nodeId },
	})
	if (!command) return null
	if (command.status === "DONE" || command.status === "FAILED") return command

	return prisma.nodeCommand.update({
		where: { id: command.id },
		data: {
			status: params.ok ? "DONE" : "FAILED",
			completedAt: new Date(),
			...(params.result === undefined ? {} : { result: params.result }),
		},
	})
}

/**
 * Commands that were delivered but never acknowledged (agent restart, network
 * loss) go back to PENDING until the attempt budget is exhausted.
 */
export async function requeueStaleCommands(
	staleAfterSec: number,
	maxAttempts = 5,
): Promise<{ requeued: number; failed: number }> {
	const cutoff = new Date(Date.now() - staleAfterSec * 1000)
	const [requeued, failed] = await prisma.$transaction([
		prisma.nodeCommand.updateMany({
			where: {
				status: "DELIVERED",
				deliveredAt: { lt: cutoff },
				attempts: { lt: maxAttempts },
			},
			data: { status: "PENDING" },
		}),
		prisma.nodeCommand.updateMany({
			where: {
				status: "DELIVERED",
				deliveredAt: { lt: cutoff },
				attempts: { gte: maxAttempts },
			},
			data: { status: "FAILED", completedAt: new Date() },
		}),
	])
	return { requeued: requeued.count, failed: failed.count }
}

export async function hasOpenCommand(params: {
	nodeId: string
	sessionId: string
	type: CommandType
}): Promise<boolean> {
	const count = await prisma.nodeCommand.count({
		where: {
			nodeId: params.nodeId,
			sessionId: params.sessionId,
			type: params.type,
			status: { in: ["PENDING", "DELIVERED"] },
		},
	})
	return count > 0
}
