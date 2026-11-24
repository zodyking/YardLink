-- Container pickups used to also write a CHASSIS_ATTACH ("Container placed
-- on chassis") whenever the system hadn't already recorded the box on that
-- chassis, even though the driver had simply hooked up to a container that
-- was already sitting on it. That pickup no longer writes the event; this
-- removes the ones it already wrote.
--
-- Matched narrowly: an attach written in the same instant, for the same trip
-- and container, as a PICKUP_CONFIRMED that was not the bare-chassis flow
-- (that flow marks its pickup with attachedToBareChassis and is a real
-- attach, so it is left alone).
DELETE FROM "container_events" AS attach
USING "container_events" AS pickup
WHERE attach."event_type" = 'CHASSIS_ATTACH'
  AND pickup."event_type" = 'PICKUP_CONFIRMED'
  AND pickup."trip_id" = attach."trip_id"
  AND pickup."container_id" = attach."container_id"
  AND pickup."occurred_at" = attach."occurred_at"
  AND COALESCE(pickup."payload"->>'attachedToBareChassis', 'false') <> 'true';
