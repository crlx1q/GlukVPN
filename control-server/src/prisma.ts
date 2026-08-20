import { PrismaClient } from "@prisma/client"
import { config } from "./config"

// NOTE: query logging is intentionally disabled. Query logs would contain
// password hashes and token hashes as bound parameters.
export const prisma = new PrismaClient({
	log: ["warn", "error"],
	datasources: { db: { url: config.DATABASE_URL } },
})

export async function disconnectPrisma(): Promise<void> {
	await prisma.$disconnect()
}

/** BigInt columns (byte counters) are not JSON-serializable by default. */
export function bytesToNumber(value: bigint | number | null | undefined): number {
	if (value === null || value === undefined) return 0
	return typeof value === "bigint" ? Number(value) : value
}
