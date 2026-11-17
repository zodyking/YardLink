CREATE TABLE IF NOT EXISTS "trip_arrivals" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"company_id" uuid NOT NULL,
	"trip_id" uuid NOT NULL,
	"driver_id" uuid NOT NULL,
	"location_id" uuid NOT NULL,
	"entered_at" timestamp with time zone NOT NULL,
	"auto_at" timestamp with time zone NOT NULL,
	"latitude" numeric(10, 7),
	"longitude" numeric(10, 7),
	"accuracy_meters" real,
	"settled_at" timestamp with time zone,
	"outcome" text,
	"event_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "trip_arrivals" ADD CONSTRAINT "trip_arrivals_company_id_companies_id_fk" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE cascade ON UPDATE no action;
 ALTER TABLE "trip_arrivals" ADD CONSTRAINT "trip_arrivals_trip_id_trips_id_fk" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE cascade ON UPDATE no action;
 ALTER TABLE "trip_arrivals" ADD CONSTRAINT "trip_arrivals_driver_id_drivers_id_fk" FOREIGN KEY ("driver_id") REFERENCES "public"."drivers"("id") ON DELETE cascade ON UPDATE no action;
 ALTER TABLE "trip_arrivals" ADD CONSTRAINT "trip_arrivals_location_id_locations_id_fk" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "trip_arrivals_open_idx" ON "trip_arrivals" USING btree ("settled_at","auto_at");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "trip_arrivals_trip_location_key" ON "trip_arrivals" USING btree ("trip_id","location_id");
