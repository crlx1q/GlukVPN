// Throwaway test environment.
//
// These values are NOT secrets and are NOT used anywhere outside `vitest`:
// they exist only so that importing `src/config.ts` passes validation, which
// lets the unit tests exercise pure helpers without a .env file or a database.
// dotenv does not override variables that are already set, so these win.

process.env.NODE_ENV = "test"
process.env.LOG_LEVEL = "silent"
process.env.PUBLIC_API_URL = "http://127.0.0.1:8081"

process.env.DATABASE_URL =
	process.env.DATABASE_URL ??
	"postgresql://glukvpn:unit-test@127.0.0.1:5432/glukvpn_unit_test?schema=public"

process.env.JWT_SECRET =
	process.env.JWT_SECRET ?? "unit-test-jwt-secret-value-0000000000000000"

process.env.TOKEN_HASH_PEPPER =
	process.env.TOKEN_HASH_PEPPER ?? "unit-test-token-hash-pepper-000000000000000"

// Pin the timing-sensitive knobs so node status assertions are deterministic.
process.env.NODE_HEARTBEAT_INTERVAL_SEC = "10"
process.env.NODE_OFFLINE_AFTER_SEC = "30"
