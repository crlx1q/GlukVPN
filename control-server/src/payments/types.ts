/**
 * The contract every payment gateway implements.
 *
 * One folder per gateway under `payments/`, one shape for all of them. The
 * billing service knows this file and nothing else about any acquirer: it
 * hands over an order and receives either a link to send the browser to or a
 * normalised event, and that is the whole surface.
 *
 * The rule that makes a folder disposable: nothing outside `payments/`
 * imports a gateway by name. `registry.ts` loads them dynamically, so
 * deleting `payments/mulenpay/` removes the gateway from the switch and from
 * the build, and everything else keeps working.
 */

/**
 * What a gateway's status means in our own vocabulary.
 *
 *   - "paid"     - money arrived; this is the only kind that grants a plan.
 *   - "failed"   - the attempt is over and was refused.
 *   - "expired"  - nobody paid in time.
 *   - "canceled" - the payer or the shop called it off.
 *   - "refunded" - money was given back (or charged back).
 *   - "pending"  - created, in progress, or on hold: wait.
 *   - "probe"    - a "test webhook" button in the gateway dashboard. It proves
 *                  the URL and the secret and must never hand out anything.
 *   - "unknown"  - a status this adapter does not recognise. Acknowledged and
 *                  ignored, so a new status in the gateway's API cannot make
 *                  us act on a guess.
 */
export type PaymentEventKind =
	| "paid"
	| "failed"
	| "expired"
	| "canceled"
	| "refunded"
	| "pending"
	| "probe"
	| "unknown"

/** What a client needs in order to pay. Identical to billing's CheckoutResult. */
export type PaymentCheckout = {
	paymentUrl: string | null
	/** The gateway's own id for the payment, stored on the order. */
	providerRef: string | null
	manual: boolean
	instructions: string | null
}

export type PaymentCustomer = {
	userId: string
	email?: string | null
	/** Digits only, or absent. Never a @username. */
	telegramId?: string | null
}

/**
 * One rail a payer may choose, as the checkout offers it.
 *
 * `id` is the gateway's own code for the rail, passed back unchanged when the
 * order is created - except `"all"`, which every gateway understands as "your
 * universal form, let the payer choose there".
 *
 * `minimumMinor` is the floor for *this rail* when it is higher than the
 * module's own (Cashera takes a rouble by SBP and a hundred by card). It is
 * what lets a 1 ₽ trial grey out the card instead of sending somebody to a
 * page that will refuse them.
 */
export type PaymentMethodOption = {
	id: string
	label: string
	minimumMinor?: number
}

/**
 * One order, as a gateway needs to see it.
 *
 * `amountMinor` is always an integer in the smallest unit of `currency`
 * (kopecks for RUB), because that is the only representation that cannot be
 * rounded into somebody else's money.
 */
export type PaymentOrderInput = {
	orderId: string
	amountMinor: number
	currency: string
	description: string
	/** A trial claim. Changes only which page the payer comes back to. */
	isTrial: boolean
	/**
	 * The rail the payer picked, as an id from `availableMethods`, or absent
	 * when they were not asked - in which case the gateway's own .env default
	 * applies. `"all"` is a choice too: it means "show me every rail".
	 */
	method?: string | null
	successUrl: string
	failUrl: string
	/**
	 * Where this gateway must POST the result. Gateways that take the address
	 * per payment use it; the others have it configured in their dashboard and
	 * ignore it.
	 */
	webhookUrl: string
	customer: PaymentCustomer
	/** Echoed back by the gateway when it supports metadata. */
	metadata: Record<string, unknown>
}

/** A payment as the gateway currently sees it. */
export type PaymentSnapshot = {
	providerRef: string | null
	/** The gateway's own status text or code, kept for the audit trail. */
	status: string
	kind: PaymentEventKind
	amountMinor?: number | null
}

/** A webhook, translated. */
export type PaymentEvent = {
	kind: PaymentEventKind
	/** Our own order id, when the event carries one. */
	orderId: string | null
	providerRef: string | null
	status: string
	amountMinor?: number | null
}

/**
 * A webhook delivery. `rawBody` is the bytes as received: re-serialising the
 * JSON changes key order and whitespace, and signatures stop matching.
 */
export type WebhookRequest = {
	rawBody: string
	headers: Record<string, unknown>
	query: Record<string, unknown>
}

export type PaymentModule = {
	/** Stable id: the env prefix, the folder name and the webhook path. */
	readonly id: string
	/** Shown in the admin panel. */
	readonly label: string
	/** The only currency this gateway settles in, uppercase. */
	readonly currency: string
	/** Smallest charge the gateway accepts, in minor units. */
	readonly minimumMinor: number
	/**
	 * True when this gateway's keys are present. A module that is installed but
	 * not configured is offered in the admin panel and refuses to take money,
	 * which is the honest way round.
	 */
	configured(): boolean
	/**
	 * The rails a payer may choose for this currency, the universal form
	 * first, or `[]` when the gateway cannot settle it at all.
	 *
	 * Optional: a gateway that leaves it out takes whatever its dashboard is
	 * set to, and the site shows no selector rather than a selector that
	 * promises a rail nobody honours.
	 */
	availableMethods?(currency: string): PaymentMethodOption[]
	createCheckout(input: PaymentOrderInput): Promise<PaymentCheckout>
	/**
	 * Asks the gateway what really happened. Used to reconcile an order whose
	 * webhook was late, lost, or never configured - never in a poll loop.
	 */
	fetchStatus(ref: { orderId: string; providerRef: string | null }): Promise<PaymentSnapshot | null>
	/** Rejects a delivery that is not from the gateway. */
	verifyWebhook(request: WebhookRequest): boolean
	parseWebhook(request: WebhookRequest): PaymentEvent
	/**
	 * Set when the webhook carries no signature of its own: the billing layer
	 * then re-asks the API before granting anything, so a forged "paid" is
	 * worth nothing even if the URL leaks.
	 */
	readonly confirmWebhookByStatus?: boolean
}
