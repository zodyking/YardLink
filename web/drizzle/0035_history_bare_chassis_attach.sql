-- Hanging a box on a chassis the driver already had was recorded as a pickup
-- plus a "placed on chassis" row. Mark the older pickups of that shape so the
-- history shows one step, and give them the place the hang happened.
UPDATE "container_events" AS pick
SET "payload" = pick."payload" || '{"attachedToBareChassis": true}'::jsonb,
    "location_id" = COALESCE(pick."location_id", hang."location_id")
FROM "container_events" AS hang
WHERE pick."event_type" = 'PICKUP_CONFIRMED'
  AND hang."event_type" = 'CHASSIS_ATTACH'
  AND pick."location_id" IS NULL
  AND pick."container_id" IS NOT NULL
  AND pick."chassis_id" IS NOT NULL
  AND NOT (pick."payload" ? 'attachedToBareChassis')
  AND pick."company_id" = hang."company_id"
  AND pick."container_id" = hang."container_id"
  AND pick."chassis_id" = hang."chassis_id"
  AND pick."trip_id" IS NOT DISTINCT FROM hang."trip_id"
  AND ABS(EXTRACT(EPOCH FROM (pick."occurred_at" - hang."occurred_at"))) <= 5;
