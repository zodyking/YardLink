-- The crossing-times page is bridges only now, and the poll no longer stores
-- tunnel readings. This clears the tunnel readings already stored so they
-- drop off the page right away instead of lingering until they age out.
DELETE FROM "bridge_crossing_snapshots" WHERE "crossing_name" ~* '\mtunnel\M';
