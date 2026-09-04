import { describe, expect, it } from "vitest"
import { effectiveSessionLimit, SESSION_LIMIT_CEILING } from "../src/lib/sessionLimit"

describe("effectiveSessionLimit", () => {
	it("allows Pro users 5 concurrent sessions regardless of env default", () => {
		expect(effectiveSessionLimit({ maxSessions: 5 })).toBe(5)
	})

	it("allows Basic users 3 concurrent sessions", () => {
		expect(effectiveSessionLimit({ maxSessions: 3 })).toBe(3)
	})

	it("keeps Free users at 1 concurrent session", () => {
		expect(effectiveSessionLimit({ maxSessions: 1 })).toBe(1)
	})

	it("caps maximum sessions at SESSION_LIMIT_CEILING", () => {
		expect(effectiveSessionLimit({ maxSessions: 100 })).toBe(SESSION_LIMIT_CEILING)
	})

	it("enforces minimum of 1 session even if 0 or negative", () => {
		expect(effectiveSessionLimit({ maxSessions: 0 })).toBe(1)
		expect(effectiveSessionLimit({ maxSessions: -5 })).toBe(1)
	})

	it("falls back to config.MAX_CONCURRENT_SESSIONS when allowance is NaN", () => {
		expect(effectiveSessionLimit({ maxSessions: Number.NaN })).toBeGreaterThanOrEqual(1)
	})
})
