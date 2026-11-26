-- ShipCSX results are saved again, now read from lookups a person runs in
-- the app. An earlier build of 0032 dropped this table; put it back where
-- it is missing and leave it alone where it survived.
DO $$ BEGIN
  CREATE TYPE "public"."csx_lookup_tab" AS ENUM('NOTIFIED', 'ENROUTE', 'IN_GATE', 'OTHERS', 'NOT_FOUND');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "csx_shipment_snapshots" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"company_id" uuid NOT NULL REFERENCES "public"."companies"("id") ON DELETE cascade,
	"container_id" uuid REFERENCES "public"."containers"("id") ON DELETE set null,
	"container_number_normalized" text NOT NULL,
	"terminal_name" text NOT NULL,
	"equipment_number" text NOT NULL,
	"reference_used" text DEFAULT '00' NOT NULL,
	"result_tab" "csx_lookup_tab" DEFAULT 'NOT_FOUND' NOT NULL,
	"load_empty" text,
	"waybill_date" text,
	"in_gate_readiness" text,
	"gate_window" text,
	"raw_payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"error" text,
	"checked_at" timestamp with time zone DEFAULT now() NOT NULL
);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "csx_shipment_snapshots_container_idx" ON "csx_shipment_snapshots" USING btree ("container_id","checked_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "csx_shipment_snapshots_company_idx" ON "csx_shipment_snapshots" USING btree ("company_id","checked_at");
