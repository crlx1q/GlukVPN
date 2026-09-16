/**
 * The registry: which payment folders exist right now.
 *
 * Modules are loaded with a runtime `require` and never with a static import,
 * and that is the whole trick behind "delete the folder to remove the
 * gateway": a missing directory is a caught exception in one function instead
 * of a compile error in half the server. TypeScript still checks the folders
 * that are present, `tsc` still builds once one is gone, and nothing outside
 * `payments/` ever names an acquirer.
 *
 * KNOWN_PAYMENT_IDS is only the list of ids to *try*. What is installed is
 * whatever answered, which is why the admin panel can honestly show "TabPay -
 * folder removed" instead of pretending the choice still exists. Adding a
 * gateway is a folder, an id in this list and a restart.
 */
import type { PaymentModule } from "./types"

export const KNOWN_PAYMENT_IDS: readonly string[] = ["tabpay", "mulenpay", "cashera"]

/** Names for the panel when the folder is gone and cannot state its own. */
const FALLBACK_LABELS: Record<string, string> = {
	tabpay: "TabPay",
	mulenpay: "MulenPay",
	cashera: "Cashera",
}

/**
 * Resolved once per process. `require` caches too, but a failed lookup is not
 * cached by Node - and this function is called on every plans request.
 *
 * The consequence is that installing a new folder needs a restart. That is the
 * right trade: re-scanning the disk per request to catch a deploy that already
 * restarts the service would be work for nothing.
 */
const loaded = new Map<string, PaymentModule | null>()

function load(id: string): PaymentModule | null {
	const cached = loaded.get(id)
	if (cached !== undefined) return cached
	let mod: PaymentModule | null = null
	try {
		// Deliberately dynamic: see the note at the top of the file.
		const folder = require(`./${id}`) as { paymentModule?: PaymentModule }
		const candidate = folder?.paymentModule
		// The id in the module must match its folder, or the webhook path and
		// the env prefix would disagree with the admin panel's choice.
		mod = candidate && candidate.id === id ? candidate : null
	} catch {
		// Deleted, or broken beyond loading. Either way: not installed. A
		// gateway that cannot load is one that cannot take money, and the
		// alternative - throwing here - would take the whole API down with it.
		mod = null
	}
	loaded.set(id, mod)
	return mod
}

/** The gateway with this id, or null when its folder is not installed. */
export function paymentModule(id: string): PaymentModule | null {
	return id && KNOWN_PAYMENT_IDS.includes(id) ? load(id) : null
}

/** Every installed gateway, in the order listed above. */
export function installedPaymentModules(): PaymentModule[] {
	return KNOWN_PAYMENT_IDS.map((id) => load(id)).filter((mod): mod is PaymentModule => mod !== null)
}

export type PaymentModuleSummary = {
	id: string
	label: string
	/** The gateway's settlement currency, or null when it is not installed. */
	currency: string | null
	installed: boolean
	/** Installed and holding keys. Installed but unconfigured is a real state. */
	configured: boolean
}

/** What the admin panel lists - including the folders that are gone. */
export function paymentModuleSummaries(): PaymentModuleSummary[] {
	return KNOWN_PAYMENT_IDS.map((id) => {
		const mod = load(id)
		return {
			id,
			label: mod?.label ?? FALLBACK_LABELS[id] ?? id,
			currency: mod?.currency ?? null,
			installed: mod !== null,
			configured: mod ? mod.configured() : false,
		}
	})
}

/** Forgets what was loaded. For tests that install a fake gateway. */
export function resetPaymentModules(): void {
	loaded.clear()
}
