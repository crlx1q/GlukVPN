-- Per-device speed caps.
--
-- Two nullable columns, no new table.
--
-- 1. plans.speed_mbps - the line speed every device on that plan gets, in
--    Mbit/s. NULL = unshaped, so an unmetered tier needs no sentinel value.
-- 2. users.speed_limit_mbps - a manual override for one account, set from the
--    admin panel. NULL = the plan decides. It wins in both directions:
--    support can slow one abusive Pro down, or hand a Free tester
--    500 Mbit/s, without inventing a plan for it.
--
-- This is a *physical* rate limit, enforced on the node per WireGuard peer -
-- the same idea as the speed an ISP sells. It is unrelated to the monthly GB
-- quota: the quota says how much, this says how fast.

ALTER TABLE "plans" ADD COLUMN IF NOT EXISTS "speed_mbps" INTEGER;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "speed_limit_mbps" INTEGER;

-- price.md, mirrored in entitlements.ts PLAN_MATRIX. Only rows that have no
-- value yet are touched, so a plan an operator has already tuned by hand
-- keeps whatever it holds and re-running the migration is a no-op.
UPDATE "plans" SET "speed_mbps" = v."speed_mbps"
FROM (VALUES
	('free',         30),
	('basic',       100),
	('basic_3m',    100),
	('basic_trial', 100),
	('pro',         250),
	('pro_3m',      250),
	('pro_trial',   250),
	('beta_pro',    250),
	('test',        250)
) AS v("code", "speed_mbps")
WHERE "plans"."code" = v."code" AND "plans"."speed_mbps" IS NULL;
