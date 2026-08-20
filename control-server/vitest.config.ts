import { defineConfig } from "vitest/config"

export default defineConfig({
	test: {
		environment: "node",
		include: ["tests/**/*.test.ts"],
		// tests/setup.ts injects a throwaway environment so importing src/config.ts
		// does not require a real .env file or a reachable database.
		setupFiles: ["./tests/setup.ts"],
		hookTimeout: 20000,
		testTimeout: 20000,
	},
})
