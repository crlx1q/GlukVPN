-- Feature state is isolated in each control-plane database (PROD/BETA).
CREATE TABLE "service_settings" (
  "id" TEXT PRIMARY KEY DEFAULT 'global' CHECK ("id" = 'global'),
  "registration_enabled" BOOLEAN,
  "maintenance" BOOLEAN NOT NULL DEFAULT false,
  "version" INTEGER NOT NULL DEFAULT 0,
  "analytics_since" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO "service_settings" ("id") VALUES ('global');
ALTER TABLE "vpn_nodes" ADD COLUMN "maintenance" BOOLEAN NOT NULL DEFAULT false;

-- No backfill of session totals into invented days. These buckets begin at
-- rollout and contain only counter increases observed after this trigger exists.
-- Device snapshots survive a sign-out/delete; deleting the account removes them.
CREATE TABLE "traffic_usage_buckets" (
  "user_id" UUID NOT NULL REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE,
  "device_id" UUID NOT NULL,
  "bucket_start" TIMESTAMP(3) NOT NULL,
  "device_name" TEXT NOT NULL,
  "platform" TEXT,
  "upload_bytes" BIGINT NOT NULL DEFAULT 0 CHECK ("upload_bytes" >= 0),
  "download_bytes" BIGINT NOT NULL DEFAULT 0 CHECK ("download_bytes" >= 0),
  PRIMARY KEY ("user_id", "device_id", "bucket_start")
);
CREATE INDEX "traffic_usage_buckets_user_id_bucket_start_idx" ON "traffic_usage_buckets" ("user_id", "bucket_start");
CREATE INDEX "traffic_usage_buckets_bucket_start_idx" ON "traffic_usage_buckets" ("bucket_start");

CREATE FUNCTION "capture_session_usage"() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  upload_delta BIGINT;
  download_delta BIGINT;
  device_label TEXT;
  device_platform TEXT;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- PostgreSQL holds the session row lock. OLD is the committed previous
    -- value, not an earlier application read: concurrent reports cannot regress.
    NEW.bytes_rx := GREATEST(NEW.bytes_rx, OLD.bytes_rx);
    NEW.bytes_tx := GREATEST(NEW.bytes_tx, OLD.bytes_tx);
    upload_delta := NEW.bytes_rx - OLD.bytes_rx;
    download_delta := NEW.bytes_tx - OLD.bytes_tx;
  ELSE
    upload_delta := GREATEST(NEW.bytes_rx, 0);
    download_delta := GREATEST(NEW.bytes_tx, 0);
  END IF;
  IF upload_delta = 0 AND download_delta = 0 THEN RETURN NEW; END IF;
  SELECT device_name, platform INTO device_label, device_platform FROM devices WHERE id = NEW.device_id;
  INSERT INTO traffic_usage_buckets (user_id, device_id, bucket_start, device_name, platform, upload_bytes, download_bytes)
  VALUES (NEW.user_id, NEW.device_id, date_trunc('hour', clock_timestamp() AT TIME ZONE 'UTC'),
          COALESCE(device_label, 'Device'), device_platform, upload_delta, download_delta)
  ON CONFLICT (user_id, device_id, bucket_start) DO UPDATE SET
    upload_bytes = traffic_usage_buckets.upload_bytes + EXCLUDED.upload_bytes,
    download_bytes = traffic_usage_buckets.download_bytes + EXCLUDED.download_bytes,
    device_name = EXCLUDED.device_name, platform = EXCLUDED.platform;
  RETURN NEW;
END;
$$;
CREATE TRIGGER "capture_session_usage_insert" BEFORE INSERT ON "sessions"
FOR EACH ROW EXECUTE FUNCTION "capture_session_usage"();
CREATE TRIGGER "capture_session_usage_update" BEFORE UPDATE OF "bytes_rx", "bytes_tx" ON "sessions"
FOR EACH ROW EXECUTE FUNCTION "capture_session_usage"();

-- An old access/refresh token must not revive when its device is re-enrolled.
ALTER TABLE "devices" ADD COLUMN "token_version" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "refresh_tokens" ADD COLUMN "device_token_version" INTEGER;
