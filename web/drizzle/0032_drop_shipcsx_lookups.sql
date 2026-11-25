-- ShipCSX is now checked by hand in the driver's browser; the server no
-- longer looks containers up, so its saved results and poll state go.
DROP TABLE IF EXISTS "csx_shipment_snapshots";--> statement-breakpoint
DROP TABLE IF EXISTS "csx_poll_state";--> statement-breakpoint
DROP TYPE IF EXISTS "public"."csx_lookup_tab";
