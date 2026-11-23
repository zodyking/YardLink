CREATE TABLE IF NOT EXISTS "fuel_receipts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"company_id" uuid NOT NULL,
	"driver_id" uuid NOT NULL,
	"purchased_at" timestamp with time zone NOT NULL,
	"gallons" numeric(8, 3) NOT NULL,
	"total_amount" numeric(10, 2) NOT NULL,
	"price_per_gallon" numeric(8, 3),
	"station_name" text,
	"storage_key" text NOT NULL,
	"mime_type" text NOT NULL,
	"size_bytes" integer DEFAULT 0 NOT NULL,
	"ocr_text" text,
	"notes" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "fuel_receipts" ADD CONSTRAINT "fuel_receipts_company_id_companies_id_fk" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE cascade ON UPDATE no action;
 ALTER TABLE "fuel_receipts" ADD CONSTRAINT "fuel_receipts_driver_id_drivers_id_fk" FOREIGN KEY ("driver_id") REFERENCES "public"."drivers"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "fuel_receipts_company_idx" ON "fuel_receipts" USING btree ("company_id","purchased_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "fuel_receipts_driver_idx" ON "fuel_receipts" USING btree ("driver_id","purchased_at");
