-- ============================================================================
-- GlukVPN beta sprint
--   1. random, non-enumerable public account numbers (1XXXXXXX)
--   2. email as a second login identity + verification-code infrastructure
--   3. approximate (country/region) origin of a user, resolved from the IP
--   4. node geography: region / city / ping target
--   5. START_BETA / STOP_BETA / RESTART_BETA deploy actions
--
-- Apply to the BETA database first (glukvpn_beta). PROD only receives it when
-- a promote is run, and nothing here rewrites existing rows.
-- ============================================================================

-- ------------------------------------------------------------- deploy actions
-- Beta lifecycle is queued like every other deploy job: a fixed enum value
-- maps to one fixed script with no arguments, so there is still no path from
-- the web UI to an arbitrary shell command.
ALTER TYPE "DeployAction" ADD VALUE IF NOT EXISTS 'START_BETA';
ALTER TYPE "DeployAction" ADD VALUE IF NOT EXISTS 'STOP_BETA';
ALTER TYPE "DeployAction" ADD VALUE IF NOT EXISTS 'RESTART_BETA';

-- --------------------------------------------------------- random public IDs
-- Sequential ids (00000001, 00000002, ...) leak the signup order and the total
-- user count, and are trivially enumerable in support/ban flows. From now on a
-- new account gets a random 8-digit number in 10000000..19999999.
--
-- Existing ids are intentionally NOT rewritten: public_id is immutable by
-- contract (there is a trigger enforcing it) and may already be referenced.
-- The old sequence is kept for the same reason - dropping it would break a
-- rollback to the previous release.
CREATE OR REPLACE FUNCTION gen_user_public_id() RETURNS text
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
	candidate text;
	attempts  int := 0;
BEGIN
	LOOP
		-- '1' followed by 7 random digits -> 10 000 000 possible values.
		candidate := '1' || lpad((floor(random() * 10000000))::bigint::text, 7, '0');
		EXIT WHEN NOT EXISTS (SELECT 1 FROM users WHERE public_id = candidate);
		attempts := attempts + 1;
		IF attempts >= 100 THEN
			-- Unreachable in practice; fail loudly instead of looping forever.
			RAISE EXCEPTION 'gen_user_public_id: no free id after % attempts', attempts;
		END IF;
	END LOOP;
	RETURN candidate;
END;
$$;

ALTER TABLE "users" ALTER COLUMN "public_id" SET DEFAULT gen_user_public_id();

-- --------------------------------------------------------- email + geo on user
-- email is nullable: accounts created before this migration (and CLI-created
-- test accounts) simply have none. Values are normalised to lower case by the
-- application, so a plain unique index is enough.
ALTER TABLE "users"
	ADD COLUMN "email"             TEXT,
	ADD COLUMN "email_verified_at" TIMESTAMP(3),
	ADD COLUMN "last_country"      TEXT,
	ADD COLUMN "last_country_code" TEXT,
	ADD COLUMN "last_region"       TEXT,
	ADD COLUMN "geo_updated_at"    TIMESTAMP(3);

CREATE UNIQUE INDEX "users_email_key" ON "users" ("email");

-- ------------------------------------------------------------ node geography
-- The app must show "Germany / Frankfurt", never the internal node name.
ALTER TABLE "vpn_nodes"
	ADD COLUMN "region"      TEXT,
	ADD COLUMN "city"        TEXT,
	ADD COLUMN "ping_target" TEXT;

-- ---------------------------------------------------------- verification codes
-- One table for every short-lived confirmation code: email verification, email
-- change, password reset, self-registration and new-device confirmation, over
-- email today and Telegram later. Only the HMAC of the code is stored, exactly
-- like refresh and node tokens.
CREATE TYPE "VerificationPurpose" AS ENUM (
	'EMAIL_VERIFY',
	'EMAIL_CHANGE',
	'PASSWORD_RESET',
	'REGISTRATION',
	'DEVICE_CONFIRM'
);

CREATE TYPE "VerificationChannel" AS ENUM ('EMAIL', 'TELEGRAM');

CREATE TABLE "verification_codes" (
	"id"          UUID                  NOT NULL,
	"user_id"     UUID,
	"purpose"     "VerificationPurpose" NOT NULL,
	"channel"     "VerificationChannel" NOT NULL DEFAULT 'EMAIL',
	-- Target address/handle. For EMAIL_CHANGE this is the *new* address, which
	-- is why the change can only land after the code is consumed.
	"destination" TEXT                  NOT NULL,
	"code_hash"   TEXT                  NOT NULL,
	"attempts"    INTEGER               NOT NULL DEFAULT 0,
	"expires_at"  TIMESTAMP(3)          NOT NULL,
	"consumed_at" TIMESTAMP(3),
	"created_ip"  TEXT,
	"created_at"  TIMESTAMP(3)          NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "verification_codes_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "verification_codes_purpose_destination_idx"
	ON "verification_codes" ("purpose", "destination");
CREATE INDEX "verification_codes_user_id_idx" ON "verification_codes" ("user_id");
CREATE INDEX "verification_codes_expires_at_idx" ON "verification_codes" ("expires_at");

ALTER TABLE "verification_codes"
	ADD CONSTRAINT "verification_codes_user_id_fkey"
	FOREIGN KEY ("user_id") REFERENCES "users" ("id")
	ON DELETE CASCADE ON UPDATE CASCADE;

-- -------------------------------------------------------------- social logins
-- Empty until Google Sign-In / Telegram verification are switched on; it exists
-- now so those flows never have to touch the users table again.
CREATE TYPE "IdentityProvider" AS ENUM ('GOOGLE', 'TELEGRAM');

CREATE TABLE "identity_links" (
	"id"               UUID               NOT NULL,
	"user_id"          UUID               NOT NULL,
	"provider"         "IdentityProvider" NOT NULL,
	"provider_user_id" TEXT               NOT NULL,
	"provider_email"   TEXT,
	"created_at"       TIMESTAMP(3)       NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "identity_links_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "identity_links_provider_provider_user_id_key"
	ON "identity_links" ("provider", "provider_user_id");
CREATE INDEX "identity_links_user_id_idx" ON "identity_links" ("user_id");

ALTER TABLE "identity_links"
	ADD CONSTRAINT "identity_links_user_id_fkey"
	FOREIGN KEY ("user_id") REFERENCES "users" ("id")
	ON DELETE CASCADE ON UPDATE CASCADE;
