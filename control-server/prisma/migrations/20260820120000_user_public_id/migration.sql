-- ============================================================================
-- Public, immutable account number for users: "00000001", "00000002", ...
--
-- Why a sequence and not a random id:
--   the number is meant to be read out loud and typed into the admin search,
--   so it must be short, stable and collision-free.
--
-- Immutability is enforced by the database, not only by the API: a BEFORE
-- UPDATE trigger rejects any statement that tries to change public_id, even a
-- manual psql UPDATE. Renaming `username` stays allowed.
-- ============================================================================

CREATE SEQUENCE IF NOT EXISTS user_public_id_seq AS BIGINT START WITH 1 INCREMENT BY 1;

-- 1. Add the column as nullable so existing rows can be backfilled.
ALTER TABLE "users" ADD COLUMN "public_id" TEXT;

-- 2. Backfill in registration order: the oldest account becomes 00000001.
WITH ordered AS (
    SELECT "id", row_number() OVER (ORDER BY "created_at", "id") AS rn
    FROM "users"
)
UPDATE "users" AS u
SET "public_id" = lpad(ordered.rn::text, 8, '0')
FROM ordered
WHERE u."id" = ordered."id";

-- 3. Move the sequence past the numbers handed out above.
SELECT setval(
    'user_public_id_seq',
    COALESCE((SELECT max("public_id"::BIGINT) FROM "users"), 0) + 1,
    false
);

-- 4. Lock the column down and let the sequence fill it from now on.
ALTER TABLE "users" ALTER COLUMN "public_id" SET NOT NULL;
ALTER TABLE "users"
    ALTER COLUMN "public_id"
    SET DEFAULT lpad(nextval('user_public_id_seq')::text, 8, '0');

CREATE UNIQUE INDEX "users_public_id_key" ON "users"("public_id");

-- 5. Reject every attempt to change public_id, from any client.
CREATE OR REPLACE FUNCTION users_public_id_immutable() RETURNS TRIGGER AS $$
BEGIN
    IF NEW."public_id" IS DISTINCT FROM OLD."public_id" THEN
        RAISE EXCEPTION 'users.public_id is immutable (attempted % -> %)',
            OLD."public_id", NEW."public_id";
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_public_id_immutable_trg
    BEFORE UPDATE ON "users"
    FOR EACH ROW
    EXECUTE FUNCTION users_public_id_immutable();
