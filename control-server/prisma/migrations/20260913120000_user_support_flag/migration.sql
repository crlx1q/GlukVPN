-- #103: support (manager) flag.
--
-- A second boolean next to `is_admin`, not a role enum: the two privileges are
-- independent and an administrator never needs this one set. Support may open
-- the admin panel read-only and grant or revoke a subscription; nodes,
-- maintenance, channels, service settings, blocking, deletion and every flag
-- stay admin-only. Enforcement lives in the API (requireStaff plus the support
-- gate in routes/admin.ts), so this migration only adds the column.

ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "is_support" BOOLEAN NOT NULL DEFAULT false;
