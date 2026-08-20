-- ============================================================================
-- Deployment queue: admin panel writes a row, the local deploy worker runs it.
--
-- Only three fixed actions exist and none of them carries parameters, so this
-- table can never become a channel for arbitrary command execution.
-- ============================================================================

CREATE TYPE "DeployAction" AS ENUM ('DEPLOY_BETA', 'PROMOTE_BETA_TO_PROD', 'ROLLBACK_PROD');
CREATE TYPE "DeployJobStatus" AS ENUM ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED');

CREATE TABLE "deploy_jobs" (
    "id" UUID NOT NULL,
    "action" "DeployAction" NOT NULL,
    "status" "DeployJobStatus" NOT NULL DEFAULT 'QUEUED',
    "requested_by_id" UUID,
    "release_id" TEXT,
    "previous_release_id" TEXT,
    "backup_path" TEXT,
    "exit_code" INTEGER,
    "log" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "started_at" TIMESTAMP(3),
    "finished_at" TIMESTAMP(3),

    CONSTRAINT "deploy_jobs_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "deploy_jobs_status_created_at_idx" ON "deploy_jobs"("status", "created_at");
CREATE INDEX "deploy_jobs_created_at_idx" ON "deploy_jobs"("created_at");

ALTER TABLE "deploy_jobs"
    ADD CONSTRAINT "deploy_jobs_requested_by_id_fkey"
    FOREIGN KEY ("requested_by_id") REFERENCES "users"("id")
    ON DELETE SET NULL ON UPDATE CASCADE;

-- At most one job may be queued or running at any time. Enforced by the
-- database so two admins clicking Promote simultaneously cannot interleave two
-- deployments over the same directories.
CREATE UNIQUE INDEX "deploy_jobs_single_active_idx"
    ON "deploy_jobs" ((1))
    WHERE "status" IN ('QUEUED', 'RUNNING');
