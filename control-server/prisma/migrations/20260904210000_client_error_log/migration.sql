-- Client-side crash reports (POST /api/telemetry/error).
--
-- No foreign keys on purpose: a report must never be rejected because the
-- account or device row it mentions has just been deleted. The columns are
-- filled from a verified token when the client has one, so they are still
-- trustworthy - they are simply not enforced.
CREATE TABLE "client_error_logs" (
    "id" UUID NOT NULL,
    "platform" TEXT NOT NULL,
    "app_version" TEXT NOT NULL,
    "error_name" TEXT NOT NULL,
    "error_message" TEXT NOT NULL,
    "stack_trace" TEXT,
    "context" TEXT,
    "device_id" TEXT,
    "user_id" UUID,
    "ip" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "client_error_logs_pkey" PRIMARY KEY ("id")
);

-- The admin panel filters by platform and always sorts by time.
CREATE INDEX "client_error_logs_platform_created_at_idx" ON "client_error_logs"("platform", "created_at");

-- Retention sweeps and the unfiltered list both walk this one.
CREATE INDEX "client_error_logs_created_at_idx" ON "client_error_logs"("created_at");
