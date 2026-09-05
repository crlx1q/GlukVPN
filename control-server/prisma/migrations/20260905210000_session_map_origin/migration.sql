-- A display-only estimate belonging to one device. Recording it before connect
-- ensures a newly created session can be shown even after the popup closes.
ALTER TABLE "devices" ADD COLUMN "map_country_code" TEXT;
