-- Tariffs aligned with price.md, plus a per-currency price matrix.
--
-- Four things happen here.
--
-- 1. The seeded prices were wrong. price.md sells Basic at 790 KZT and Pro at
--    1 490 KZT; the initial seed charged 1 490 and 2 490 - Basic was being sold
--    at Pro's price. Concurrent tunnels were seeded 1/1/2 where the table says
--    1/3/5, so a paying Pro user got two tunnels instead of five.
--
-- 2. price.md has a three-month row and a hidden internal tier. Neither
--    existed as a plan at all, so neither could be sold or granted.
--
-- 3. Monthly traffic caps (5/50/150 GB) were not modelled anywhere, which is
--    why the Free plan's own feature list claimed "no traffic limits".
--
-- 4. Prices now exist per currency, so a Kazakh, Russian or international
--    visitor each sees their own. A new market is a row in plan_prices rather
--    than a schema change, and plans.price_minor stays as the fallback for a
--    currency nobody has priced yet.

-- ------------------------------------------------------- 1. new plan columns
-- NULL traffic_gb = uncapped, so a future unmetered tier needs no sentinel.
ALTER TABLE "plans" ADD COLUMN IF NOT EXISTS "traffic_gb" INTEGER;

-- "active" already means "may be granted or renewed". Hiding a tier from the
-- shop is a different question, so it gets its own flag: beta_pro has to stay
-- grantable by an admin while never appearing in the public catalogue.
ALTER TABLE "plans" ADD COLUMN IF NOT EXISTS "is_public" BOOLEAN NOT NULL DEFAULT true;

-- ----------------------------------------------------------- 2. price matrix
CREATE TABLE IF NOT EXISTS "plan_prices" (
	"id"          UUID         NOT NULL,
	"plan_id"     UUID         NOT NULL,
	"currency"    TEXT         NOT NULL,
	"price_minor" INTEGER      NOT NULL,
	"created_at"  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"updated_at"  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "plan_prices_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "plan_prices_plan_id_currency_key"
	ON "plan_prices" ("plan_id", "currency");

DO $$ BEGIN
	ALTER TABLE "plan_prices"
		ADD CONSTRAINT "plan_prices_plan_id_fkey"
		FOREIGN KEY ("plan_id") REFERENCES "plans" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------------------------- 3. correct the seeded rows
UPDATE "plans" SET
	"price_minor"  = 0,
	"max_devices"  = 1,
	"max_sessions" = 1,
	"traffic_gb"   = 5,
	"features"     = '["1 устройство", "5 GB в месяц", "Auto Best Server", "Kill Switch"]'::jsonb,
	"updated_at"   = CURRENT_TIMESTAMP
WHERE "code" = 'free';

UPDATE "plans" SET
	"price_minor"  = 79000,
	"max_devices"  = 3,
	"max_sessions" = 3,
	"traffic_gb"   = 50,
	"features"     = '["3 устройства", "3 одновременных подключения", "50 GB в месяц", "Выбор сервера", "DNS Protection", "Kill Switch"]'::jsonb,
	"updated_at"   = CURRENT_TIMESTAMP
WHERE "code" = 'basic';

UPDATE "plans" SET
	"price_minor"  = 149000,
	"max_devices"  = 5,
	"max_sessions" = 5,
	"traffic_gb"   = 150,
	"features"     = '["5 устройств", "5 одновременных подключений", "150 GB в месяц", "Все серверы и новые регионы первыми", "DNS Protection", "Kill Switch"]'::jsonb,
	"updated_at"   = CURRENT_TIMESTAMP
WHERE "code" = 'pro';

-- --------------------------------------- 4. three-month rows and the beta tier
-- Ninety days rather than three calendar months: `days` is what the renewal
-- arithmetic already uses everywhere else.
--
-- beta_pro carries Pro's limits at zero cost and is_public = false. It is the
-- internal test tier from price.md: grantable from the admin panel with any
-- period, never listed in the shop, never purchasable.
INSERT INTO "plans" ("id", "code", "name", "tier", "days", "price_minor", "currency",
                     "max_devices", "max_sessions", "traffic_gb", "features",
                     "featured", "active", "is_public", "sort_order", "updated_at")
VALUES
	(gen_random_uuid(), 'basic_3m', 'Basic · 3 месяца', 1, 90, 199000, 'KZT', 3, 3, 50,
	 '["3 устройства", "3 одновременных подключения", "50 GB в месяц", "Выбор сервера", "DNS Protection", "Выгоднее на 16%"]'::jsonb,
	 false, true, true, 21, CURRENT_TIMESTAMP),
	(gen_random_uuid(), 'pro_3m', 'Pro · 3 месяца', 2, 90, 399000, 'KZT', 5, 5, 150,
	 '["5 устройств", "5 одновременных подключений", "150 GB в месяц", "Все серверы и новые регионы первыми", "DNS Protection", "Выгоднее на 11%"]'::jsonb,
	 true, true, true, 31, CURRENT_TIMESTAMP),
	(gen_random_uuid(), 'beta_pro', 'β Pro', 2, 30, 0, 'KZT', 5, 5, 150,
	 '["Возможности Pro", "Внутренний тестовый доступ", "Не отображается в каталоге"]'::jsonb,
	 false, true, false, 90, CURRENT_TIMESTAMP)
ON CONFLICT ("code") DO NOTHING;

-- ------------------------------------------------------------ 5. the currencies
-- KZT and RUB are quoted in price.md and in the operator's own note; USD is
-- the rest of the world. The monthly figures are given, the quarterly ones are
-- the usual two-and-a-half months of the monthly price rounded to a price that
-- reads like a price - change any row here and nothing else needs touching.
--
--   KZ  790 / 1 490 KZT per month,   1 990 / 3 990 KZT per quarter
--   RU  150 /   290 RUB per month,     379 /   739 RUB per quarter
--   ROW 1.99 /  3.99 USD per month,   4.99 /  9.99 USD per quarter
INSERT INTO "plan_prices" ("id", "plan_id", "currency", "price_minor")
SELECT gen_random_uuid(), p."id", v."currency", v."price_minor"
FROM (VALUES
	('free',     'KZT',      0),
	('free',     'RUB',      0),
	('free',     'USD',      0),
	('basic',    'KZT',  79000),
	('basic',    'RUB',  15000),
	('basic',    'USD',    199),
	('pro',      'KZT', 149000),
	('pro',      'RUB',  29000),
	('pro',      'USD',    399),
	('basic_3m', 'KZT', 199000),
	('basic_3m', 'RUB',  37900),
	('basic_3m', 'USD',    499),
	('pro_3m',   'KZT', 399000),
	('pro_3m',   'RUB',  73900),
	('pro_3m',   'USD',    999),
	('beta_pro', 'KZT',      0),
	('beta_pro', 'RUB',      0),
	('beta_pro', 'USD',      0)
) AS v("code", "currency", "price_minor")
JOIN "plans" p ON p."code" = v."code"
ON CONFLICT ("plan_id", "currency") DO UPDATE
	SET "price_minor" = EXCLUDED."price_minor",
	    "updated_at"  = CURRENT_TIMESTAMP;
