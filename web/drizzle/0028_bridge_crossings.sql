CREATE TYPE "public"."bridge_crossing_direction" AS ENUM('ToNY', 'ToNJ');
--> statement-breakpoint
CREATE TABLE "bridge_crossing_snapshots" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"facility_id" integer NOT NULL,
	"crossing_name" text NOT NULL,
	"direction" "bridge_crossing_direction" NOT NULL,
	"travel_time_minutes" integer NOT NULL,
	"typical_time_minutes" integer,
	"is_closed" boolean DEFAULT false NOT NULL,
	"source_timestamp" text,
	"recorded_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "bridge_crossing_snapshots_lane_idx" ON "bridge_crossing_snapshots" USING btree ("facility_id","direction","recorded_at");
--> statement-breakpoint
CREATE INDEX "bridge_crossing_snapshots_recorded_idx" ON "bridge_crossing_snapshots" USING btree ("recorded_at");
