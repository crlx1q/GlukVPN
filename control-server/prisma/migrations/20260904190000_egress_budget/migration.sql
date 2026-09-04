-- Oracle always-free egress budget, tracked per PAYG billing cycle.
--
-- One row per cycle, keyed by the cycle's first instant so an upsert is enough
-- to roll over: there is no scheduled job that has to notice the anniversary.
CREATE TABLE IF NOT EXISTS "egress_budget_cycles" (
    "id" UUID NOT NULL,
    "cycle_start" TIMESTAMP(3) NOT NULL,
    "cycle_end" TIMESTAMP(3) NOT NULL,
    "bytes_out" BIGINT NOT NULL DEFAULT 0,
    "charged_amount" DECIMAL(12,2),
    "charged_currency" TEXT,
    "alerted_tb" JSONB NOT NULL DEFAULT '[]',
    "charges_alerted_at" TIMESTAMP(3),
    "last_polled_at" TIMESTAMP(3),
    "last_error" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "egress_budget_cycles_pkey" PRIMARY KEY ("id")
);

-- The cycle start is the natural key: upsert-by-cycle depends on it.
CREATE UNIQUE INDEX IF NOT EXISTS "egress_budget_cycles_cycle_start_key"
    ON "egress_budget_cycles"("cycle_start");
