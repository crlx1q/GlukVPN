-- Tombstone state for deleted accounts.
--
-- A deleted account keeps exactly one row: status DELETED plus when, why and
-- by whom. Every personal field is wiped by the deletion service itself, so
-- all this migration has to add is the state that survives.
--
-- The new enum value and the columns live in one file deliberately: nothing
-- here *uses* 'DELETED' as a value, which is the only thing PostgreSQL
-- forbids in the transaction that added it.
ALTER TYPE "UserStatus" ADD VALUE IF NOT EXISTS 'DELETED';

ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "deleted_at" TIMESTAMP(3);
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "deleted_reason" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "deleted_by" UUID;
