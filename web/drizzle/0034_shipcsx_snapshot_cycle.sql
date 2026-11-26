-- Each ShipCSX result belongs to the container's duty cycle at the time.
ALTER TABLE "csx_shipment_snapshots" ADD COLUMN IF NOT EXISTS "duty_cycle_id" uuid REFERENCES "public"."container_duty_cycles"("id") ON DELETE set null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "csx_shipment_snapshots_cycle_idx" ON "csx_shipment_snapshots" USING btree ("duty_cycle_id","checked_at");
