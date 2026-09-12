-- Telegram bot overhaul (#090-#100): administration notifications, the daily
-- digest, and the account menus inside the bot.
--
-- IF NOT EXISTS everywhere: prod and beta share this migration history and one
-- of them may already have been patched by hand during a hotfix.

-- #100: profile data the bot refreshes while the owner is talking to it. No
-- background polling, so the timestamp is what keeps it to once a day.
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "telegram_first_name" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "telegram_last_name" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "telegram_photo_id" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "telegram_profile_synced_at" TIMESTAMP(3);

-- #091: the sign-up already knows which client and which entry point started
-- it; without storing that, the notification sent minutes later cannot say so.
ALTER TABLE "pending_registrations" ADD COLUMN IF NOT EXISTS "created_platform" TEXT;
ALTER TABLE "pending_registrations" ADD COLUMN IF NOT EXISTS "created_source" TEXT;

-- #093: one digest per day, and counters for the things a per-event
-- notification cannot report (abandoned and refused sign-ups).
CREATE TABLE IF NOT EXISTS "telegram_admin_state" (
    "id" TEXT NOT NULL DEFAULT 'global',
    "last_digest_day" TEXT,
    "last_digest_at" TIMESTAMP(3),
    "abandoned_registrations" INTEGER NOT NULL DEFAULT 0,
    "failed_registrations" INTEGER NOT NULL DEFAULT 0,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "telegram_admin_state_pkey" PRIMARY KEY ("id")
);
