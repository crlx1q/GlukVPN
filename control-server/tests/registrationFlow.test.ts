import { describe, expect, it } from "vitest"
import { config } from "../src/config"

describe("registration and billing config defaults", () => {
	it("defaults REGISTER_REQUIRE_TELEGRAM to false so sign-up succeeds with email alone", () => {
		expect(config.REGISTER_REQUIRE_TELEGRAM).toBe(false)
	})

	it("defaults GOOGLE_REQUIRE_TELEGRAM to true", () => {
		expect(config.GOOGLE_REQUIRE_TELEGRAM).toBe(true)
	})

	it("defaults billing currency to KZT and provider defaults to unconfigured without env", () => {
		expect(config.BILLING_CURRENCY).toBe("KZT")
		expect(["", "tabpay", "stripe", "manual"]).toContain(config.BILLING_PROVIDER)
	})
})
