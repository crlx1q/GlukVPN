-- ============================================================================
-- GlukVPN: sing-box policy, per-device VLESS credentials, traffic attribution,
-- persisted sign-in links, tester flag, user blocking and billing scaffolding.
--
--   0. catch-up: columns/tables that `schema.prisma` already declared but no
--      committed migration ever created (Telegram identity, pending sign-ups,
--      IdentityLink name/phone). Every statement is IF NOT EXISTS, so a
--      database that received them through `prisma db push` is left alone.
--   1. users: is_tester, blocked_at / blocked_reason, BLOCKED status
--   2. devices: vless_uuid (one credential per device)
--   3. vpn_nodes: tier, gateway_* (reported by the agent), policy_version
--   4. sessions: transport, client_ip
--   5. node_block_rules: admin-managed "reject" rules for the sing-box router
--   6. traffic_domain_stats: sniffed domain per device/session (no URLs)
--   7. link_requests: device-authorization grant moved from RAM to the table
--   8. subscriptions: tier / source; plans + orders for billing
--   9. node_commands: SYNC_POLICY
--
-- Nothing here rewrites existing rows. Safe to run on prod and beta alike.
-- ============================================================================

-- -------------------------------------------------------------- 0. catch-up
ALTER TABLE "users"
	ADD COLUMN IF NOT EXISTS "telegram_id"          TEXT,
	ADD COLUMN IF NOT EXISTS "telegram_username"    TEXT,
	ADD COLUMN IF NOT EXISTS "telegram_phone"       TEXT,
	ADD COLUMN IF NOT EXISTS "telegram_verified_at" TIMESTAMP(3);

CREATE UNIQUE INDEX IF NOT EXISTS "users_telegram_id_key"    ON "users" ("telegram_id");
CREATE UNIQUE INDEX IF NOT EXISTS "users_telegram_phone_key" ON "users" ("telegram_phone");

ALTER TYPE "VerificationPurpose" ADD VALUE IF NOT EXISTS 'TELEGRAM_LINK';

ALTER TABLE "identity_links"
	ADD COLUMN IF NOT EXISTS "provider_name"  TEXT,
	ADD COLUMN IF NOT EXISTS "provider_phone" TEXT;

CREATE TABLE IF NOT EXISTS "pending_registrations" (
	"id"                   UUID         NOT NULL,
	"email"                TEXT         NOT NULL,
	"password_hash"        TEXT         NOT NULL,
	"email_verified_at"    TIMESTAMP(3),
	"telegram_code"        TEXT         NOT NULL,
	"telegram_id"          TEXT,
	"telegram_username"    TEXT,
	"telegram_phone"       TEXT,
	"telegram_verified_at" TIMESTAMP(3),
	"google_sub"           TEXT,
	"created_ip"           TEXT,
	"expires_at"           TIMESTAMP(3) NOT NULL,
	"created_at"           TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"updated_at"           TIMESTAMP(3) NOT NULL,

	CONSTRAINT "pending_registrations_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "pending_registrations_email_key"
	ON "pending_registrations" ("email");
CREATE UNIQUE INDEX IF NOT EXISTS "pending_registrations_telegram_code_key"
	ON "pending_registrations" ("telegram_code");
CREATE INDEX IF NOT EXISTS "pending_registrations_expires_at_idx"
	ON "pending_registrations" ("expires_at");
CREATE INDEX IF NOT EXISTS "pending_registrations_telegram_id_idx"
	ON "pending_registrations" ("telegram_id");

-- ------------------------------------------------------------------ 1. users
ALTER TYPE "UserStatus" ADD VALUE IF NOT EXISTS 'BLOCKED';

ALTER TABLE "users"
	ADD COLUMN IF NOT EXISTS "is_tester"      BOOLEAN NOT NULL DEFAULT false,
	ADD COLUMN IF NOT EXISTS "blocked_at"     TIMESTAMP(3),
	ADD COLUMN IF NOT EXISTS "blocked_reason" TEXT;

-- ---------------------------------------------------------------- 2. devices
-- Nullable: rows that predate this column keep using the fleet-wide VLESS_UUID
-- until they connect again, at which point the API issues them a personal one.
ALTER TABLE "devices" ADD COLUMN IF NOT EXISTS "vless_uuid" UUID;
CREATE UNIQUE INDEX IF NOT EXISTS "devices_vless_uuid_key" ON "devices" ("vless_uuid");

-- -------------------------------------------------------------- 3. vpn_nodes
ALTER TABLE "vpn_nodes"
	ADD COLUMN IF NOT EXISTS "tier"               INTEGER NOT NULL DEFAULT 0,
	ADD COLUMN IF NOT EXISTS "gateway_host"       TEXT,
	ADD COLUMN IF NOT EXISTS "gateway_port"       INTEGER,
	ADD COLUMN IF NOT EXISTS "gateway_sni"        TEXT,
	ADD COLUMN IF NOT EXISTS "gateway_flow"       TEXT,
	ADD COLUMN IF NOT EXISTS "gateway_updated_at" TIMESTAMP(3),
	ADD COLUMN IF NOT EXISTS "policy_version"     TEXT,
	ADD COLUMN IF NOT EXISTS "policy_applied_at"  TIMESTAMP(3);

-- --------------------------------------------------------------- 4. sessions
ALTER TABLE "sessions"
	ADD COLUMN IF NOT EXISTS "transport" TEXT NOT NULL DEFAULT 'wireguard',
	ADD COLUMN IF NOT EXISTS "client_ip" TEXT;

-- ------------------------------------------------------- 5. node_block_rules
DO $$ BEGIN
	CREATE TYPE "BlockRuleKind" AS ENUM (
		'PROTOCOL', 'DOMAIN', 'DOMAIN_SUFFIX', 'DOMAIN_KEYWORD', 'DOMAIN_REGEX',
		'IP_CIDR', 'PORT', 'PORT_RANGE'
	);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS "node_block_rules" (
	"id"            UUID            NOT NULL,
	"node_id"       UUID,
	"kind"          "BlockRuleKind" NOT NULL,
	"value"         TEXT            NOT NULL,
	"network"       TEXT,
	"enabled"       BOOLEAN         NOT NULL DEFAULT true,
	"note"          TEXT,
	"created_by_id" UUID,
	"created_at"    TIMESTAMP(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"updated_at"    TIMESTAMP(3)    NOT NULL,

	CONSTRAINT "node_block_rules_pkey" PRIMARY KEY ("id")
);

CREATE INDEX IF NOT EXISTS "node_block_rules_node_id_enabled_idx"
	ON "node_block_rules" ("node_id", "enabled");

DO $$ BEGIN
	ALTER TABLE "node_block_rules"
		ADD CONSTRAINT "node_block_rules_node_id_fkey"
		FOREIGN KEY ("node_id") REFERENCES "vpn_nodes" ("id")
		ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
	ALTER TABLE "node_block_rules"
		ADD CONSTRAINT "node_block_rules_created_by_id_fkey"
		FOREIGN KEY ("created_by_id") REFERENCES "users" ("id")
		ON DELETE SET NULL ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- --------------------------------------------------- 6. traffic_domain_stats
CREATE TABLE IF NOT EXISTS "traffic_domain_stats" (
	"id"            UUID         NOT NULL,
	"user_id"       UUID         NOT NULL,
	"device_id"     UUID         NOT NULL,
	"session_id"    UUID         NOT NULL,
	"node_id"       UUID         NOT NULL,
	"domain"        TEXT         NOT NULL,
	"category"      TEXT,
	"bytes_rx"      BIGINT       NOT NULL DEFAULT 0,
	"bytes_tx"      BIGINT       NOT NULL DEFAULT 0,
	"connections"   INTEGER      NOT NULL DEFAULT 0,
	"first_seen_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"last_seen_at"  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "traffic_domain_stats_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "traffic_domain_stats_session_id_domain_key"
	ON "traffic_domain_stats" ("session_id", "domain");
CREATE INDEX IF NOT EXISTS "traffic_domain_stats_user_id_last_seen_at_idx"
	ON "traffic_domain_stats" ("user_id", "last_seen_at");
CREATE INDEX IF NOT EXISTS "traffic_domain_stats_device_id_last_seen_at_idx"
	ON "traffic_domain_stats" ("device_id", "last_seen_at");
CREATE INDEX IF NOT EXISTS "traffic_domain_stats_last_seen_at_idx"
	ON "traffic_domain_stats" ("last_seen_at");

DO $$ BEGIN
	ALTER TABLE "traffic_domain_stats"
		ADD CONSTRAINT "traffic_domain_stats_user_id_fkey"
		FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
	ALTER TABLE "traffic_domain_stats"
		ADD CONSTRAINT "traffic_domain_stats_device_id_fkey"
		FOREIGN KEY ("device_id") REFERENCES "devices" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
	ALTER TABLE "traffic_domain_stats"
		ADD CONSTRAINT "traffic_domain_stats_session_id_fkey"
		FOREIGN KEY ("session_id") REFERENCES "sessions" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
	ALTER TABLE "traffic_domain_stats"
		ADD CONSTRAINT "traffic_domain_stats_node_id_fkey"
		FOREIGN KEY ("node_id") REFERENCES "vpn_nodes" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------- 7. link_requests
DO $$ BEGIN
	CREATE TYPE "LinkRequestStatus" AS ENUM ('PENDING', 'APPROVED', 'DENIED', 'EXPIRED', 'USED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS "link_requests" (
	"id"               UUID                NOT NULL,
	"user_code"        TEXT                NOT NULL,
	"poll_secret_hash" TEXT                NOT NULL,
	"client"           TEXT                NOT NULL,
	"device_name"      TEXT,
	"ip"               TEXT,
	"user_agent"       TEXT,
	"status"           "LinkRequestStatus" NOT NULL DEFAULT 'PENDING',
	"user_id"          UUID,
	"approved_via"     TEXT,
	"expires_at"       TIMESTAMP(3)        NOT NULL,
	"last_poll_at"     TIMESTAMP(3),
	"approved_at"      TIMESTAMP(3),
	"used_at"          TIMESTAMP(3),
	"created_at"       TIMESTAMP(3)        NOT NULL DEFAULT CURRENT_TIMESTAMP,

	CONSTRAINT "link_requests_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "link_requests_user_code_key" ON "link_requests" ("user_code");
CREATE INDEX IF NOT EXISTS "link_requests_expires_at_idx" ON "link_requests" ("expires_at");

DO $$ BEGIN
	ALTER TABLE "link_requests"
		ADD CONSTRAINT "link_requests_user_id_fkey"
		FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------- 8. billing
ALTER TABLE "subscriptions"
	ADD COLUMN IF NOT EXISTS "tier"   INTEGER NOT NULL DEFAULT 0,
	ADD COLUMN IF NOT EXISTS "source" TEXT    NOT NULL DEFAULT 'manual';

DO $$ BEGIN
	CREATE TYPE "OrderStatus" AS ENUM ('PENDING', 'PAID', 'FAILED', 'CANCELLED', 'REFUNDED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS "plans" (
	"id"           UUID         NOT NULL,
	"code"         TEXT         NOT NULL,
	"name"         TEXT         NOT NULL,
	"tier"         INTEGER      NOT NULL DEFAULT 0,
	"days"         INTEGER      NOT NULL DEFAULT 30,
	"price_minor"  INTEGER      NOT NULL DEFAULT 0,
	"currency"     TEXT         NOT NULL DEFAULT 'KZT',
	"max_devices"  INTEGER      NOT NULL DEFAULT 3,
	"max_sessions" INTEGER      NOT NULL DEFAULT 1,
	"features"     JSONB        NOT NULL DEFAULT '[]',
	"featured"     BOOLEAN      NOT NULL DEFAULT false,
	"active"       BOOLEAN      NOT NULL DEFAULT true,
	"sort_order"   INTEGER      NOT NULL DEFAULT 0,
	"created_at"   TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"updated_at"   TIMESTAMP(3) NOT NULL,

	CONSTRAINT "plans_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "plans_code_key" ON "plans" ("code");

CREATE TABLE IF NOT EXISTS "orders" (
	"id"           UUID          NOT NULL,
	"user_id"      UUID          NOT NULL,
	"plan_id"      UUID          NOT NULL,
	"status"       "OrderStatus" NOT NULL DEFAULT 'PENDING',
	"amount_minor" INTEGER       NOT NULL,
	"currency"     TEXT          NOT NULL,
	"provider"     TEXT          NOT NULL,
	"provider_ref" TEXT,
	"payment_url"  TEXT,
	"paid_at"      TIMESTAMP(3),
	"metadata"     JSONB,
	"created_at"   TIMESTAMP(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP,
	"updated_at"   TIMESTAMP(3)  NOT NULL,

	CONSTRAINT "orders_pkey" PRIMARY KEY ("id")
);

CREATE INDEX IF NOT EXISTS "orders_user_id_created_at_idx" ON "orders" ("user_id", "created_at");
CREATE INDEX IF NOT EXISTS "orders_status_idx"              ON "orders" ("status");
CREATE INDEX IF NOT EXISTS "orders_provider_ref_idx"        ON "orders" ("provider_ref");

DO $$ BEGIN
	ALTER TABLE "orders"
		ADD CONSTRAINT "orders_user_id_fkey"
		FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
	ALTER TABLE "orders"
		ADD CONSTRAINT "orders_plan_id_fkey"
		FOREIGN KEY ("plan_id") REFERENCES "plans" ("id") ON DELETE RESTRICT ON UPDATE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The three public plans, priced as on the pricing page (tenge, per month).
-- Free stays tier 0 so nothing that works today stops working; Basic and Pro
-- carry tiers 1 and 2 for the node `tier` gate.
INSERT INTO "plans" ("id", "code", "name", "tier", "days", "price_minor", "currency",
                     "max_devices", "max_sessions", "features", "featured", "active",
                     "sort_order", "updated_at")
VALUES
	(gen_random_uuid(), 'free',  'Free',  0, 30,      0, 'KZT', 1, 1,
	 '["1 устройство", "Базовые серверы", "Без ограничений по трафику"]'::jsonb, false, true, 10, CURRENT_TIMESTAMP),
	(gen_random_uuid(), 'basic', 'Basic', 1, 30, 149000, 'KZT', 3, 1,
	 '["3 устройства", "Все серверы", "Приоритетная скорость"]'::jsonb, true, true, 20, CURRENT_TIMESTAMP),
	(gen_random_uuid(), 'pro',   'Pro',   2, 30, 249000, 'KZT', 5, 2,
	 '["5 устройств", "2 одновременных туннеля", "Все серверы и новые регионы первыми"]'::jsonb, false, true, 30, CURRENT_TIMESTAMP)
ON CONFLICT ("code") DO NOTHING;

-- ---------------------------------------------------------- 9. node_commands
ALTER TYPE "CommandType" ADD VALUE IF NOT EXISTS 'SYNC_POLICY';
