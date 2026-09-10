import { describe, expect, it } from "vitest"
import {
	effectiveSpeedLimit,
	type Entitlement,
	planShape,
	planSpeedPriority,
	quotaPeriod,
	PLAN_MATRIX,
} from "../src/services/entitlements"
import { quotaPayload, type QuotaStatus } from "../src/services/quota"

// The speed cap is a server decision, exactly like the traffic quota and the
// device count: the client renders the number, the node enforces it. These
// tests pin the two halves of that decision - what a plan is worth, and how a
// manual override interacts with it.
describe("plan speed caps", () => {
	it("gives every sold plan the cap from price.md", () => {
		expect(planShape("free").speedMbps).toBe(30)
		expect(planShape("basic").speedMbps).toBe(100)
		expect(planShape("pro").speedMbps).toBe(250)
	})

	it("keeps a longer term and a trial on the same cap as the plan they preview", () => {
		expect(planShape("basic_3m").speedMbps).toBe(planShape("basic").speedMbps)
		expect(planShape("basic_trial").speedMbps).toBe(planShape("basic").speedMbps)
		expect(planShape("pro_3m").speedMbps).toBe(planShape("pro").speedMbps)
		expect(planShape("pro_trial").speedMbps).toBe(planShape("pro").speedMbps)
	})

	it("treats the internal tiers as Pro so testers are not throttled", () => {
		expect(planShape("beta_pro").speedMbps).toBe(250)
		expect(planShape("test").speedMbps).toBe(250)
	})

	it("falls back to the Free cap for an unknown plan code", () => {
		expect(planShape("nonsense_plan").speedMbps).toBe(30)
		expect(planShape(null).speedMbps).toBe(30)
	})

	it("leaves no plan in the matrix without a cap", () => {
		for (const [code, shape] of Object.entries(PLAN_MATRIX)) {
			expect(shape.speedMbps, code).toBeTypeOf("number")
			expect(shape.speedMbps ?? 0, code).toBeGreaterThan(0)
		}
	})
})

// Priority only matters while the uplink is congested: the kernel drains the
// lowest class first, so Free must never be served before a paid tier.
describe("planSpeedPriority", () => {
	it("orders beta above pro, pro above basic and basic above free", () => {
		expect(planSpeedPriority("beta_pro")).toBeLessThan(planSpeedPriority("pro"))
		expect(planSpeedPriority("pro")).toBeLessThan(planSpeedPriority("basic"))
		expect(planSpeedPriority("basic")).toBeLessThan(planSpeedPriority("free"))
	})

	it("gives the same priority to a plan and its longer term or trial", () => {
		expect(planSpeedPriority("pro_3m")).toBe(planSpeedPriority("pro"))
		expect(planSpeedPriority("pro_trial")).toBe(planSpeedPriority("pro"))
		expect(planSpeedPriority("basic_trial")).toBe(planSpeedPriority("basic"))
		expect(planSpeedPriority("test")).toBe(planSpeedPriority("beta_pro"))
	})

	it("treats an unknown or missing code as the lowest priority", () => {
		expect(planSpeedPriority("nonsense_plan")).toBe(planSpeedPriority("free"))
		expect(planSpeedPriority(null)).toBe(planSpeedPriority("free"))
	})

	it("stays inside the tc prio range the shaper writes", () => {
		for (const code of Object.keys(PLAN_MATRIX)) {
			const prio = planSpeedPriority(code)
			expect(prio, code).toBeGreaterThanOrEqual(0)
			expect(prio, code).toBeLessThanOrEqual(7)
		}
	})
})

describe("effectiveSpeedLimit", () => {
	it("prefers the manual cap over the plan cap", () => {
		expect(effectiveSpeedLimit(50, 250)).toBe(50)
	})

	it("lets support raise an account above its plan", () => {
		// A Free tester on 500 Mbit/s must not require inventing a plan row.
		expect(effectiveSpeedLimit(500, 30)).toBe(500)
	})

	it("uses the plan cap when there is no override", () => {
		expect(effectiveSpeedLimit(null, 100)).toBe(100)
		expect(effectiveSpeedLimit(undefined, 100)).toBe(100)
	})

	it("reports no cap only when neither side has one", () => {
		expect(effectiveSpeedLimit(null, null)).toBeNull()
		expect(effectiveSpeedLimit(undefined, undefined)).toBeNull()
	})

	it("caps an unshaped plan when the override says so", () => {
		expect(effectiveSpeedLimit(100, null)).toBe(100)
	})
})

// The four clients render the cap and none of them may compute it - the plan
// matrix lives here. The quota payload is the only place that number crosses
// the wire, so a refactor there must not silently drop it again.
describe("quotaPayload speed", () => {
	const period = quotaPeriod(
		new Date("2026-01-01T00:00:00.000Z"),
		new Date("2026-01-10T00:00:00.000Z"),
	)

	function statusWith(
		speedLimitMbps: number | null,
		speedLimitSource: "plan" | "manual" = "plan",
	): QuotaStatus {
		const entitlement: Entitlement = {
			planCode: "pro",
			planName: "Pro",
			badge: "pro",
			tier: 2,
			subscribed: true,
			subscriptionId: null,
			source: null,
			expiresAt: null,
			daysLeft: null,
			maxDevices: 5,
			maxSessions: 5,
			trafficLimitBytes: 1024,
			speedLimitMbps,
			speedLimitSource,
			speedPriority: planSpeedPriority("pro"),
			period,
		}
		return {
			entitlement,
			period,
			usedBytes: 256,
			limitBytes: 1024,
			remainingBytes: 768,
			usedFraction: 0.25,
			exceeded: false,
		}
	}

	it("sends the cap next to the bytes, where every client draws it", () => {
		const payload = quotaPayload(statusWith(planShape("pro").speedMbps ?? null))
		expect(payload.speedLimitMbps).toBe(250)
		expect(payload.speedLimitSource).toBe("plan")
		// The traffic half of the same answer must survive the addition.
		expect(payload.limitBytes).toBe(1024)
	})

	it("tells the client when support set the number by hand", () => {
		expect(quotaPayload(statusWith(500, "manual")).speedLimitSource).toBe("manual")
	})

	it("keeps null for an unshaped account instead of inventing a zero", () => {
		// A 0 in that field would read as "no traffic allowed" on every client.
		expect(quotaPayload(statusWith(null)).speedLimitMbps).toBeNull()
	})
})
