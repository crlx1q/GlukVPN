import { describe, expect, it } from "vitest"
import { config } from "../src/config"

describe("registration and billing config defaults", () => {
	it("defaults REGISTER_REQUIRE_TELEGRAM to false so sign-up succeeds with email alone", () => {
		expect(config.REGISTER_REQUIRE_TELEGRAM).toBe(false)
	})

	it("defaults GOOGLE_REQUIRE_TELEGRAM to true", () => {
		expect(config.GOOGLE_REQUIRE_TELEGRAM).toBe(true)
	})

	it("defaults billing currency to KZT and takes the provider from env alone", () => {
		expect(config.BILLING_CURRENCY).toBe("KZT")
		// The id is a free string now: every adapter lives in its own folder under
		// src/payments/<id> and registers itself, so the schema cannot enumerate
		// them without breaking the "delete the folder" promise. Unset means
		// billing is hidden, and the live choice is a row in billing_settings.
		expect(typeof config.BILLING_PROVIDER).toBe("string")
		expect(config.BILLING_PROVIDER).toBe(process.env.BILLING_PROVIDER ?? "")
	})

	it("sends the payer back to the GitHub Pages app shell by default", () => {
		expect(config.BILLING_APP_BASE_URL).toBe("https://app.gluk.tech")
	})
})
