/**
 * Which gateway is live - a row in the database, not a deploy.
 *
 * BILLING_PROVIDER in .env still seeds the choice and still answers when the
 * table is missing, but the switch an administrator flips in the panel lives
 * in `billing_settings` so that swapping acquirer during an outage is a click.
 * That is the whole point of the exercise: one gateway refuses a moderation
 * review, and the shop keeps selling through another one minutes later.
 *
 * Two safety rules are worth stating out loud:
 *
 *   - an id whose folder has been deleted is not honoured. Billing falls back
 *     to .env and, failing that, switches itself off. It never quietly charges
 *     through a different acquirer than the one that was chosen.
 *   - only ids this build knows are storable, so the column cannot be typed
 *     into a state the code has no adapter for.
 */
import { config } from "../config"
import { badRequest, serviceUnavailable } from "../lib/errors"
import { prisma } from "../prisma"
import { paymentModule } from "./registry"

/**
 * Gateways that are not folders:
 *
 *   - ""       - billing hidden; the site shows no prices at all;
 *   - "manual" - orders are created and an administrator marks them paid;
 *   - "stripe" - kept in `billing.ts` because it is not a Russian acquirer and
 *                shares nothing with the three that are.
 */
export const BUILTIN_PROVIDER_IDS: readonly string[] = ["", "manual", "stripe"]

const SINGLETON_ID = "global"
/** The choice is read on nearly every billing request and changes by hand. */
const CACHE_TTL_MS = 5000

type SettingsRow = { id: string; provider: string }

type SettingsDelegate = {
	findUnique(args: { where: { id: string } }): Promise<SettingsRow | null>
	upsert(args: {
		where: { id: string }
		create: SettingsRow
		update: { provider: string }
	}): Promise<SettingsRow>
}

/**
 * The delegate, reached through a narrow cast.
 *
 * `prisma generate` runs in the build, but not necessarily in the editor or in
 * a checkout that predates the model - and a hard reference would stop the
 * entire server compiling over one table. A missing delegate simply means
 * ".env decides", which is exactly how the server behaved before.
 */
function settingsTable(): SettingsDelegate | null {
	const client = prisma as unknown as { billingSettings?: SettingsDelegate }
	return client.billingSettings ?? null
}

let cache: { value: string; at: number } | null = null

/** True when this id can be selected: builtin, or an installed folder. */
export function providerIdExists(id: string): boolean {
	if (BUILTIN_PROVIDER_IDS.includes(id)) return true
	return paymentModule(id) !== null
}

/**
 * Whether a new choice can be stored at all.
 *
 * False on a server whose database has not run the `billing_settings`
 * migration yet. Reading still works there - .env answers - so the panel can
 * show the gateway in use and say why the switch is disabled, instead of
 * offering a control that answers 503.
 */
export function providerSwitchAvailable(): boolean {
	return settingsTable() !== null
}

/** The .env choice: the seed, and the fallback when the row cannot be used. */
export function envProviderId(): string {
	const id = config.BILLING_PROVIDER.trim()
	return providerIdExists(id) ? id : ""
}

/**
 * The gateway the next payment goes through.
 *
 * No row yet means nobody has touched the panel, so .env decides. A row
 * holding "" is a deliberate "billing off" and is honoured as such - which is
 * why the absence of a row and an empty row are not the same thing here.
 */
export async function activeProviderId(): Promise<string> {
	if (cache && Date.now() - cache.at < CACHE_TTL_MS) return cache.value

	let stored: string | null = null
	const table = settingsTable()
	if (table) {
		try {
			const row = await table.findUnique({ where: { id: SINGLETON_ID } })
			if (row) stored = typeof row.provider === "string" ? row.provider.trim() : ""
		} catch {
			// Table not migrated, or the database is having a moment. Either way
			// the shop should keep selling through whatever .env says.
			stored = null
		}
	}

	const value = stored === null ? envProviderId() : providerIdExists(stored) ? stored : envProviderId()
	cache = { value, at: Date.now() }
	return value
}

/** Switches the live gateway. Returns what was stored. */
export async function setActiveProviderId(id: string): Promise<string> {
	const next = id.trim()
	if (!providerIdExists(next)) {
		throw badRequest(`Unknown or uninstalled payment provider: ${next || "(empty)"}`)
	}
	const table = settingsTable()
	if (!table) throw serviceUnavailable("billing_settings is not migrated on this server yet")
	const row = await table.upsert({
		where: { id: SINGLETON_ID },
		create: { id: SINGLETON_ID, provider: next },
		update: { provider: next },
	})
	cache = { value: row.provider, at: Date.now() }
	return row.provider
}

/** Drops the cache so the next read hits the database. */
export function resetProviderCache(): void {
	cache = null
}
