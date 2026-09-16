-- The live payment gateway, as a row instead of a deploy.
--
-- Three acquirers now live side by side in src/payments/{tabpay,mulenpay,
-- cashera}. This table holds the one the shop is currently charging through,
-- so switching - a moderation refusal, an outage, a rate that got worse - is a
-- click in the admin panel.
--
-- Deliberately NOT seeded. In services terms an absent row means "BILLING_-
-- PROVIDER decides", which is exactly how every existing deployment behaves
-- today; inserting 'global' with the default '' here would switch billing off
-- on the next restart. The row appears the first time an administrator picks a
-- gateway.

CREATE TABLE IF NOT EXISTS "billing_settings" (
	"id"         TEXT         NOT NULL DEFAULT 'global',
	-- "" = billing off, or "manual" / "stripe" / a folder in src/payments.
	"provider"   TEXT         NOT NULL DEFAULT '',
	"updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "billing_settings_pkey" PRIMARY KEY ("id")
);
