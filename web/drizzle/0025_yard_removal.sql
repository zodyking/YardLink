DROP TABLE IF EXISTS "yard_asset_positions";--> statement-breakpoint
DROP TABLE IF EXISTS "yard_slots";--> statement-breakpoint
DROP TABLE IF EXISTS "yard_features";--> statement-breakpoint
DROP TABLE IF EXISTS "yard_objects";--> statement-breakpoint
DROP TABLE IF EXISTS "yard_layouts";--> statement-breakpoint
DROP TABLE IF EXISTS "container_placements";--> statement-breakpoint
DROP TYPE IF EXISTS "public"."yard_object_type";--> statement-breakpoint
DROP TYPE IF EXISTS "public"."yard_layout_status";--> statement-breakpoint
DROP TYPE IF EXISTS "public"."yard_feature_type";--> statement-breakpoint
DROP TYPE IF EXISTS "public"."yard_feature_source";--> statement-breakpoint
DROP TYPE IF EXISTS "public"."yard_asset_type";--> statement-breakpoint
ALTER TABLE "locations" DROP COLUMN IF EXISTS "boundary";--> statement-breakpoint
ALTER TABLE "locations" DROP COLUMN IF EXISTS "map_heading";--> statement-breakpoint
ALTER TABLE "locations" ADD COLUMN IF NOT EXISTS "arrival_radius_m" integer DEFAULT 180 NOT NULL;--> statement-breakpoint
ALTER TABLE "location_zones" DROP COLUMN IF EXISTS "boundary";--> statement-breakpoint
ALTER TABLE "location_zones" DROP COLUMN IF EXISTS "local_geometry";--> statement-breakpoint
ALTER TABLE "container_events" DROP COLUMN IF EXISTS "yard_position";
