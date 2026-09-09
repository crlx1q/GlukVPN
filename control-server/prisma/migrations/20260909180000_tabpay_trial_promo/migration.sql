-- TabPay, the trial promotion and promo codes.
--
-- Three tables and one hidden plan.
--
-- 1. promo_codes / promo_redemptions. A percentage off one order. The
--    redemption row is unique per order, which is what makes a code survive a
--    webhook delivered five times: it is consumed once, when the money
--    arrives, so an abandoned checkout never burns a single-use code.
--
-- 2. trial_offers. The promotion itself - length, sign-up window, plan and
--    price - as one row the admin panel edits. The .env values only seed this
--    row the first time it is read, so switching the offer off or moving it to
--    Pro is a click and not a deploy.
--
-- 3. basic_trial. The hidden plan the trial actually sells: seven days for one
--    rouble, is_public = false so it never shows up in the catalogue, priced
--    in every currency the site quotes because the equivalents are shown to
--    the visitor even when the charge itself settles in roubles.

-- ------------------------------------------------------------ 1. promo codes
CREATE TABLE IF NOT EXISTS "promo_codes" (
	"id"              UUID         NOT NULL,
	"code"            TEXT         NOT NULL,
	"description"     TEXT,
	"percent_off"     INTEGER      NOT NULL,
	"active"          BOOLEAN      NOT NULL DEFAULT true,
	"starts_at"       TIMESTAMP(3),
	"ends_at"         TIMESTAMP(3),
	-- NULL = unlimited overall.
	"max_redemptions" INTEGER,
	-- 0 = unlimited per account.
	"per_user_limit"  INTEGER      NOT NULL DEFAULT 1,
	-- Empty array = every paid plan.
	"plan_codes"      JSONB        NOT NULL DEFAULT '[]',
	-- Denormalised counter, so the global limit is a read and not a COUNT(*).
	"redeemed_count"  INTEGER      NOT NULL DEFAULT 0,
	"created_at"      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"updated_at"      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "promo_codes_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "promo_codes_code_key" ON "promo_codes" ("code");

CREATE TABLE IF NOT EXISTS "promo_redemptions" (
	"id"             UUID         NOT NULL,
	"promo_code_id"  UUID         NOT NULL,
	"user_id"        UUID         NOT NULL,
	"order_id"       UUID         NOT NULL,
	"discount_minor" INTEGER      NOT NULL,
	"currency"       TEXT         NOT NULL,
	"created_at"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "promo_redemptions_pkey" PRIMARY KEY ("id")
);

-- One code per order. This index is the idempotency guard for a retried
-- webhook, not merely a tidy constraint.
CREATE UNIQUE INDEX IF NOT EXISTS "promo_redemptions_order_id_key"
	ON "promo_redemptions" ("order_id");
CREATE INDEX IF NOT EXISTS "promo_redemptions_promo_code_id_idx"
	ON "promo_redemptions" ("promo_code_id");
CREATE INDEX IF NOT EXISTS "promo_redemptions_user_id_idx"
	ON "promo_redemptions" ("user_id");

DO $$ BEGIN
	ALTER TABLE "promo_redemptions"
		ADD CONSTRAINT "promo_redemptions_promo_code_id_fkey"
		FOREIGN KEY ("promo_code_id") REFERENCES "promo_codes" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
	ALTER TABLE "promo_redemptions"
		ADD CONSTRAINT "promo_redemptions_user_id_fkey"
		FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
	ALTER TABLE "promo_redemptions"
		ADD CONSTRAINT "promo_redemptions_order_id_fkey"
		FOREIGN KEY ("order_id") REFERENCES "orders" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------- 2. trial offer
CREATE TABLE IF NOT EXISTS "trial_offers" (
	"id"               TEXT         NOT NULL DEFAULT 'global',
	"enabled"          BOOLEAN      NOT NULL DEFAULT true,
	"plan_code"        TEXT         NOT NULL DEFAULT 'basic',
	"days"             INTEGER      NOT NULL DEFAULT 7,
	"eligibility_days" INTEGER      NOT NULL DEFAULT 14,
	"require_telegram" BOOLEAN      NOT NULL DEFAULT true,
	-- Kopecks. 100 = 1 RUB, which is also the gateway's own minimum charge.
	"price_kopecks"    INTEGER      NOT NULL DEFAULT 100,
	"updated_at"       TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "trial_offers_pkey" PRIMARY KEY ("id")
);

-- The single row. The service would create it on first read anyway; seeding it
-- here means a fresh beta database answers /api/billing/trial before anybody
-- has opened the admin panel.
INSERT INTO "trial_offers" ("id") VALUES ('global')
ON CONFLICT ("id") DO NOTHING;

-- ------------------------------------------------------- 3. the trial plan
-- Basic's limits, seven days, one rouble, hidden from the shop. Sold only
-- through /api/billing/trial/claim, which is what keeps "one trial per
-- account" checkable: a PAID order for this plan is the record of the claim.
INSERT INTO "plans" ("id", "code", "name", "tier", "days", "price_minor", "currency",
                     "max_devices", "max_sessions", "traffic_gb", "features",
                     "featured", "active", "is_public", "sort_order", "updated_at")
VALUES
	(gen_random_uuid(), 'basic_trial', 'Basic · пробный период', 1, 7, 100, 'RUB', 3, 3, 50,
	 '["3 устройства", "3 одновременных подключения", "50 GB в месяц", "Выбор сервера", "DNS Protection", "7 дней за 1 ₽"]'::jsonb,
	 false, true, false, 90, CURRENT_TIMESTAMP)
ON CONFLICT ("code") DO NOTHING;

-- The charge settles in roubles; the other two rows are what the banner and
-- /trial quote to a visitor in Kazakhstan or abroad (100 ₸ / $0.10).
INSERT INTO "plan_prices" ("id", "plan_id", "currency", "price_minor")
SELECT gen_random_uuid(), p."id", v."currency", v."price_minor"
FROM (VALUES
	('basic_trial', 'RUB',   100),
	('basic_trial', 'KZT', 10000),
	('basic_trial', 'USD',    10)
) AS v("code", "currency", "price_minor")
JOIN "plans" p ON p."code" = v."code"
ON CONFLICT ("plan_id", "currency") DO UPDATE
	SET "price_minor" = EXCLUDED."price_minor",
	    "updated_at"  = CURRENT_TIMESTAMP;

-- ------------------------------------------------------------ 4. TIKTOK -25%
-- One use per account, monthly and quarterly plans only. The trial is left out
-- deliberately: 25% off one rouble is 75 kopecks, and the gateway refuses
-- anything below a rouble - a code that cannot be honoured should not be
-- offered in the first place.
INSERT INTO "promo_codes" ("id", "code", "description", "percent_off", "active",
                           "per_user_limit", "plan_codes", "updated_at")
VALUES
	(gen_random_uuid(), 'TIKTOK', 'TikTok: −25% на подписку', 25, true, 1,
	 '["basic", "pro", "basic_3m", "pro_3m"]'::jsonb, CURRENT_TIMESTAMP)
ON CONFLICT ("code") DO NOTHING;
